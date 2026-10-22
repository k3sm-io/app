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

/// UpdatesPane is the Settings window's Updates pane: the installed and the
/// available release with the `update` row's state in plain words
/// (`UpdatesPaneFacts`), Update Now (`UpdateNowControl` over the one update
/// plan, `UpdatePlan`, run by `AppModel.performUpdate`) with the plan's line
/// under it, the roll's progress in the console's own
/// panel (`UpdateProgressPanel`, with its Cancel), and the two stored
/// options passed to `k3sm update apply` (drain and the signature policy,
/// `UpdateOptions`, in `PreferencesStore`); allowing a downgrade is asked in
/// the confirmation, for one apply only. The notification preference
/// (`UpdateNotice`) sits under the releases. The app's own line
/// (`AppUpdateState`, with the last check's age, Check Now, the two app
/// update preferences and the persistent "app ahead of cluster" line,
/// `AppAheadOfCluster`) sits between them.
/// Opening the pane reads the status again, so the offer is never judged on
/// a stale read.
struct UpdatesPane: View {
    @ObservedObject var app: AppModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        let facts = UpdatesPaneFacts.decide(report: app.lanReport, installed: app.installedVersion)
        let plan = app.updatePlan
        let control = UpdateNowControl.decide(plan: plan, report: app.lanReport)
        VStack(alignment: .leading, spacing: 18) {
            group("Releases") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Installed").foregroundStyle(.secondary)
                        Text(verbatim: facts.installed).monospacedDigit().help(Help.Updates.installed)
                    }
                    GridRow {
                        Text("Available").foregroundStyle(.secondary)
                        Text(verbatim: facts.available).monospacedDigit().help(Help.Updates.available)
                    }
                }
                Text(verbatim: facts.state).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Help.Updates.state)
                Button(UpdateNowControl.title) { app.performUpdate() }
                    .disabled(!control.enabled)
                    .help(Help.Updates.updateNow(control, plan: plan))
                if let line = plan.line ?? control.reason { note(line) }
            }
            group("This app") {
                let appState = app.appUpdateState
                Text(verbatim: appState.line).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Help.Updates.appState)
                if let ahead = app.appAheadOfCluster { note(ahead.line) }
                HStack(spacing: 10) {
                    Button("Check Now") { app.checkAppUpdateNow() }
                        .disabled(appState == .development || app.appUpdateChecking)
                        .help(Help.Updates.checkNow)
                    Text(verbatim: AppUpdateAge.line(lastCheck: app.appUpdateLastCheck, now: Date()))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Check for app updates automatically", isOn: $preferences.checkAppUpdates)
                    .help(Help.Updates.checkAppUpdates)
                Toggle("Download app updates in the background", isOn: $preferences.downloadAppUpdates)
                    .help(Help.Updates.downloadAppUpdates)
            }
            group("Notifications") {
                Toggle("Notify me when an update is available", isOn: $preferences.notifyUpdate)
                    .help(Help.Updates.notify)
                note(UpdateNotice.paneNote)
            }
            if let panel = app.updateProgress.panel {
                UpdateProgressPanel(app: app, panel: panel)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            group("When updating") {
                Toggle("Drain each node before updating it", isOn: $preferences.updateDrain)
                    .help(Help.Updates.drain)
                Picker("Code signature", selection: $preferences.updateSignature) {
                    ForEach(UpdateSignaturePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .fixedSize()
                .help(Help.Updates.signature)
                note(UpdateOptions.paneNote)
            }
        }
        .padding(20)
        .frame(width: SettingsWindowController.paneWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard app.screen == .status else { return }
            Task {
                _ = await app.readFullReport()
                await app.refreshUpdateStatus()
            }
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
        Text(verbatim: text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
