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

import Foundation

/// AppPreferences is the app's own settings, typed keys over a `UserDefaults`
/// domain (the standard one in the app, a fresh suite in tests), each with
/// its default: a key that is absent, or holds a value of another type,
/// reads as the default and never fails. These are per-user and per-app,
/// take effect at once and need no administrator; anything that changes
/// what k3sm's daemons do is a node setting instead, recorded by k3sm and
/// read back from its status. `reset` puts every preference back; the
/// console's remembered layout is separate, and `resetLayout` clears it,
/// the tables' column widths with it (`resetColumnWidths` clears only those).
public struct AppPreferences: @unchecked Sendable {
    /// The boolean preferences, by user-defaults key.
    public enum Key: String, CaseIterable, Sendable {
        /// Post "k3sm is stopped" at login when it is (`StoppedNotice`).
        case notifyStoppedAtLogin = "pref.notifyStoppedAtLogin"
        /// Open the window on a launch at login too, not only the status item.
        case openWindowAtLogin = "pref.openWindowAtLogin"
        /// Beat the wings of the Dock icon's mark while the console is up.
        case dockAnimation = "pref.dockAnimation"
        /// Open the info popover's "All checks" disclosure, as the user left it.
        case allChecksOpen = "pref.allChecksOpen"
        /// Pass `--drain` to `k3sm update apply` (`UpdateOptions.drain`).
        case updateDrain = "pref.updateDrain"
        /// Post a notification when an update becomes available (`UpdateNotice`).
        case notifyUpdate = "pref.notifyUpdate"
        /// Run the Stop action before the app quits (`QuitPolicy`).
        case stopOnQuit = "pref.stopOnQuit"

        /// The value when nothing usable is stored.
        public var defaultValue: Bool {
            switch self {
            case .notifyStoppedAtLogin: true
            case .openWindowAtLogin: false
            case .dockAnimation: true
            case .allChecksOpen: false
            case .updateDrain: false
            case .notifyUpdate: true
            case .stopOnQuit: false
            }
        }
    }

    /// The update's signature policy, an `UpdateSignaturePolicy` word.
    public static let updateSignatureKey = "pref.updateSignature"
    /// How often the app reads k3sm, a `PollProfile` word.
    public static let pollProfileKey = "pref.pollProfile"
    /// The app's appearance, an `AppAppearance` word.
    public static let appearanceKey = "pref.appearance"
    /// The release the update notification last named (`UpdateNotice.release`).
    /// It is a record, not a preference: Reset to Defaults keeps it, so the
    /// same release is never announced twice.
    public static let updateNotifiedKey = "updateNotifiedRelease"
    /// The release the version-set question after a self-update was last
    /// answered for (`VersionSetOffer`), yes or no. A record, not a
    /// preference: Reset to Defaults keeps it, so the question is not asked
    /// again for the same release.
    public static let versionSetAnsweredKey = "versionSetAnsweredTag"
    /// The Settings window's last pane.
    public static let settingsPaneKey = "settingsPane"
    /// The Settings window's frame and screen, a `WindowFrame.Saved` value.
    public static let settingsFrameKey = "settingsWindowFrame"
    /// The console panel's Cluster or This Mac choice.
    public static let panelModeKey = "consolePanelMode"
    /// Whether the console shows its details column.
    public static let inspectorShownKey = "consoleInspectorShown"
    /// The console's layout as the user left it: the panel's view, width
    /// and collapsed state, the details column and its width, the log pane's height, and every table's column
    /// widths. Reset Window Layout
    /// clears these and nothing else (not the tab, the searches or the
    /// selections, which are what the user was looking at, not a layout).
    public static let layoutKeys = [panelModeKey, inspectorShownKey, PanelLayout.widthKey, PanelLayout.collapsedKey,
                                    InspectorWidth.key, LogPaneHeight.key]
        + columnKeys
    /// Each table's column widths, one key per `ConsoleTable`.
    public static let columnKeys = ConsoleTable.allCases.map(columnWidthsKey)

    /// The key `table`'s column widths are kept under.
    public static func columnWidthsKey(_ table: ConsoleTable) -> String {
        "columnWidths." + table.rawValue
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored value of `key`, or its default.
    public func bool(_ key: Key) -> Bool {
        (defaults.object(forKey: key.rawValue) as? Bool) ?? key.defaultValue
    }

    /// Stores `value` for `key`.
    public func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    public var notifyStoppedAtLogin: Bool {
        get { bool(.notifyStoppedAtLogin) }
        nonmutating set { set(newValue, for: .notifyStoppedAtLogin) }
    }

    public var openWindowAtLogin: Bool {
        get { bool(.openWindowAtLogin) }
        nonmutating set { set(newValue, for: .openWindowAtLogin) }
    }

    public var dockAnimation: Bool {
        get { bool(.dockAnimation) }
        nonmutating set { set(newValue, for: .dockAnimation) }
    }

    public var allChecksOpen: Bool {
        get { bool(.allChecksOpen) }
        nonmutating set { set(newValue, for: .allChecksOpen) }
    }

    public var updateDrain: Bool {
        get { bool(.updateDrain) }
        nonmutating set { set(newValue, for: .updateDrain) }
    }

    public var notifyUpdate: Bool {
        get { bool(.notifyUpdate) }
        nonmutating set { set(newValue, for: .notifyUpdate) }
    }

    public var stopOnQuit: Bool {
        get { bool(.stopOnQuit) }
        nonmutating set { set(newValue, for: .stopOnQuit) }
    }

    /// The stored poll profile, through `PollProfile.restore`.
    public var pollProfile: PollProfile {
        get { PollProfile.restore(from: defaults.object(forKey: Self.pollProfileKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.pollProfileKey) }
    }

    /// The stored appearance, through `AppAppearance.restore`.
    public var appearance: AppAppearance {
        get { AppAppearance.restore(from: defaults.object(forKey: Self.appearanceKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.appearanceKey) }
    }

    /// The release the update notification last named; nil before the first.
    public var updateNotifiedRelease: String? {
        get { defaults.object(forKey: Self.updateNotifiedKey) as? String }
        nonmutating set { defaults.set(newValue, forKey: Self.updateNotifiedKey) }
    }

    /// The release the version-set question was last answered for; nil
    /// before the first answer.
    public var versionSetAnsweredTag: String? {
        get { defaults.object(forKey: Self.versionSetAnsweredKey) as? String }
        nonmutating set { defaults.set(newValue, forKey: Self.versionSetAnsweredKey) }
    }

    /// The stored signature policy; a missing value, another type or a word
    /// this build does not know reads as `ifSigned`, the CLI's default.
    public var updateSignature: UpdateSignaturePolicy {
        get { (defaults.object(forKey: Self.updateSignatureKey) as? String).flatMap(UpdateSignaturePolicy.init(rawValue:)) ?? .ifSigned }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.updateSignatureKey) }
    }

    /// The managed update's options as stored, read once when Update is
    /// clicked. Allowing a downgrade is never stored: the confirmation
    /// offers it for that one apply, off each time.
    public var updateOptions: UpdateOptions {
        UpdateOptions(drain: updateDrain, allowDowngrade: false, signature: updateSignature)
    }

    /// The Settings window's last pane, restored through `SettingsPane.restore`.
    public var settingsPane: SettingsPane {
        get { SettingsPane.restore(from: defaults.object(forKey: Self.settingsPaneKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.settingsPaneKey) }
    }

    /// Puts every preference and the Settings window's pane back to the
    /// default by removing what is stored.
    public func reset() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        defaults.removeObject(forKey: Self.updateSignatureKey)
        defaults.removeObject(forKey: Self.pollProfileKey)
        defaults.removeObject(forKey: Self.appearanceKey)
        defaults.removeObject(forKey: Self.settingsPaneKey)
    }

    /// The column widths kept for `layout`'s table (`ColumnWidths.restore`).
    public func columnWidths(_ layout: TableColumns) -> ColumnWidths {
        ColumnWidths.restore(layout, from: defaults.object(forKey: Self.columnWidthsKey(layout.table)))
    }

    /// Keeps `widths` for its table; widths all at their default store nothing.
    public func setColumnWidths(_ widths: ColumnWidths) {
        let key = Self.columnWidthsKey(widths.table)
        if widths.isDefault {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(widths.stored, forKey: key)
        }
    }

    /// Puts every table's columns back to their default widths.
    public func resetColumnWidths() {
        for key in Self.columnKeys { defaults.removeObject(forKey: key) }
    }

    /// Clears the console's remembered layout (`layoutKeys`) only.
    public func resetLayout() {
        for key in Self.layoutKeys { defaults.removeObject(forKey: key) }
    }

    /// Whether a launch opens the window: any launch the user made does; a
    /// launch at login, or one with `LaunchPolicy.backgroundArgument`, does
    /// only with `openWindowAtLogin`.
    public func opensWindow(loginLaunch: Bool, background: Bool = false) -> Bool {
        !(loginLaunch || background) || openWindowAtLogin
    }

    /// Whether the first poll of this launch is checked for the stopped
    /// notice: only at login, and only with `notifyStoppedAtLogin`.
    public func checksStoppedNotice(loginLaunch: Bool) -> Bool {
        loginLaunch && notifyStoppedAtLogin
    }
}

/// AppAppearance is the app's appearance, a General preference: System,
/// which follows macOS as the app always has, or Light or Dark for the
/// app's own windows, popover and menus whatever macOS is set to. The menu
/// bar item is not the app's to change: it follows the menu bar.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// The appearance when nothing usable is stored.
    public static let defaultAppearance: AppAppearance = .system

    /// The picker's item.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The `NSAppearance.Name` raw value the app sets on itself, nil for
    /// System, which clears the app's own so it follows macOS again. Kept
    /// as strings here so the mapping is tested without AppKit's runtime.
    public var appearanceName: String? {
        switch self {
        case .system: nil
        case .light: "NSAppearanceNameAqua"
        case .dark: "NSAppearanceNameDarkAqua"
        }
    }

    /// A stored appearance word, or System for anything else (absent,
    /// another type, a word this build does not know).
    public static func restore(from stored: Any?) -> AppAppearance {
        (stored as? String).flatMap(AppAppearance.init(rawValue:)) ?? defaultAppearance
    }
}

/// SettingsPane is one pane of the Settings window, in toolbar order. The
/// list is data: a later pane adds a case and an entry in `shown`, and a pane
/// not built yet is not listed, never shown disabled.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general
    /// The node's role and its cluster install settings, read-only.
    case cluster
    /// The LAN switch, moved here from the info popover.
    case network
    /// The data volume and the release base, read-only.
    case storage
    /// The installed and available releases, Update Now, the roll's
    /// progress and the update options.
    case updates
    /// The bug report, the logs, Live Status, Uninstall and Reset to defaults.
    case advanced

    /// The panes the window shows, in order.
    public static let shown: [SettingsPane] = [.general, .cluster, .network, .storage, .updates, .advanced]

    /// The toolbar label and the window title.
    public var title: String {
        switch self {
        case .general: "General"
        case .cluster: "Cluster"
        case .network: "Network"
        case .storage: "Storage"
        case .updates: "Updates"
        case .advanced: "Advanced"
        }
    }

    /// The SF Symbol on the toolbar item.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .cluster: "server.rack"
        case .network: "network"
        case .storage: "externaldrive"
        case .updates: "arrow.triangle.2.circlepath"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// A stored pane id, or the first shown pane for anything else (absent,
    /// another type, an id this build does not know or does not show).
    public static func restore(from stored: Any?) -> SettingsPane {
        if let id = stored as? String, let pane = SettingsPane(rawValue: id), shown.contains(pane) { return pane }
        return shown[0]
    }
}

/// LoginItemStatus is the app's login item as the system reports it, the
/// four cases of `SMAppService.Status` without importing it here.
public enum LoginItemStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// LoginItemDisplay is the General pane's Open at login control: on while
/// the app is registered (approved or waiting for approval), off otherwise;
/// a change is offered only to a copy in /Applications, the only place the
/// app registers from; and the note says why when the system needs the
/// user's approval, cannot find the app, or refused the last change.
public struct LoginItemDisplay: Equatable, Sendable {
    public let isOn: Bool
    public let isEnabled: Bool
    /// The line under the checkbox, nil when there is nothing to explain.
    public let note: String?
    /// Whether to offer a button that opens System Settings at Login Items.
    public let offersLoginItems: Bool

    public static let approvalNote = "Waiting for your approval in System Settings > General > Login Items."
    public static let applicationsNote = "k3sm can open at login only when it runs from the Applications folder."
    public static let notFoundNote = "macOS cannot find this copy of k3sm as a login item. Open k3sm from the Applications folder."

    public static func decide(status: LoginItemStatus, inApplications: Bool, error: String?) -> LoginItemDisplay {
        let isOn: Bool
        var note: String?
        var offers = false
        switch status {
        case .enabled:
            isOn = true
        case .requiresApproval:
            isOn = true
            note = approvalNote
            offers = true
        case .notRegistered:
            isOn = false
            if !inApplications { note = applicationsNote }
        case .notFound:
            isOn = false
            note = inApplications ? notFoundNote : applicationsNote
        }
        // A registered app can always be taken off; turning one on needs /Applications.
        let enabled = isOn || inApplications
        if let error {
            note = "macOS did not change the login item: " + StatusDisplay.errorText(error)
        }
        return LoginItemDisplay(isOn: isOn, isEnabled: enabled, note: note, offersLoginItems: offers)
    }

    public init(isOn: Bool, isEnabled: Bool, note: String?, offersLoginItems: Bool) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.note = note
        self.offersLoginItems = offersLoginItems
    }
}

/// DockAnimationDisplay is the General pane's Dock animation checkbox: the
/// preference as stored, except under Reduce Motion, where the icon is
/// always still, so the box shows off, cannot be changed, and says why.
public struct DockAnimationDisplay: Equatable, Sendable {
    public let isOn: Bool
    public let isEnabled: Bool
    public let note: String?

    public static let reduceMotionNote = "Reduce Motion is on in Accessibility settings, so the icon stays still."

    public static func decide(preference: Bool, reduceMotion: Bool) -> DockAnimationDisplay {
        reduceMotion
            ? DockAnimationDisplay(isOn: false, isEnabled: false, note: reduceMotionNote)
            : DockAnimationDisplay(isOn: preference, isEnabled: true, note: nil)
    }

    public init(isOn: Bool, isEnabled: Bool, note: String?) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.note = note
    }
}

/// AppWindow names the app's windows.
public enum AppWindow: Hashable, Sendable {
    case console
    case settings
}

/// WindowPresence is the one activation rule for every window: the app is a
/// regular app (Dock icon, app menu, Command-Tab) while any of its windows is
/// open, and an accessory with only the status item once the last closes.
/// `opened` and `closed` return whether the app should be regular now.
public struct WindowPresence: Sendable {
    private var open: Set<AppWindow> = []

    public init() {}

    public var regular: Bool { !open.isEmpty }

    public mutating func opened(_ window: AppWindow) -> Bool {
        open.insert(window)
        return regular
    }

    public mutating func closed(_ window: AppWindow) -> Bool {
        open.remove(window)
        return regular
    }
}
