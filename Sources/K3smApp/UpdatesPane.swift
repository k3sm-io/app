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
/// the confirmation, for one apply only.
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
