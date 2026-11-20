import AppKit
import SwiftUI

struct EditorKeyboardMonitor: ViewModifier {
    let isEnabled: Bool
    let onSpace: () -> Void
    let onSplitAtPlayhead: () -> Void
    let onSetRangeStart: () -> Void
    let onSetRangeEnd: () -> Void
    let onDelete: () -> Void
    let onStepFrame: (Double) -> Void

    @State private var monitorToken: Any?
    @State private var handlerBox = HandlerBox()

    func body(content: Content) -> some View {
        let _ = syncHandlers()
        content
            .onAppear {
                installMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func syncHandlers() {
        handlerBox.isEnabled = isEnabled
        handlerBox.onSpace = onSpace
        handlerBox.onSplitAtPlayhead = onSplitAtPlayhead
        handlerBox.onSetRangeStart = onSetRangeStart
        handlerBox.onSetRangeEnd = onSetRangeEnd
        handlerBox.onDelete = onDelete
        handlerBox.onStepFrame = onStepFrame
    }

    private func installMonitor() {
        guard monitorToken == nil else { return }
        let box = handlerBox
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard box.isEnabled,
                  NSApp.modalWindow == nil,
                  !(NSApp.keyWindow?.firstResponder is NSText) else {
                return event
            }

            let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
                return event
            }

            if event.keyCode == 49 { // Space
                box.onSpace()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
                box.onDelete()
                return nil
            }
            if event.keyCode == 123 { // Left Arrow
                let step: Double = event.modifierFlags.contains(.shift) ? -5.0 : -0.5
                box.onStepFrame(step)
                return nil
            }
            if event.keyCode == 124 { // Right Arrow
                let step: Double = event.modifierFlags.contains(.shift) ? 5.0 : 0.5
                box.onStepFrame(step)
                return nil
            }

            guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            switch chars {
            case "s":
                box.onSplitAtPlayhead()
                return nil
            case "i":
                box.onSetRangeStart()
                return nil
            case "o":
                box.onSetRangeEnd()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitorToken {
            NSEvent.removeMonitor(monitorToken)
            self.monitorToken = nil
        }
    }
}

@MainActor
private final class HandlerBox {
    var isEnabled = true
    var onSpace: () -> Void = {}
    var onSplitAtPlayhead: () -> Void = {}
    var onSetRangeStart: () -> Void = {}
    var onSetRangeEnd: () -> Void = {}
    var onDelete: () -> Void = {}
    var onStepFrame: (Double) -> Void = { _ in }
}
