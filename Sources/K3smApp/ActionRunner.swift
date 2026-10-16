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
import K3smInstall
import K3smStatus

/// ActionRunner runs every console tab's writes, one at a time: it holds
/// the request waiting on its confirmation (the console's one dialog shows
/// while it is set), runs the request's pre-check and then its arguments,
/// each through `TrustedCLI` (a fresh trust check of the installed CLI) and
/// `CLIProcess` with the request's deadline, `OutputLimit.status` and
/// `keepErrors`, so the CLI's own error text reaches the report; a run that
/// leads to another action (a prune's dry run, a reset's delete) asks that
/// one next. It keeps the
/// `ActionReport` and asks the owning tab to read again after the run,
/// whatever the outcome. Each tab's finished reads come back through
/// `tabRead`, and the report clears on the next good one after that read.
@MainActor
final class ActionRunner: ObservableObject {
    /// The request waiting on its confirmation.
    @Published private(set) var pending: (any ConsoleActionRequest)?
    /// The current action's lifecycle; nil when there is nothing to show.
    @Published private(set) var report: ActionReport?
    /// Reads a tab again after an action on one of its rows.
    var refresh: (@MainActor (ConsoleSection) async -> Void)?

    private let environment: [String: String]
    private let teamID: TeamID?

    init(environment: [String: String], teamID: TeamID?) {
        self.environment = environment
        self.teamID = teamID
    }

    /// Whether an action is running, so every action button waits.
    var busy: Bool { report?.phase == .running }

    /// The finished report for one row, when the last action ran on it.
    func report(section: ConsoleSection, rowKey: String?) -> ActionReport? {
        guard let report, report.finished, report.section == section, report.rowKey == rowKey else { return nil }
        return report
    }

    /// Asks for an action: the request is fixed now, and the confirmation
    /// shows it; a request that does not ask first runs now. Ignored while
    /// another action runs or waits.
    func ask(_ request: any ConsoleActionRequest) {
        guard !busy, pending == nil else { return }
        pending = request
        report = ActionReport.pending(request)
        if !request.asksFirst { runPending() }
    }

    /// The confirmation was declined.
    func cancel() {
        pending = nil
        report = report?.cancelled()
    }

    /// One finished read of a tab, by `ActionReport.afterRead`.
    func tabRead(_ section: ConsoleSection, succeeded: Bool) {
        guard let report else { return }
        let next = report.afterRead(of: section, succeeded: succeeded)
        if next != report { self.report = next }
    }

    /// Runs the confirmed action: its pre-check first, when it has one, and
    /// the action's runs only when the pre-check lets it, each in turn
    /// whatever the last one's outcome; then the owning tab is read again.
    func runPending() {
        guard !busy, let request = pending else { return }
        pending = nil
        report = ActionReport.pending(request).confirmed()
        let environment = environment
        let teamID = teamID
        let deadline = request.deadline
        let cli = TrustedCLI<CLIOutcome>(
            check: { await Task.detached { SelfCheck.installedCLITrust(team: teamID) }.value },
            execute: { arguments in
                await CLIProcess.run(
                    path: K3smCLI.path, arguments: arguments, environment: environment,
                    deadline: deadline, limit: OutputLimit.status, keepErrors: true)
            })
        Task { [weak self] in
            let outcome: ActionOutcome
            if let check = request.precheckArguments, let refusal = request.precheck(Self.actionRun(await cli.run(check))) {
                outcome = refusal
            } else {
                var runs: [ActionRun] = []
                for arguments in request.runs {
                    runs.append(Self.actionRun(await cli.run(arguments)))
                }
                if let last = runs.last, let next = request.next(after: last) {
                    // The run leads to another action (asking first when it
                    // does): nothing is reported or read yet.
                    log.notice("console: \(request.verb, privacy: .public) leads on")
                    guard let self else { return }
                    self.report = nil
                    self.ask(next)
                    return
                }
                outcome = request.report(runs: runs)
            }
            log.notice("console: \(request.verb, privacy: .public) \(outcome.failed ? "failed" : "asked", privacy: .public)")
            guard let self else { return }
            self.report = self.report?.finished(outcome)
            await self.refresh?(request.section)
            self.report = self.report?.refreshDone()
        }
    }

    /// One trusted run as an action reads it.
    nonisolated private static func actionRun(_ result: TrustedCLI<CLIOutcome>.Result) -> ActionRun {
        switch result {
        case .refused(let why): return .refused(why)
        case .ran(.exited(let status, let stdout)): return .exited(status: status, output: stdout)
        case .ran(.missing): return .missing
        case .ran(.refused(let why)): return .refused(why)
        case .ran(.failedToLaunch), .ran(.killed), .ran(.truncated): return .noAnswer
        }
    }
}
