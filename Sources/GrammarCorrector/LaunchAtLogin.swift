import ServiceManagement
import SwiftUI

/// "Open at login" toggle backed by SMAppService (shows up in System Settings → Login Items).
struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Open at login", isOn: Binding(get: { isOn }, set: update))
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
    }

    private func update(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = "Couldn't change login item: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        if status == .requiresApproval {
            note = "Allow it in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        } else if note?.hasPrefix("Allow") == true {
            note = nil
        }
    }
}
