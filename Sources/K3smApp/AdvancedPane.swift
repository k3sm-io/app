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

/// AdvancedPane is the Settings window's Advanced pane: Write a Bug Report,
/// Live Status and Open Logs (the status item's own actions, `MenuActions`),
/// Uninstall (`UninstallSection`, moved here from the info popover) and
/// Reset to defaults (`PreferencesStore.resetToDefaults`, behind a
/// confirmation).
struct AdvancedPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Diagnostics") {
                HStack(spacing: 12) {
                    Button("Write a Bug Report…") { MenuActions.writeBugReport() }
                        .help(Help.Advanced.bugReport)
                    Button("Live Status") { MenuActions.openLive(.status) }
                        .disabled(app.screen != .status)
                        .help(Help.Advanced.liveStatus)
                    Button("Open Logs") { MenuActions.openLogs(role: app.role) }
                        .help(Help.Advanced.openLogs)
                }
            }
            group("Uninstall") {
                UninstallSection(model: app)
                    .disabled(app.screen != .status)
            }
            group("Preferences") {
                Button("Reset to Defaults…") { settings.confirmingDefaults = true }
                    .help(Help.Advanced.resetDefaults)
            }
        }
        .padding(20)
        .frame(width: SettingsWindowController.paneWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Reset the preferences to their defaults?", isPresented: $settings.confirmingDefaults) {
            Button("Reset", role: .destructive) { settings.resetDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference goes back to its default: the notifications, the window at login, the Dock animation, the status popover's All checks, Quit, the update options, the refresh pace and the appearance. Open at login, the window layout and k3sm itself stay as they are.")
        }
    }

    /// A titled group of rows.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }.padding(.leading, 2)
        }
    }
}

/// UninstallSection removes k3sm through the same verified root step. The
/// data stays unless purge is chosen.
struct UninstallSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Also delete k3sm's data", isOn: $model.purge)
                .help(Help.Advanced.purge)
            Button("Uninstall k3sm…") { model.confirmingUninstall = true }
                .disabled(!model.canUninstall)
                .help(Help.Advanced.uninstall)
                .confirmationDialog(
                    model.purge ? "Uninstall k3sm and delete its data?" : "Uninstall k3sm and keep its data?",
                    isPresented: $model.confirmingUninstall
                ) {
                    Button("Uninstall", role: .destructive) { model.submitUninstall() }
                }
            if let message = model.outcomeMessage, model.running || model.screen == .firstRun {
                Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
