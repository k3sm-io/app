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

/// StatusView shows the full report, clipped, the version comparison, and
/// the Update and Uninstall actions.
struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text(verbatim: StatusDisplay.clip(headline(report))).font(.title2)
                if let stopped = report.stoppedBy {
                    Text(verbatim: StatusDisplay.clip(stopped.line)).foregroundStyle(.secondary)
                }
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
            Divider()
            UpdateSection(model: model)
            Divider()
            UninstallSection(model: model)
            if case .disabled(let reason) = model.availability {
                Text(verbatim: reason).foregroundStyle(.secondary)
            }
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

/// UpdateSection offers "Update k3sm" when the payload is newer, following
/// the rollout order: a worker any time, the control plane last, behind an
/// explicit confirmation while the status report carries no worker versions.
struct UpdateSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decision = model.updateDecision, let payload = model.payloadVersion {
                switch decision.verdict {
                case .upToDate:
                    Text("k3sm is up to date with this app.").foregroundStyle(.secondary)
                case .needsDowngradeConsent:
                    Text("This app does not carry a newer k3sm than the one installed, or the installed version could not be read. The app does not downgrade.")
                        .foregroundStyle(.secondary)
                case .waitForWorkers:
                    Text(verbatim: "Update these workers first: " + decision.workersToUpdate.map(StatusDisplay.clip).joined(separator: ", "))
                case .confirmWorkersUpdated, .offer:
                    if model.role == .server {
                        serverNotes(payload: payload)
                    }
                    agentTarget
                    Button("Update k3sm to " + payload.description) { model.submitUpdate() }
                        .disabled(!model.canUpdate)
                }
            }
        }
    }

    @ViewBuilder
    private func serverNotes(payload: SemanticVersion) -> some View {
        Text("This Mac runs the control plane, so it updates last.").bold()
        ForEach(UpdatePolicy.serverChecks, id: \.self) { Text(verbatim: "• " + $0).font(.callout) }
        Text("k3sm cannot read the workers' versions yet. Update every worker first, then confirm.")
            .font(.callout)
            .foregroundStyle(.secondary)
        Toggle("Every worker runs k3sm " + payload.description + " or newer", isOn: $model.workersConfirmed)
    }

    @ViewBuilder
    private var agentTarget: some View {
        if model.role == .agent {
            switch model.joinTarget {
            case .success(let server):
                Text(verbatim: "This worker joins " + server.description + ".").font(.callout)
            case .failure, nil:
                Text("The control-plane address this worker joins could not be read from its LaunchDaemon, so update it in Terminal.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// UninstallSection removes k3sm through the same verified root step. The
/// data stays unless purge is chosen, and purge is offered only once the CLI
/// can be told whose kubeconfig to clean.
struct UninstallSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Also delete k3sm's data", isOn: $model.purge)
                .disabled(CopyOutAction.purgeUnavailableReason != nil)
            if let reason = CopyOutAction.purgeUnavailableReason {
                Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
            }
            Button("Uninstall k3sm…") { model.confirmingUninstall = true }
                .disabled(!model.canUninstall)
                .confirmationDialog(
                    model.purge ? "Uninstall k3sm and delete its data?" : "Uninstall k3sm and keep its data?",
                    isPresented: $model.confirmingUninstall
                ) {
                    Button("Uninstall", role: .destructive) { model.submitUninstall() }
                }
        }
    }
}
