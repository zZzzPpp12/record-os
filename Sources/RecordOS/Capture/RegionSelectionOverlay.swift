import AppKit
import CoreGraphics
import Foundation

struct RegionSelectionResult: Sendable {
    var displayID: CGDirectDisplayID
    var displayName: String
    var rectInDisplayPoints: CGRect
    var pixelScale: CGFloat
}

/// Presents full-screen translucent overlays on every connected display so the
/// user can draw, move, and resize a capture rectangle in display-local coordinates.
@MainActor
final class RegionSelectionController {
    private var windows: [RegionOverlayWindow] = []
    private nonisolated(unsafe) var localKeyMonitor: Any?
    private nonisolated(unsafe) var globalKeyMonitor: Any?
    private nonisolated(unsafe) var appResignObserver: NSObjectProtocol?
    private var continuation: CheckedContinuation<RegionSelectionResult?, Never>?
    private var activeScreenID: CGDirectDisplayID?

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
        }
        let leftoverWindows = windows
        if !leftoverWindows.isEmpty {
            DispatchQueue.main.async {
                for window in leftoverWindows {
                    window.orderOut(nil)
                    window.close()
                }
            }
        }
        continuation?.resume(returning: nil)
    }

    func selectRegion() async -> RegionSelectionResult? {
        guard continuation == nil else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.activeScreenID = nil
            self.presentOverlays(for: screens)
        }
    }

    func cancelSelection() {
        finish(with: nil)
    }

    private func presentOverlays(for screens: [NSScreen]) {
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let window = RegionOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: true)

            let overlayView = RegionOverlayView(
                displayID: displayID,
                displayName: screen.localizedName,
                pixelScale: screen.backingScaleFactor
            )
            overlayView.onBeginInteraction = { [weak self] id in
                self?.handleScreenInteraction(activeDisplayID: id)
            }
            overlayView.onConfirm = { [weak self] result in
                self?.finish(with: result)
            }
            overlayView.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            window.contentView = overlayView
            window.orderFrontRegardless()
            windows.append(window)
        }

        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.finish(with: nil)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                if self.confirmCurrentSelection() {
                    return nil
                }
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.finish(with: nil)
            }
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(with: nil)
            }
        }
    }

    private func handleScreenInteraction(activeDisplayID: CGDirectDisplayID) {
        guard activeScreenID != activeDisplayID else { return }
        activeScreenID = activeDisplayID
        for window in windows {
            guard let view = window.contentView as? RegionOverlayView else { continue }
            if view.displayID != activeDisplayID {
                view.clearSelection()
            }
        }
        if let targetWindow = windows.first(where: { ($0.contentView as? RegionOverlayView)?.displayID == activeDisplayID }) {
            targetWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func confirmCurrentSelection() -> Bool {
        for window in windows {
            if let view = window.contentView as? RegionOverlayView,
               let result = view.currentResult() {
                finish(with: result)
                return true
            }
        }
        return false
    }

    private func finish(with result: RegionSelectionResult?) {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        activeScreenID = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

private final class RegionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionOverlayView: NSView {
    let displayID: CGDirectDisplayID
    let displayName: String
    let pixelScale: CGFloat

    var onBeginInteraction: ((CGDirectDisplayID) -> Void)?
    var onConfirm: ((RegionSelectionResult) -> Void)?
    var onCancel: (() -> Void)?

    private enum DragMode {
        case none
        case creating(anchor: CGPoint)
        case moving(offset: CGPoint, initialRect: CGRect)
        case resizing(handle: ResizeHandle, anchor: CGPoint, initialRect: CGRect)
    }

    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var selectionRect: CGRect?
    private var dragMode: DragMode = .none
    private let minSelectionSize: CGFloat = 24

    private let toolbarStack = NSStackView()
    private let confirmButton = NSButton(title: "确认区域", target: nil, action: nil)
    private let resetButton = NSButton(title: "重选", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(displayID: CGDirectDisplayID, displayName: String, pixelScale: CGFloat) {
        self.displayID = displayID
        self.displayName = displayName
        self.pixelScale = pixelScale
        super.init(frame: .zero)
        wantsLayer = true
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clearSelection() {
        selectionRect = nil
        dragMode = .none
        toolbarStack.isHidden = true
        needsDisplay = true
    }

    func currentResult() -> RegionSelectionResult? {
        guard let rect = selectionRect,
              rect.width >= minSelectionSize,
              rect.height >= minSelectionSize else {
            return nil
        }
        let clamped = rect.intersection(bounds).integral
        guard clamped.width >= minSelectionSize, clamped.height >= minSelectionSize else {
            return nil
        }
        return RegionSelectionResult(
            displayID: displayID,
            displayName: displayName,
            rectInDisplayPoints: clamped,
            pixelScale: pixelScale
        )
    }

    private func setupToolbar() {
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.bezelStyle = .rounded
        confirmButton.controlSize = .regular
        confirmButton.contentTintColor = .white
        confirmButton.bezelColor = .controlAccentColor
        confirmButton.keyEquivalent = "\r"

        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 8
        toolbarStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbarStack.wantsLayer = true
        toolbarStack.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        toolbarStack.layer?.cornerRadius = 8
        toolbarStack.layer?.borderWidth = 1
        toolbarStack.layer?.borderColor = NSColor.separatorColor.cgColor

        toolbarStack.addArrangedSubview(confirmButton)
        toolbarStack.addArrangedSubview(resetButton)
        toolbarStack.addArrangedSubview(cancelButton)
        toolbarStack.isHidden = true
        addSubview(toolbarStack)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Dim the entire screen, leaving the selected region clear.
        let overlayColor = NSColor.black.withAlphaComponent(0.36)
        overlayColor.setFill()
        if let rect = selectionRect {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: rect))
            path.windingRule = .evenOdd
            path.fill()
        } else {
            bounds.fill()
            drawHintBanner()
            return
        }

        // Border around the active selection.
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selectionRect!.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()

        // Resize handles.
        for handle in ResizeHandle.allCases {
            let handleRect = frame(for: handle, in: selectionRect!)
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let oval = NSBezierPath(ovalIn: handleRect)
            oval.fill()
            oval.lineWidth = 1.2
            oval.stroke()
        }

        drawDimensionBadge(for: selectionRect!)
    }

    private func drawHintBanner() {
        let text = "拖动框选「\(displayName)」录制区域 · 按 Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let boxRect = CGRect(
            x: (bounds.width - size.width - 28) / 2,
            y: 44,
            width: size.width + 28,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(
            at: CGPoint(x: boxRect.minX + 14, y: boxRect.minY + 8),
            withAttributes: attributes
        )
    }

    private func drawDimensionBadge(for rect: CGRect) {
        let rawW = Int((rect.width * pixelScale).rounded())
        let rawH = Int((rect.height * pixelScale).rounded())
        let pixelW = max(16, rawW.isMultiple(of: 2) ? rawW : rawW + 1)
        let pixelH = max(16, rawH.isMultiple(of: 2) ? rawH : rawH + 1)
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt  (\(pixelW) × \(pixelH) px)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let badgeWidth = textSize.width + 18
        let badgeHeight = textSize.height + 10
        let badgeY = rect.minY >= badgeHeight + 14 ? rect.minY - badgeHeight - 8 : rect.minY + 8
        let badgeX = min(max(8, rect.minX), max(8, bounds.width - badgeWidth - 8))
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(
            at: CGPoint(x: badgeRect.minX + 9, y: badgeRect.minY + 5),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        onBeginInteraction?(displayID)
        let point = convert(event.locationInWindow, from: nil)

        if !toolbarStack.isHidden, toolbarStack.frame.contains(point) {
            return
        }

        if let rect = selectionRect {
            if let handle = hitTestHandle(at: point, in: rect) {
                let anchor = anchorPoint(for: handle, in: rect)
                dragMode = .resizing(handle: handle, anchor: anchor, initialRect: rect)
                toolbarStack.isHidden = true
                return
            }
            if rect.contains(point) {
                dragMode = .moving(
                    offset: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY),
                    initialRect: rect
                )
                toolbarStack.isHidden = true
                return
            }
        }

        toolbarStack.isHidden = true
        selectionRect = CGRect(origin: point, size: .zero)
        dragMode = .creating(anchor: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = CGPoint(
            x: min(max(0, rawPoint.x), bounds.width),
            y: min(max(0, rawPoint.y), bounds.height)
        )

        switch dragMode {
        case .none:
            return
        case .creating(let anchor):
            selectionRect = normalizedRect(from: anchor, to: point)
        case .moving(let offset, let initialRect):
            let maxX = max(0, bounds.width - initialRect.width)
            let maxY = max(0, bounds.height - initialRect.height)
            let newX = min(max(0, point.x - offset.x), maxX)
            let newY = min(max(0, point.y - offset.y), maxY)
            selectionRect = CGRect(origin: CGPoint(x: newX, y: newY), size: initialRect.size)
        case .resizing(let handle, let anchor, let initialRect):
            selectionRect = resizedRect(handle: handle, anchor: anchor, point: point, initialRect: initialRect)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = .none }
        guard let rect = selectionRect,
              rect.width >= minSelectionSize,
              rect.height >= minSelectionSize else {
            selectionRect = nil
            toolbarStack.isHidden = true
            needsDisplay = true
            return
        }
        selectionRect = rect.intersection(bounds).integral
        positionToolbar(for: selectionRect!)
        toolbarStack.isHidden = false
        needsDisplay = true
    }

    private func positionToolbar(for rect: CGRect) {
        toolbarStack.layoutSubtreeIfNeeded()
        let size = toolbarStack.fittingSize
        let x = min(max(12, rect.maxX - size.width), max(12, bounds.width - size.width - 12))
        let belowY = rect.maxY + 10
        let y: CGFloat
        if belowY + size.height + 12 <= bounds.height {
            y = belowY
        } else if rect.minY - size.height - 10 >= 12 {
            y = rect.minY - size.height - 10
        } else {
            y = max(12, rect.maxY - size.height - 12)
        }
        toolbarStack.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func frame(for handle: ResizeHandle, in rect: CGRect) -> CGRect {
        let size: CGFloat = 10
        let half = size / 2
        let x: CGFloat
        let y: CGFloat
        switch handle {
        case .topLeft: (x, y) = (rect.minX, rect.minY)
        case .top: (x, y) = (rect.midX, rect.minY)
        case .topRight: (x, y) = (rect.maxX, rect.minY)
        case .right: (x, y) = (rect.maxX, rect.midY)
        case .bottomRight: (x, y) = (rect.maxX, rect.maxY)
        case .bottom: (x, y) = (rect.midX, rect.maxY)
        case .bottomLeft: (x, y) = (rect.minX, rect.maxY)
        case .left: (x, y) = (rect.minX, rect.midY)
        }
        return CGRect(x: x - half, y: y - half, width: size, height: size)
    }

    private func hitTestHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            if frame(for: handle, in: rect).insetBy(dx: -5, dy: -5).contains(point) {
                return handle
            }
        }
        return nil
    }

    private func anchorPoint(for handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .right: CGPoint(x: rect.minX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    private func resizedRect(
        handle: ResizeHandle,
        anchor: CGPoint,
        point: CGPoint,
        initialRect: CGRect
    ) -> CGRect {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return normalizedRect(from: anchor, to: point)
        case .top, .bottom:
            let minY = min(anchor.y, point.y)
            let maxY = max(anchor.y, point.y)
            return CGRect(x: initialRect.minX, y: minY, width: initialRect.width, height: maxY - minY)
        case .left, .right:
            let minX = min(anchor.x, point.x)
            let maxX = max(anchor.x, point.x)
            return CGRect(x: minX, y: initialRect.minY, width: maxX - minX, height: initialRect.height)
        }
    }

    @objc private func confirmTapped() {
        guard let result = currentResult() else { return }
        onConfirm?(result)
    }

    @objc private func resetTapped() {
        clearSelection()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
