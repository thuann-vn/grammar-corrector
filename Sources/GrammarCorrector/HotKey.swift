import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A system-wide hotkey registered through Carbon (works without Accessibility permission).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4752_4D52), id: 1) // "GRMR"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        log.info("hotkey registered: status=\(status)")
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Synthesizes ⌘-key presses in the frontmost app (requires Accessibility permission).
enum Keystroke {
    static func command(_ keyCode: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Waits (up to 1.5 s) until ⌘, ⇧, ⌥ and ⌃ are no longer physically held.
    static func waitForModifiersRelease() async {
        let held: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0..<30 {
            if CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
