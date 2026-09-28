import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

let log = Logger(subsystem: "com.local.GrammarCorrector", category: "quickfix")

@MainActor
final class CheckerModel: ObservableObject {
    @Published var input = ""
    @Published var result: GrammarResult?
    @Published var error: String?
    @Published var isChecking = false
    @Published var apiKey: String = Keychain.load()
    @AppStorage("geminiModel") var modelID = "gemini-flash-latest"
    @AppStorage("showPanelAfterFix") var showPanelAfterFix = true

    /// Called after a shortcut fix that changed the text (or failed), to pop the panel open.
    var onQuickFixFinished: (() -> Void)?

    @Published var hasAccessibility = Keystroke.isTrusted

    @Published var shortcut = Shortcut.load() {
        didSet { shortcut.save(); registerHotKey() }
    }
    @Published var isRecordingShortcut = false

    private var task: Task<Void, Never>?
    private var hotKey: HotKey?
    private var recordMonitor: Any?

    init() {
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey = nil // unregister the old one first
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.quickFix()
        }
    }

    // MARK: Shortcut recording

    /// Captures the next key combo pressed in the panel. Esc cancels.
    func startRecordingShortcut() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        hotKey = nil // so pressing the current combo records it instead of firing
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecordingShortcut()
            } else if let new = Shortcut(event: event) {
                self.stopRecordingShortcut()
                self.shortcut = new
            } else {
                NSSound.beep() // needs ⌘, ⌃ or ⌥
            }
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        isRecordingShortcut = false
        registerHotKey()
    }

    // MARK: Global shortcut — fix the selected text in any app

    /// Copies the selection, corrects it, and pastes the result over it.
    /// The user's previous clipboard contents are restored afterwards.
    func quickFix() {
        log.info("hotkey pressed (trusted=\(Keystroke.isTrusted), checking=\(self.isChecking))")
        guard !isChecking else { return }
        hasAccessibility = Keystroke.isTrusted
        guard hasAccessibility else {
            Keystroke.requestTrust()
            return
        }
        guard !apiKey.isEmpty else {
            error = CheckError.missingKey.localizedDescription
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        let client = GeminiClient(apiKey: apiKey, model: modelID)

        task = Task {
            defer { isChecking = false }

            // Wait until the user lets go of the shortcut modifiers so the target app sees a clean ⌘C.
            await Keystroke.waitForModifiersRelease()

            // Copy the selection and wait for the pasteboard to change.
            let before = pasteboard.changeCount
            Keystroke.command(kVK_ANSI_C)
            var copied: String?
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if pasteboard.changeCount != before {
                    copied = pasteboard.string(forType: .string)
                    break
                }
            }
            guard let original = copied,
                  !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                log.error("copy failed: pasteboard changed=\(pasteboard.changeCount != before)")
                Self.restore(saved, to: pasteboard)
                NSSound.beep() // nothing selected
                return
            }

            // Slack/Asana put mentions and formatting in richer pasteboard types; keep them.
            let rich = RichClipboard.detect(pasteboard)

            isChecking = true
            error = nil
            input = original
            result = nil
            do {
                log.info("copied \(original.count) chars as \(rich.map { "\(type(of: $0))" } ?? "plain text", privacy: .public), calling Gemini")
                let contents: [NSPasteboard.PasteboardType: Data]
                let changed: Bool
                if let rich {
                    (result, contents, changed) = try await Self.fixRich(rich, with: client)
                } else {
                    let fixed = try await client.check(original)
                    result = fixed
                    let replacement = Self.keepingOuterWhitespace(of: original, around: fixed.corrected)
                    contents = [.string: Data(replacement.utf8)]
                    changed = replacement != original
                }
                log.info("Gemini returned \(self.result?.issues.count ?? 0) issues, changed=\(changed)")

                if changed {
                    pasteboard.clearContents()
                    pasteboard.declareTypes(Array(contents.keys), owner: nil)
                    for (type, data) in contents { pasteboard.setData(data, forType: type) }
                    Keystroke.command(kVK_ANSI_V)
                    // Give the target app time to read the pasteboard before restoring it.
                    try? await Task.sleep(for: .milliseconds(400))
                    if showPanelAfterFix { onQuickFixFinished?() }
                }
            } catch {
                log.error("check failed: \(error.localizedDescription, privacy: .public)")
                self.error = error.localizedDescription
                NSSound.beep()
                onQuickFixFinished?()
            }
            Self.restore(saved, to: pasteboard)
        }
    }

    /// Corrects masked rich text. Retries once if the model breaks a placeholder, and never
    /// returns contents that would lose a mention or formatting.
    private static func fixRich(_ rich: MaskedContent, with client: GeminiClient) async throws
        -> (GrammarResult, [NSPasteboard.PasteboardType: Data], Bool) {
        for attempt in 1...2 {
            let fixed = try await client.check(rich.masked, hasPlaceholders: true)
            guard let contents = rich.pasteboardContents(for: fixed.corrected) else {
                log.error("placeholders broken on attempt \(attempt)")
                continue
            }
            let issues = fixed.issues.map {
                GrammarIssue(original: rich.plainText(from: $0.original),
                             suggestion: rich.plainText(from: $0.suggestion),
                             explanation: $0.explanation)
            }
            let display = GrammarResult(corrected: rich.plainText(from: fixed.corrected), issues: issues)
            return (display, contents, fixed.corrected != rich.masked)
        }
        throw CheckError.formattingLost
    }

    func requestAccessibility() {
        Keystroke.requestTrust()
    }

    func refreshAccessibility() {
        hasAccessibility = Keystroke.isTrusted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// The model trims leading/trailing whitespace; keep the selection's original edges.
    private static func keepingOuterWhitespace(of original: String, around corrected: String) -> String {
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + corrected.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }

    // MARK: Panel

    func check() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isChecking else { return }
        isChecking = true
        error = nil
        result = nil
        let client = GeminiClient(apiKey: apiKey, model: modelID)
        task = Task {
            do {
                result = try await client.check(text)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            isChecking = false
        }
    }

    func cancel() {
        task?.cancel()
        isChecking = false
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            input = text
            result = nil
            error = nil
        }
    }

    func copyCorrected() {
        guard let corrected = result?.corrected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(corrected, forType: .string)
    }

    func applyCorrection() {
        guard let corrected = result?.corrected else { return }
        input = corrected
        result = nil
    }

    func saveKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(apiKey)
    }
}
