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

import K3smInstall
import K3smStatus
import SwiftUI

/// MainView is the window: the first-run form or the status, then the log of
/// the last root step. Every string from the CLI renders verbatim.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.loginItemNeedsApproval {
                HStack {
                    Text("k3sm is not allowed to open at login.")
                    Button("Open Login Items") { LoginItem.openSettings() }
                }
            }
            switch model.screen {
            case .firstRun: FirstRunView(model: model)
            case .status: StatusView(model: model)
            }
            if !model.logTail.isEmpty {
                ScrollView {
                    Text(verbatim: model.logTail)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120)
            }
            if let message = model.outcomeMessage {
                Text(verbatim: message)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420, alignment: .topLeading)
    }
}

/// FirstRunView asks the one first-run question: start a cluster here, or
/// join one. The token is typed or pasted, never read from the clipboard.
struct FirstRunView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up k3sm on this Mac").font(.title2)
            Picker("", selection: $model.choice) {
                ForEach(AppModel.FirstRunChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.choice == .join {
                TextField("Server address, for example studio.local", text: $model.serverText)
                    .textFieldStyle(.roundedBorder)
                if let error = model.addressError {
                    Text(verbatim: error).foregroundStyle(.red)
                }
                SecureField("Join token from `k3sm token create` on the server", text: $model.token)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Pods on one Mac share one trust domain. Run untrusted workloads in the vm runtime class.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if case .disabled(let reason) = model.availability {
                Text(verbatim: reason).foregroundStyle(.secondary)
            }
            Button(model.choice == .start ? "Start" : "Join") { model.submitFirstRun() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
        }
    }
}

/// StatusView shows the full report, clipped, and the version comparison.
struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text(verbatim: StatusDisplay.clip(headline(report))).font(.title2)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(StatusDisplay.rows(of: report).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(verbatim: row.name).bold()
                            Text(verbatim: row.state)
                            Text(verbatim: row.detail).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("k3sm is installed, but its status could not be read.").font(.title2)
            }
            Text(verbatim: versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Refresh") { Task { await model.refresh() } }
                .disabled(model.running)
        }
    }

    private func headline(_ report: StatusReport) -> String {
        report.summary.isEmpty ? "k3sm \(report.verdict.word)" : "k3sm \(report.verdict.word) · \(report.summary)"
    }

    private var versionLine: String {
        let installed = model.installedVersion?.description ?? "unknown"
        guard let payload = model.payloadVersion else { return "Installed: \(installed)" }
        guard let current = model.installedVersion else { return "Installed: \(installed) · this app carries \(payload)" }
        switch PayloadRelation(payload: payload, installed: current) {
        case .newer: return "Installed: \(current) · this app carries \(payload), a newer release"
        case .same: return "Installed: \(current) · up to date with this app"
        case .older: return "Installed: \(current) · this app carries an older release, \(payload)"
        }
    }
}
