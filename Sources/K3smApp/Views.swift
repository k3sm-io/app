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
import K3smInstall
import K3smStatus
import SwiftUI

/// MainView is the window: always the console (`ConsoleView`). Before k3sm
/// is installed its content pane holds the guided first run (`SetUpPane`);
/// once installed, the tabs, with the status popover (state, problems,
/// start, stop and update) behind the console's info button.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ConsoleView(app: model)
    }
}

/// SetUpPane is the console's content pane while nothing is installed
/// (`ConsolePane.setUp`): the login item line and the guided first run
/// (`FirstRunView`), below the strip's height so it clears the title bar.
struct SetUpPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoginApprovalLine(model: model)
            FirstRunView(model: model)
        }
        .padding(20)
        .padding(.top, CGFloat(TabStripLayout.height))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// FirstRunView is the guided first run, one step at a time
/// (`FirstRunFlow`): choose start or join; for a join, paste the join
/// command; review what will happen and authenticate; follow the install
/// phase by phase; then the console, or a plain failure with Try Again. The
/// token is pasted into a secure field and never shown or read from the
/// clipboard by the app.
struct FirstRunView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up k3sm on this Mac").font(.title2)
            stepList
            Divider()
            switch model.firstRunStep {
            case .choose: choose
            case .join: join
            case .review: review
            case .install: install
            case .finished: finished
            }
            Spacer(minLength: 0)
            buttons
        }
    }

    /// The path's steps, the current one bold.
    private var stepList: some View {
        let steps = FirstRunFlow.steps(for: model.choice)
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Text(verbatim: "›").foregroundStyle(.secondary) }
                Text(verbatim: "\(index + 1). \(step.title)")
                    .fontWeight(step == model.firstRunStep ? .semibold : .regular)
                    .foregroundStyle(step == model.firstRunStep ? Color.primary : Palette.ink2)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.choice) {
                ForEach(FirstRunPath.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(Help.FirstRun.choice)
            Text(verbatim: model.choice.detail).fixedSize(horizontal: false, vertical: true)
            if !model.logTail.isEmpty {
                Text("The last install on this Mac did not finish. Its log:").font(.callout).foregroundStyle(.secondary)
                RootStepLog(text: model.logTail)
            }
        }
    }

    private var join: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(JoinHints.prompt)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste the address and token", text: $model.joinPaste)
                .textFieldStyle(.roundedBorder)
            if let error = model.joinPasteError {
                Text(verbatim: error).foregroundStyle(Palette.errorText).fixedSize(horizontal: false, vertical: true)
            }
            if !model.serverText.isEmpty || !model.token.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Server: " + (model.joinAddress?.description ?? StatusDisplay.clip(model.serverText)))
                        Text(verbatim: model.token.isEmpty ? "Token: missing" : "Token: received, kept hidden")
                    }
                    Spacer()
                    Button("Clear") { model.clearJoinPaste() }
                        .help(Help.FirstRun.clearPaste)
                }
                .font(.callout)
            }
        }
    }

    private var review: some View {
        let review = model.firstRunReview
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: review.title).font(.headline)
            numbered(review.lines)
            if let command = review.terminalCommand {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.wash)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .help(Help.FirstRun.copyCommand)
                    if let title = review.terminalButton {
                        Button(title) { model.firstRunInstallInTerminal() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.running)
                            .help(Help.FirstRun.installInTerminal)
                    }
                }
                if model.firstRunInTerminal {
                    Text(verbatim: FirstRunFlow.terminalInstallingLine).font(.callout)
                }
                if let watch = model.installWatch {
                    InstallPathView(watch: watch)
                }
            } else if let reason = model.firstRunInstallDisabledReason {
                Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 10) {
            phases(FirstRunFlow.progress(path: model.choice, log: model.logTail, outcome: nil))
            if !model.logTail.isEmpty, FirstRunFlow.phase(log: model.logTail) != .authenticate {
                RootStepLog(text: model.logTail)
            }
        }
    }

    @ViewBuilder
    private var finished: some View {
        if let outcome = model.firstRunOutcome {
            let finish = FirstRunFlow.finish(path: model.choice, outcome: outcome, log: model.logTail)
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(verbatim: finish.title).font(.headline)
                } icon: {
                    Image(systemName: finish.succeeded ? RowTone.healthy.symbolName : RowTone.attention.symbolName)
                        .foregroundStyle(finish.succeeded ? Palette.ok : Palette.warn)
                }
                ForEach(Array(finish.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                }
                phases(FirstRunFlow.progress(path: model.choice, log: model.logTail, outcome: outcome))
                if !finish.succeeded, !model.logTail.isEmpty {
                    RootStepLog(text: model.logTail)
                }
            }
        }
    }

    /// The step's buttons: Back and Continue, the install (Check Again in a
    /// developer build, whose Install in Terminal sits beside Copy Command
    /// above the install watch's path), Try Again or Open Console when the
    /// install ended.
    private var buttons: some View {
        HStack {
            if FirstRunFlow.previous(before: model.firstRunStep, path: model.choice) != nil {
                Button("Back") { model.firstRunBack() }
                    .disabled(model.running)
                    .help(Help.FirstRun.back)
            }
            Spacer()
            switch model.firstRunStep {
            case .choose, .join:
                Button("Continue") { model.firstRunContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.firstRunCanContinue)
                    .help(Help.FirstRun.next)
            case .review:
                if let title = model.firstRunReview.installButton {
                    let reason = model.firstRunInstallDisabledReason
                    Button(title) { model.firstRunInstall() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reason != nil)
                        .help(Help.FirstRun.install(join: model.choice == .join, disabledReason: reason))
                } else {
                    Button("Check Again") { model.checkAgain() }
                        .disabled(model.running || model.installWatch?.checking == true)
                        .help(Help.FirstRun.checkAgain)
                }
            case .install:
                ProgressView().controlSize(.small)
            case .finished:
                if model.firstRunOutcome == .succeeded {
                    Button("Open Console") { Task { await model.refresh() } }
                        .keyboardShortcut(.defaultAction)
                        .help(Help.FirstRun.openConsole)
                } else {
                    Button("Try Again") { model.firstRunTryAgain() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.running)
                        .help(Help.FirstRun.tryAgain)
                }
            }
        }
    }

    private func numbered(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(index + 1).").monospacedDigit().foregroundStyle(Palette.ink2)
                    Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The install's phases, each with its state's mark.
    private func phases(_ rows: [FirstRunPhaseRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.phase) { row in
                HStack(spacing: 8) {
                    mark(row.state).frame(width: 16)
                    Text(verbatim: row.title)
                        .foregroundStyle(row.state == .pending ? Palette.ink2 : Color.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func mark(_ state: FirstRunPhaseState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Palette.ink2).accessibilityLabel(Text("pending"))
        case .active:
            ProgressView().controlSize(.mini).accessibilityLabel(Text("in progress"))
        case .done:
            Image(systemName: RowTone.healthy.symbolName).foregroundStyle(Palette.ok).accessibilityLabel(Text("done"))
        case .failed:
            Image(systemName: RowTone.attention.symbolName).foregroundStyle(Palette.warn).accessibilityLabel(Text("failed"))
        }
    }
}

/// StatusView is the popover's status: the headline (one state, `StatusHeadline`), the health check's
/// line (`HealthState.statusLine`; the whole headline without a report),
/// the stopped-by line, only the checks that are not ok (`StatusPopover.problemRows`, or
/// its all-ok line), the version line with the one update plan's button
/// (`UpdatePlan`), Start, Stop and Restart, the plan's line, and the full table
/// with Refresh behind the "All checks" disclosure, closed by default and
/// remembered (`AppPreferences.allChecksOpen`). The LAN switch is in
/// Settings > Network and Uninstall in Settings > Advanced.
struct StatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                headline(StatusHeadline.of(report))
                if let stopped = report.stoppedBy {
                    Text(verbatim: StatusDisplay.clip(stopped.line)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = model.health?.statusLine {
                    Text(verbatim: line).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                problems(report)
            } else {
                Text(verbatim: model.health?.line ?? HealthState.statusUnreadable.line ?? "").font(.title3).bold()
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The status as one state (`StatusHeadline`): its dot, the word, and a
    /// lock while checks need an administrator; accessibility reads the whole.
    private func headline(_ headline: StatusHeadline) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.row(headline.tone)).frame(width: 9, height: 9)
                .help(Help.Status.dot)
            Text(verbatim: headline.state).font(.title3).bold()
            if headline.showsLock {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help(Help.Status.needsAdmin(headline.needsAdmin, in: .popover))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: headline.accessibilityLabel))
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

    /// The version line, and the update plan's button while it has one.
    private var versionRow: some View {
        let plan = model.updatePlan
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let title = plan.buttonTitle {
                Spacer(minLength: 0)
                Button(title) { model.performUpdate() }
                    .controlSize(.small)
                    .disabled(!plan.isEnabled)
                    .help(Help.Strip.update(plan))
            }
        }
    }

    private var versionLine: String {
        model.appVersion.versionLine(installed: model.installedVersion, payload: model.payloadVersion)
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

/// UpdateSection is the update plan's line under the version row's button:
/// what Update does or why it cannot run, the datastore checks before the
/// control plane installs the app's release, and the address a worker's
/// app-carried update rejoins. It has no button of its own: the version
/// row's is the popover's one Update.
struct UpdateSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let plan = model.updatePlan
        VStack(alignment: .leading, spacing: 8) {
            if let line = plan.line {
                Text(verbatim: line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .payload = plan.path {
                if model.updatePlanFacts.role == .server {
                    Text("This Mac runs the control plane and no other node.").bold()
                    ForEach(UpdatePolicy.serverChecks, id: \.self) { Text(verbatim: "• " + $0).font(.callout) }
                }
                agentTarget
            }
        }
    }

    @ViewBuilder
    private var agentTarget: some View {
        if model.updatePlanFacts.role == .agent, case .success(let server) = model.joinTarget {
            Text(verbatim: "This worker joins " + server.description + ".").font(.callout)
        }
    }
}
