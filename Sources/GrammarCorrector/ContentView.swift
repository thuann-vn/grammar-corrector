import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: CheckerModel
    @State private var showSettings = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showSettings || model.apiKey.isEmpty {
                SettingsView(showSettings: $showSettings)
            } else {
                hotKeyHint
                editor
                actions
                results
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { model.refreshAccessibility() }
    }

    private var header: some View {
        HStack {
            Label("Grammar Corrector", systemImage: "text.badge.checkmark")
                .font(.headline)
            Spacer()
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit")
        }
    }

    @ViewBuilder
    private var hotKeyHint: some View {
        if model.hasAccessibility {
            Label("Select text in any app and press \(model.shortcut.display) to fix it in place.", systemImage: "keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Label("\(model.shortcut.display) needs Accessibility permission to copy & paste for you.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption)
                Spacer()
                Button("Grant…") { model.requestAccessibility() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
        }
    }

    private var editor: some View {
        TextEditor(text: $model.input)
            .font(.body)
            .frame(height: 130)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .overlay(alignment: .topLeading) {
                if model.input.isEmpty {
                    Text("Type or paste text to check…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }

    private var actions: some View {
        HStack {
            Button("Paste", systemImage: "doc.on.clipboard") { model.pasteFromClipboard() }
            Button("Clear") { model.input = ""; model.result = nil; model.error = nil }
                .disabled(model.input.isEmpty)
            Spacer()
            if model.isChecking {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel() }
            } else {
                Button("Check") { model.check() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("⌘↩")
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
        } else if let result = model.result {
            Divider()
            if result.issues.isEmpty {
                Label("Looks good — no issues found.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Suggested correction").font(.subheadline.bold())
                CappedScrollView(maxHeight: 110) {
                    Text(result.corrected)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        model.copyCorrected()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Button("Use in editor") { model.applyCorrection() }
                }

                Text("\(result.issues.count) change\(result.issues.count == 1 ? "" : "s")")
                    .font(.subheadline.bold())
                CappedScrollView(maxHeight: 180) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.issues) { IssueRow(issue: $0) }
                    }
                }
            }
        }
    }
}

/// A ScrollView as tall as its content, up to `maxHeight`. A plain ScrollView with only a
/// max height collapses to zero inside the self-sizing menu bar window.
struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { contentHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in contentHeight = height }
                }
            )
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

struct IssueRow: View {
    let issue: GrammarIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(issue.original).strikethrough().foregroundStyle(.red)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(issue.suggestion).foregroundStyle(.green).bold()
            }
            Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: CheckerModel
    @Binding var showSettings: Bool
    @State private var keyDraft = ""
    @AppStorage("geminiModel") private var modelID = "gemini-flash-latest"
    @AppStorage("showPanelAfterFix") private var showPanelAfterFix = true

    private let models = [
        ("gemini-flash-latest", "Gemini Flash (recommended)"),
        ("gemini-flash-lite-latest", "Gemini Flash-Lite (fastest)"),
        ("gemini-pro-latest", "Gemini Pro (most careful, slower)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gemini API key").font(.subheadline.bold())
            SecureField("AIza…", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
            Text("Stored in your macOS Keychain. Get a key at aistudio.google.com/apikey.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Model", selection: $modelID) {
                ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
            }

            Toggle("Show the changes after fixing with the shortcut", isOn: $showPanelAfterFix)
            LaunchAtLoginToggle()

            HStack {
                Text("Fix-in-place shortcut")
                Spacer()
                Button {
                    model.isRecordingShortcut ? model.stopRecordingShortcut() : model.startRecordingShortcut()
                } label: {
                    Text(model.isRecordingShortcut ? "Press keys… (Esc to cancel)" : model.shortcut.display)
                        .frame(minWidth: 70)
                }
                .help("Click, then press the new key combo")
                if model.shortcut != .default {
                    Button("Reset") { model.shortcut = .default }
                        .buttonStyle(.borderless)
                }
            }

            HStack {
                Spacer()
                Button("Save") {
                    model.saveKey(keyDraft)
                    if !model.apiKey.isEmpty { showSettings = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .onAppear { keyDraft = model.apiKey }
        .onDisappear { if model.isRecordingShortcut { model.stopRecordingShortcut() } }
    }
}
