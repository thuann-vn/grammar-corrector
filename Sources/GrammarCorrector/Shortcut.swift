import AppKit
import Carbon.HIToolbox

/// A user-chosen global shortcut, stored as a Carbon key code + Carbon modifier mask.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    static let `default` = Shortcut(keyCode: kVK_ANSI_C, modifiers: shiftKey | cmdKey, key: "C")

    /// Shown in Apple's standard order: ⌃⌥⇧⌘.
    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// Builds a shortcut from a key press; nil if it has no ⌘/⌃/⌥ (plain keys would hijack typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        guard mods & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: mods, key: Self.name(for: event))
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func name(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    // MARK: Persistence

    private static let defaultsKey = "quickFixShortcut"

    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        else { return .default }
        return shortcut
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
