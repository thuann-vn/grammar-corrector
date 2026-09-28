import AppKit
import Combine
import SwiftUI

@main
struct GrammarCorrectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The UI lives in the status item's popover (see AppDelegate); no windows here.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the menu bar icon and its popover. Unlike SwiftUI's MenuBarExtra, an NSPopover
/// can be opened from code, so the panel can pop up after a ⇧⌘C fix.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = CheckerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.normal
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: ContentView().environmentObject(model))
        host.sizingOptions = .preferredContentSize // popover follows the content's size
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        model.$isChecking
            .sink { [weak self] busy in
                self?.statusItem.button?.image = busy ? MenuBarIcon.busy : MenuBarIcon.normal
            }
            .store(in: &cancellables)

        model.onQuickFixFinished = { [weak self] in
            self?.showPopover(activate: false)
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover(activate: true)
    }

    /// `activate: false` shows the panel without stealing focus from the app being typed in.
    private func showPopover(activate: Bool) {
        guard let button = statusItem.button else { return }
        if activate { NSApp.activate() }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // A transient popover only closes on outside clicks while we're the active app,
        // so also watch clicks in other apps.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.popover.performClose(nil) }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}
