import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private var usageStore: UsageStore!
    private var statusController: StatusItemController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        usageStore = UsageStore(settingsStore: settingsStore)
        statusController = StatusItemController(
            store: usageStore,
            settingsStore: settingsStore,
            openSettings: { [weak self] in self?.showSettings() }
        )
        usageStore.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageStore.stop()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settingsStore: settingsStore, store: usageStore)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "ClaudeMeter Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
