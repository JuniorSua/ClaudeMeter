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
        scheduleDebugSnapshotIfRequested()
    }

    /// Debug aid: CLAUDEMETER_SNAPSHOT=/path.png renders the popover view to
    /// a PNG shortly after launch (once data has loaded) — lets UI changes be
    /// eyeballed without opening the menu bar popover by hand.
    private func scheduleDebugSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLAUDEMETER_SNAPSHOT"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            let view = PopoverView(
                store: self.usageStore,
                settingsStore: self.settingsStore,
                openSettings: {},
                quit: {}
            )
            Self.writeSnapshot(of: view, size: NSSize(width: 320, height: 600), to: path)
            // The trend card can sit below the popover fold; render it alone
            // too so layout checks cover it.
            if let trend = self.usageStore.snapshot?.dailyTrend {
                let card = CardView(title: "Last 7 Days") { DailyTrendChart(days: trend) }
                    .padding(12)
                    .frame(width: 320)
                Self.writeSnapshot(of: card, size: NSSize(width: 320, height: 140),
                                   to: (path as NSString).deletingPathExtension + "-trend.png")
            }
        }
    }

    private static func writeSnapshot<V: View>(of view: V, size: NSSize, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
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
