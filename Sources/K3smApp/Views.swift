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

/// MainView is the window. Before k3sm is installed it is the first-run
/// form; once installed it is the console, with the status popover (state,
/// problems, start, stop and update) behind the console's info button.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.screen {
        case .firstRun: StatusPanel(model: model)
        case .status: ConsoleView(app: model)
        }
    }
}

/// StatusPanel is the first-run form, then the log of the last root step.
/// Every string from the CLI renders verbatim.
struct StatusPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoginApprovalLine(model: model)
            FirstRunView(model: model)
            if !model.logTail.isEmpty {
                RootStepLog(text: model.logTail)
            }
            if let message = model.outcomeMessage {
                Text(verbatim: message)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420, alignment: .topLeading)
    }
}

/// StatusPopoverPanel is the console's info popover, about 380 pt wide: the
/// status (`StatusView`), then the last root step's log only while a step
/// runs or after one failed (`StatusPopover.showsLog`), then the outcome.
struct StatusPopoverPanel: View {
    @ObservedObject var model: AppModel

    /// The popover's width.
    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LoginApprovalLine(model: model)
            StatusView(model: model, preferences: PreferencesStore.shared)
            if StatusPopover.showsLog(logTail: model.logTail, running: model.running,
                                      lastStepSucceeded: CopyOutOutcome(log: model.logTail) == .succeeded) {
                RootStepLog(text: model.logTail)
            }
            if let message = model.outcomeMessage {
                Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .topLeading)
    }
}

/// LoginApprovalLine says when macOS waits for the user to allow the login item.
struct LoginApprovalLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.loginItemNeedsApproval {
            HStack {
                Text("k3sm is not allowed to open at login.")
                Button("Open Login Items") { LoginItem.openSettings() }
                    .help(Help.Popover.openLoginItems)
            }
        }
    }
}

/// RootStepLog is the tail of the last root step's log, verbatim.
struct RootStepLog: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 120)
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
            .help(Help.FirstRun.choice)
            if model.choice == .join {
                TextField("Server address, for example studio.local", text: $model.serverText)
                    .textFieldStyle(.roundedBorder)
                if let error = model.addressError {
                    Text(verbatim: error).foregroundStyle(Palette.errorText)
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
                .help(Help.FirstRun.submit(join: model.choice == .join))
        }
    }
}

/// StatusView is the popover's status: the headline and the stopped-by
/// line, only the checks that are not ok (`StatusPopover.problemRows`, or
/// its all-ok line), the version line with the managed update's button
/// while the `update` row says behind (`UpdateOffer`), Start, Stop and
/// Restart, the app-carried update when it offers one, and the full table
/// with Refresh behind the "All checks" disclosure, closed by default and
/// remembered (`AppPreferences.allChecksOpen`). The LAN switch is in
/// Settings > Network and Uninstall in Settings > Advanced.
struct StatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text(verbatim: StatusDisplay.headline(report)).font(.title3).bold()
                    .fixedSize(horizontal: false, vertical: true)
                if let stopped = report.stoppedBy {
                    Text(verbatim: StatusDisplay.clip(stopped.line)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                problems(report)
            } else {
                Text("k3sm is installed, but its status could not be read.").font(.title3).bold()
            }
            versionRow
            LifecycleSection(model: model)
            UpdateSection(model: model)
            if case .disabled(let reason) = model.availability {
                Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            DisclosureGroup(StatusPopover.allChecksTitle, isExpanded: $preferences.allChecksOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    if let report = model.report {
                        allChecks(report)
                    }
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.running)
                        .help(Help.Popover.refresh)
                }
                .padding(.top, 6)
            }
        }
    }

    /// The checks that are not ok, each its glyph, name and state over its detail.
    @ViewBuilder
    private func problems(_ report: StatusReport) -> some View {
        if let line = StatusPopover.allOkLine(report) {
            Label { Text(verbatim: line) } icon: {
                Image(systemName: RowTone.healthy.symbolName).foregroundStyle(Palette.row(.healthy))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(StatusPopover.problemRows(of: report).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.rowState.tone.symbolName)
                            .foregroundStyle(Palette.row(row.rowState.tone))
                            .accessibilityLabel(Text(verbatim: row.rowState.tone.word))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: row.name).bold()
                                Text(verbatim: row.state)
                            }
                            if !row.detail.isEmpty {
                                Text(verbatim: row.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every check, as the CLI lists them.
    private func allChecks(_ report: StatusReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(StatusDisplay.rows(of: report).enumerated()), id: \.offset) { _, row in
                GridRow {
                    Image(systemName: row.rowState.tone.symbolName)
                        .foregroundStyle(Palette.row(row.rowState.tone))
                        .accessibilityLabel(Text(verbatim: row.rowState.tone.word))
                    Text(verbatim: row.name).bold()
                    Text(verbatim: row.state)
                    Text(verbatim: row.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    /// The version line, and the managed update's button while one is offered.
    private var versionRow: some View {
        let offer = model.updateOffer
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let title = offer.buttonTitle {
                Spacer(minLength: 0)
                Button(title) { model.performUpdate() }
                    .controlSize(.small)
                    .disabled(!offer.isEnabled)
                    .help(Help.Strip.update(offer))
            }
        }
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

/// LifecycleSection offers Stop and Restart while k3sm runs and Start while
/// it is stopped, each through the same confirmation and administrator
/// prompt as the menu. With an installed CLI too old for `k3sm stop`, or one
/// the app will not run as root, it shows the note instead.
struct LifecycleSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.lifecycleState {
            case .running:
                HStack {
                    Button(LifecycleVerb.stop.title + "…") { model.perform(.stop, expected: .running) }
                        .help(Help.Popover.stop)
                    Button(LifecycleVerb.restart.title + "…") { model.perform(.restart, expected: .running) }
                        .help(Help.Popover.restart)
                }
                .disabled(!model.canRunLifecycle)
            case .stopped:
                Button(LifecycleVerb.start.title + "…") { model.perform(.start, expected: .stopped) }
                    .disabled(!model.canRunLifecycle)
                    .help(Help.Popover.start)
            case .notInstalled, .unreadable:
                EmptyView()
            }
            if case .unavailable(let note) = model.lifecycleSupport {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// UpdateSection offers "Update k3sm" when the payload is newer (and shows
/// nothing otherwise, the version line saying how the releases compare), following
/// the rollout order: a worker any time, the control plane last, behind an
/// explicit confirmation while the status report carries no worker versions.
struct UpdateSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decision = model.updateDecision, let payload = model.payloadVersion {
                switch decision.verdict {
                case .upToDate, .needsDowngradeConsent:
                    // The version line already says how the two releases compare.
                    EmptyView()
                case .waitForWorkers:
                    Text(verbatim: "Update these workers first: " + decision.workersToUpdate.map(StatusDisplay.clip).joined(separator: ", "))
                case .confirmWorkersUpdated, .offer:
                    if model.role == .server {
                        serverNotes(payload: payload)
                    }
                    agentTarget
                    Button("Update k3sm to " + payload.description) { model.submitUpdate() }
                        .disabled(!model.canUpdate)
                        .help(Help.Popover.installPayload)
                }
            }
        }
    }

    private var unverifiedNote: String {
        let names = model.updateDecision?.workersUnverified ?? []
        if names.isEmpty {
            return "k3sm cannot read the workers' versions. Update every worker first, then confirm."
        }
        return "These workers report no version: " + names.map(StatusDisplay.clip).joined(separator: ", ")
            + ". Update every worker first, then confirm."
    }

    @ViewBuilder
    private func serverNotes(payload: SemanticVersion) -> some View {
        Text("This Mac runs the control plane, so it updates last.").bold()
        ForEach(UpdatePolicy.serverChecks, id: \.self) { Text(verbatim: "• " + $0).font(.callout) }
        Text(verbatim: unverifiedNote)
            .font(.callout)
            .foregroundStyle(.secondary)
        Toggle("Every worker runs k3sm " + payload.description + " or newer", isOn: $model.workersConfirmed)
            .help(Help.Popover.workersConfirmed)
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
