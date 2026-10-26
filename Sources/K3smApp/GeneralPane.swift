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

import K3smStatus
import SwiftUI

/// GeneralPane is the Settings window's General pane: Open at login (the
/// real login item, with the system's reason when it needs approval or
/// refused), the stopped notice at login, the window at login, whether Quit
/// stops k3sm first (`QuitPolicy`, off by default), the app's
/// appearance (`AppAppearance`), the Dock
/// animation (off and disabled under Reduce Motion), the poll profile
/// (`PollProfile`), the tour and Reset Window Layout, and the app's own version (`AppVersion.title`). Its state
/// is on `SettingsModel` and `PreferencesStore`.
struct GeneralPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Login") {
                let login = settings.login
                Toggle("Open k3sm at login", isOn: Binding(get: { login.isOn }, set: { settings.setLogin($0) }))
                    .disabled(!login.isEnabled)
                    .help(Help.General.openAtLogin)
                if let text = login.note { note(text) }
                if login.offersLoginItems {
                    Button("Open Login Items") { settings.openLoginItems() }
                        .help(Help.Popover.openLoginItems)
                }
                Toggle("Open the window when k3sm opens at login", isOn: $preferences.openWindowAtLogin)
                    .help(Help.General.windowAtLogin)
                Toggle("Notify me at login when k3sm is stopped", isOn: $preferences.notifyStoppedAtLogin)
                    .help(Help.General.notifyStopped)
            }
            group("Quit") {
                Toggle(QuitPolicy.toggleLabel, isOn: $preferences.stopOnQuit)
                    .help(Help.General.stopOnQuit)
                note(QuitPolicy.paneNote)
            }
            group("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(Help.General.appearance)
            }
            group("Dock") {
                let dock = settings.dock
                Toggle("Animate the Dock icon while the window is open",
                       isOn: Binding(get: { dock.isOn }, set: { preferences.dockAnimation = $0 }))
                    .disabled(!dock.isEnabled)
                    .help(Help.General.dockAnimation)
                if let text = dock.note { note(text) }
            }
            group("Status") {
                Picker("Status refresh", selection: $preferences.pollProfile) {
                    ForEach(PollProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .fixedSize()
                .help(Help.General.pollProfile)
                note(PollProfile.paneNote)
            }
            group("Window") {
                HStack(spacing: 12) {
                    Button("Take the Tour") { settings.takeTour() }
                        .disabled(!settings.tourAvailable)
                        .help(Help.General.tour(available: settings.tourAvailable))
                    Button("Reset Window Layout…") { settings.confirmingReset = true }
                        .help(Help.General.resetLayout)
                }
            }
            group("Version") {
                Text(verbatim: SelfCheck.appVersion().title)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: SettingsWindowController.paneWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Reset the window layout?", isPresented: $settings.confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The console's panel goes back to its first width and view, shown, the details column is shown again, and every table's columns go back to their first widths. Tabs, searches and selections stay.")
        }
    }

    /// A titled group of rows.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }.padding(.leading, 2)
        }
    }

    /// A secondary line under a control.
    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
