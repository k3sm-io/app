/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import AppKit
import Combine
import K3smStatus
import SwiftUI

/// SettingsModel is the Settings window's state (no view holds any): the
/// login item as the system reports it, Reduce Motion, whether the tour can
/// run, and the two reset confirmations; and the actions the General and
/// Advanced panes run. The Cluster, Network, Storage and Updates panes and
/// Uninstall read and act on `app`.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var login = LoginItemDisplay.decide(status: .notRegistered, inApplications: false, error: nil)
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Whether the console is the window's screen, the only one the tour walks.
    @Published private(set) var tourAvailable = false
    /// Whether the Reset Window Layout confirmation is up.
    @Published var confirmingReset = false
    /// Whether the Reset to Defaults confirmation is up.
    @Published var confirmingDefaults = false

    let preferences: PreferencesStore
    let app: AppModel
    private let showConsole: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []
    private var screen: AnyCancellable?

    init(app: AppModel, preferences: PreferencesStore, showConsole: @escaping @MainActor () -> Void) {
        self.app = app
        self.preferences = preferences
        self.showConsole = showConsole
        screen = app.$screen.sink { [weak self] screen in
            MainActor.assumeIsolated { self?.tourAvailable = screen == .status }
        }
        // The user may approve the login item, or turn Reduce Motion on, in
        // System Settings while this window is open; both are read again
        // when the app comes back and when the display options change.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLogin() }
        })
        refreshLogin()
    }

    var dock: DockAnimationDisplay {
        DockAnimationDisplay.decide(preference: preferences.dockAnimation, reduceMotion: reduceMotion)
    }

    /// Reads the login item's status again, with no error to show.
    func refreshLogin() {
        showLogin(error: nil)
    }

    /// Registers or unregisters the login item, then shows what the system
    /// reports, with its reason when it refused.
    func setLogin(_ enabled: Bool) {
        var failure: String?
        do {
            try LoginItem.set(enabled: enabled)
        } catch {
            failure = error.localizedDescription
            log.error("login item: change refused: \(error.localizedDescription, privacy: .public)")
        }
        showLogin(error: failure)
    }

    private func showLogin(error: String?) {
        let status = LoginItem.status()
        login = LoginItemDisplay.decide(status: status, inApplications: LoginItem.inApplications(), error: error)
        app.loginItemNeedsApproval = status == .requiresApproval
    }

    func openLoginItems() {
        LoginItem.openSettings()
    }

    /// Brings the console forward and starts the tour there.
    func takeTour() {
        guard tourAvailable else { return }
        showConsole()
        app.statusPanelShown = false
        app.tour.start()
    }

    /// Puts the console's layout back to how a first launch shows it: the
    /// running window follows at once, and the stored keys are removed.
    func resetLayout() {
        // A running tour would put its saved layout back over the reset.
        app.tour.end()
        app.panelMode = nil
        app.inspectorShown = true
        app.consolePanelCollapsed = false
        app.resetPanelWidth()
        app.columns.resetAll()
        preferences.preferences.resetLayout()
        log.notice("settings: window layout reset")
    }

    /// Puts every preference back to its default (`AppPreferences.reset`);
    /// the login item, the window layout and k3sm itself are left alone.
    func resetDefaults() {
        preferences.resetToDefaults()
        log.notice("settings: preferences reset to defaults")
    }
}

/// SettingsWindowController owns the Settings window: a toolbar of panes
/// (`SettingsPane.shown`, so a later pane is one more entry there), each a
/// SwiftUI view in an `NSHostingView`, the window sized to the pane and
/// titled by it. It remembers the last pane (`AppPreferences.settingsPane`)
/// and where it was (a `WindowFrame.Saved` under
/// `AppPreferences.settingsFrameKey`, saved on every move and close and put
/// back through `WindowFrame.restore`, the console's clamp), and shares the console's
/// activation rule through `AppActivation`: while it is open the app is in
/// the Dock, as it is while the console is.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// The one Settings window's controller, set by the app delegate, for
    /// the console strip's gear.
    static var shared: SettingsWindowController?

    private static let toolbarID = "io.k3sm.app.settings.toolbar"
    /// The panes' width; each pane sets its own height.
    static let paneWidth: CGFloat = 520

    private let model: SettingsModel
    private var window: NSWindow?
    private var pane: SettingsPane

    init(model: SettingsModel) {
        self.model = model
        self.pane = model.preferences.preferences.settingsPane
    }

    /// Shows the window, creating it on first use, at the last pane.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refreshLogin()
        AppActivation.opened(.settings)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Shows the window at `pane` (the update notification's click opens Updates).
    func show(pane: SettingsPane) {
        show()
        guard let window, pane != self.pane, SettingsPane.shown.contains(pane) else { return }
        show(pane, in: window, keepTop: true)
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        model.confirmingReset = false
        model.confirmingDefaults = false
        AppActivation.closed(.settings)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    /// Records the window's frame and its screen. A window on no screen
    /// records nothing.
    private func saveFrame() {
        guard let window, let screen = window.screen else { return }
        let f = window.frame
        let saved = WindowFrame.Saved(
            frame: WindowFrame.Rect(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height),
            screen: screen.k3smIdentity)
        UserDefaults.standard.set(saved.defaultsValue, forKey: AppPreferences.settingsFrameKey)
    }

    /// Puts the window back where it was, at the current pane's size with
    /// the saved top edge kept, clamped onto a connected screen by
    /// `WindowFrame.restore`; centres it when nothing is saved.
    private func placeWindow(_ window: NSWindow) {
        let size = window.frame.size
        let stored = WindowFrame.Saved(defaultsValue: UserDefaults.standard.object(forKey: AppPreferences.settingsFrameKey))
        let saved = stored.map { s in
            WindowFrame.Saved(frame: WindowFrame.Rect(x: s.frame.x, y: s.frame.maxY - Double(size.height),
                                                      width: Double(size.width), height: Double(size.height)),
                              screen: s.screen)
        }
        let minimum = WindowFrame.Size(width: Double(size.width), height: Double(size.height))
        guard let frame = WindowFrame.restore(saved: saved, screens: NSScreen.k3smScreens(), minimum: minimum) else {
            window.center()
            return
        }
        window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: Self.toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        show(pane, in: window, keepTop: false)
        // Placed once the pane has sized it; the delegate is set last, so
        // only the user's moves from here on are saved.
        placeWindow(window)
        window.delegate = self
        return window
    }

    /// Puts `pane` in the window: its view, the selected toolbar item, the title.
    private func show(_ pane: SettingsPane, in window: NSWindow, keepTop: Bool) {
        self.pane = pane
        model.preferences.preferences.settingsPane = pane
        window.toolbar?.selectedItemIdentifier = Self.identifier(pane)
        window.title = pane.title
        window.contentView = NSHostingView(rootView: Self.view(for: pane, model: model))
        fit(window, keepTop: keepTop)
    }

    /// Sizes the window to its pane, keeping the top edge where it is.
    private func fit(_ window: NSWindow, keepTop: Bool) {
        guard let content = window.contentView else { return }
        let size = NSSize(width: Self.paneWidth, height: max(content.fittingSize.height, 120))
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var origin = window.frame.origin
        if keepTop { origin.y += window.frame.height - frame.height }
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: keepTop && window.isVisible)
    }

    /// The SwiftUI view of each pane.
    private static func view(for pane: SettingsPane, model: SettingsModel) -> AnyView {
        switch pane {
        case .general: AnyView(GeneralPane(settings: model, preferences: model.preferences))
        case .cluster, .storage: AnyView(NodeSettingsPaneView(pane: pane, app: model.app))
        case .network: AnyView(NetworkPane(app: model.app, nodes: model.app.workloads.nodeList))
        case .updates: AnyView(UpdatesPane(app: model.app, preferences: model.preferences))
        case .advanced: AnyView(AdvancedPane(settings: model, app: model.app))
        }
    }

    private static func identifier(_ pane: SettingsPane) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("io.k3sm.app.settings.\(pane.rawValue)")
    }

    @objc private func choose(_ sender: NSToolbarItem) {
        guard let window, let pane = SettingsPane.shown.first(where: { Self.identifier($0) == sender.itemIdentifier }),
              pane != self.pane else { return }
        show(pane, in: window, keepTop: true)
    }

    // MARK: NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { SettingsPane.shown.map(Self.identifier) }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { SettingsPane.shown.map(Self.identifier) }
    }

    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { SettingsPane.shown.map(Self.identifier) }
    }

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let pane = SettingsPane.shown.first(where: { Self.identifier($0) == itemIdentifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = pane.title
            item.toolTip = Help.SettingsWindow.pane(pane).text
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.target = self
            item.action = #selector(choose(_:))
            return item
        }
    }
}
