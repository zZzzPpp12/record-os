import AppKit
import Foundation

/// Shows a live "recording" indicator in the macOS menu bar while screen capture
/// is running, so the state stays visible even when the app window is hidden.
@MainActor
final class MenuBarRecordingIndicator: NSObject {
    private var statusItem: NSStatusItem?
    private var blinkTimer: Timer?
    private var elapsedTimer: Timer?
    private var elapsedMenuItem: NSMenuItem?
    private var startedAt: Date?
    private var displayName: String?
    private var isLargePhase = false
    private var onStop: (() -> Void)?

    func start(startedAt: Date, displayName: String?, onStop: @escaping () -> Void) {
        stop()
        self.startedAt = startedAt
        self.displayName = displayName
        self.onStop = onStop

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.image = dotImage(diameter: 8)
            button.title = " 00:00"
            button.toolTip = displayName.map { "正在录制「\($0)」" } ?? "正在录制屏幕"
        }
        item.menu = makeMenu(displayName: displayName)
        statusItem = item
        updateElapsed()

        let blink = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleBlinkPhase()
            }
        }
        let elapsed = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateElapsed()
            }
        }
        RunLoop.main.add(blink, forMode: .common)
        RunLoop.main.add(elapsed, forMode: .common)
        blinkTimer = blink
        elapsedTimer = elapsed
    }

    func stop() {
        blinkTimer?.invalidate()
        elapsedTimer?.invalidate()
        blinkTimer = nil
        elapsedTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        elapsedMenuItem = nil
        startedAt = nil
        displayName = nil
        onStop = nil
    }

    private func makeMenu(displayName: String?) -> NSMenu {
        let menu = NSMenu()

        let statusItem = NSMenuItem(title: statusTitle(displayName: displayName), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        elapsedMenuItem = statusItem

        menu.addItem(.separator())

        let showApp = NSMenuItem(title: "打开 RecordOS", action: #selector(openApp), keyEquivalent: "")
        showApp.target = self
        menu.addItem(showApp)

        let stopItem = NSMenuItem(title: "停止录制", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        return menu
    }

    private func statusTitle(displayName: String?) -> String {
        let elapsed = startedAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0
        let source = displayName.map { "正在录制「\($0)」" } ?? "正在录制屏幕"
        return "\(source) · \(elapsed.formattedDuration)"
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(startedAt))
        statusItem?.button?.title = " " + elapsed.formattedDuration
        elapsedMenuItem?.title = statusTitle(displayName: displayName)
    }

    private func toggleBlinkPhase() {
        isLargePhase.toggle()
        statusItem?.button?.image = dotImage(diameter: isLargePhase ? 10 : 6)
    }

    private func dotImage(diameter: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(
            x: (size.width - diameter) / 2,
            y: (size.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func stopRecording() {
        onStop?()
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
