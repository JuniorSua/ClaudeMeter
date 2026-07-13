import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem, its custom content view, and the popover.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let contentView = StatusBarView()
    private let popover = NSPopover()

    private let store: UsageStore
    private let settingsStore: SettingsStore
    private let openSettings: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(store: UsageStore, settingsStore: SettingsStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.settingsStore = settingsStore
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: button.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                settingsStore: settingsStore,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                },
                quit: { NSApp.terminate(nil) }
            )
        )

        Publishers.CombineLatest(store.$snapshot, settingsStore.$settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot, settings in
                self?.update(snapshot: snapshot, settings: settings)
            }
            .store(in: &cancellables)

        // A popover opened in one Space keeps stale coordinates after a Space
        // switch (e.g. anchored above the screen from a fullscreen Space's
        // hidden menu bar) — close it instead of letting it float misplaced.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeSpaceChanged() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func update(snapshot: UsageSnapshot?, settings: AppSettings) {
        // Default (Auto): the menu bar is ALWAYS two tiny stacked lines —
        // session % on top, weekly % below. When official data hasn't loaded
        // yet, show quiet placeholder dashes rather than token counts.
        if settings.displayMode == .auto {
            let stacked = MenuBarFormatter.stackedDisplay(snapshot: snapshot)
                ?? MenuBarFormatter.StackedDisplay(topText: "–", topPercent: 0, bottomText: "–", bottomPercent: 0)
            contentView.content = .stacked(stacked)
            statusItem.length = contentView.intrinsicContentSize.width
            return
        }
        // Explicit non-auto display modes keep the single-line text layout.
        apply(mode: settings.displayMode, snapshot: snapshot, settings: settings, degradeIfHidden: false)
    }

    /// Applies a text display mode; in Auto, if the menu bar has no room the
    /// system gives the item no window — degrade full → compact →
    /// ultraCompact until it fits.
    private func apply(mode: DisplayMode, snapshot: UsageSnapshot?, settings: AppSettings, degradeIfHidden: Bool) {
        let display = MenuBarFormatter.display(snapshot: snapshot, settings: settings, mode: mode)
        contentView.content = .single(text: display.text, percentage: display.percentage)
        statusItem.length = contentView.intrinsicContentSize.width

        guard degradeIfHidden, let smaller = Self.nextSmaller(mode) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.contentView.window == nil {
                self.apply(mode: smaller, snapshot: snapshot, settings: settings, degradeIfHidden: true)
            }
        }
    }

    private static func nextSmaller(_ mode: DisplayMode) -> DisplayMode? {
        switch mode {
        case .auto, .full: return .compact
        case .compact: return .ultraCompact
        case .ultraCompact: return nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button, button.window != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.loadProfiles()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            clampPopoverToVisibleScreen()
        }
    }

    /// If the anchor put the popover partially above the usable screen area
    /// (hidden menu bar in fullscreen Spaces), move it fully on screen.
    private func clampPopoverToVisibleScreen() {
        guard let window = popover.contentViewController?.view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let topLimit = screen.visibleFrame.maxY
        if frame.maxY > topLimit {
            frame.origin.y = topLimit - frame.height
            window.setFrame(frame, display: true)
        }
    }
}
