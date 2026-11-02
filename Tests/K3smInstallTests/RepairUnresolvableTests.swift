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

import Testing

import K3smStatus
@testable import K3smInstall

/// Repair over an installed k3sm whose entry point does not resolve: k3sm
/// refuses `install --from-staging` and names the install script, so the app
/// shows that repair and stops offering Repair, which cannot work.
@Suite("repair over an unresolvable install")
struct RepairUnresolvableTests {
    static let v020 = SemanticVersion("0.2.0")!

    static func plan(_ action: CopyOutAction) throws -> CopyOutPlan {
        try CopyOutPlan(
            bundlePath: "/Applications/k3sm.app", payloadVersion: v020,
            teamID: TeamID("ABCDE12345")!, user: ConsoleUser("alice")!, action: action)
    }

    /// The copy-out log as k3sm leaves it: `k3sm install: <err>` on stderr,
    /// exit 1, where the error is pkg/install's
    /// `install: <errInstalledUnresolvable>: <detail>; <installedUnresolvableRecovery>`.
    static let refusedLog = "copy-out: verified the staged k3sm\n"
        + "k3sm install: install: the installed k3sm does not resolve to a binary of its install tree: "
        + "/Library/k3sm/k3sm -> /Library/k3sm/versions/v0.1.9/k3sm: lstat: no such file or directory; "
        + "repair the install with the install script, curl -fsSL https://k3sm.io/install.sh | sh "
        + "(K3SM_INSTALL_VERSION=vX.Y.Z after the pipe pins a release), then update again\n"

    static let otherLog = "copy-out: verified the staged k3sm\n"
        + "k3sm install: install: no daemon plist on disk says which role this Mac has\n"

    @Test("repair names the install script on an unresolvable install")
    func repairNamesTheInstallScriptOnAnUnresolvableInstall() throws {
        let plan = try Self.plan(.repair)
        let failed = PrivilegedOutcome.failed(exitStatus: 1)
        #expect(Self.refusedLog.contains(UnresolvableInstall.recoveryPhrase))
        #expect(UnresolvableInstall.refused(failed, action: .repair, log: Self.refusedLog))

        // The sentence names the install script, pinned to the app's
        // release, not a retry, and is the app's own text, not the log's.
        let text = OutcomeSummary.text(failed, plan: plan, log: Self.refusedLog)
        #expect(text.contains("Repair the install with the install script in Terminal"))
        #expect(text.contains("curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.2.0 sh"))
        #expect(text.contains("Repair cannot run it"))
        #expect(!text.contains("The log above says why"))
        #expect(!text.contains("/Library/k3sm/versions"))
        #expect(text == RepairRefusal.installedUnresolvable(payload: Self.v020).text)

        // Repair is not offered again while the state stays repairable.
        for health: HealthState in [.cliMissing, .cliUntrusted("not owned by root"), .partlyRunning(down: ["io.k3sm.agent"])] {
            #expect(RepairPolicy.refusal(health: health, rootStep: true, payload: Self.v020, unresolvable: true)
                == .installedUnresolvable(payload: Self.v020))
        }
        // Once the install script has repaired the Mac the flag no longer
        // decides anything: the state does.
        #expect(RepairPolicy.refusal(health: .healthy, rootStep: true, payload: Self.v020, unresolvable: true) == .notHalfInstalled)
        // The root step and the payload still come first.
        #expect(RepairPolicy.refusal(health: .cliMissing, rootStep: false, payload: Self.v020, unresolvable: true) == .noRootStep)
    }

    @Test("an unrelated failure still offers repair")
    func unrelatedFailureStillOffersRepair() throws {
        let plan = try Self.plan(.repair)
        let failed = PrivilegedOutcome.failed(exitStatus: 1)
        #expect(!UnresolvableInstall.refused(failed, action: .repair, log: Self.otherLog))
        #expect(!UnresolvableInstall.refused(failed, action: .repair, log: ""))
        #expect(OutcomeSummary.text(failed, plan: plan, log: Self.otherLog).contains("The log above says why"))
        #expect(RepairPolicy.refusal(health: .cliMissing, rootStep: true, payload: Self.v020, unresolvable: false) == nil)
        #expect(RepairPolicy.refusal(health: .cliMissing, rootStep: true, payload: Self.v020) == nil)

        // A step that succeeded, was cancelled or was not a Repair is not the refusal.
        #expect(!UnresolvableInstall.refused(.succeeded, action: .repair, log: Self.refusedLog))
        #expect(!UnresolvableInstall.refused(.cancelled, action: .repair, log: Self.refusedLog))
        #expect(!UnresolvableInstall.refused(failed, action: .uninstall(purge: false), log: Self.refusedLog))
        let signature = PrivilegedOutcome.failed(exitStatus: CopyOutExit.signatureRejected)
        #expect(OutcomeSummary.text(signature, plan: plan, log: Self.otherLog).contains("signature check"))
    }

    /// The mark as a failed Repair with the refusal in its log leaves it.
    static func refusedMark() -> UnresolvableInstallMark {
        var mark = UnresolvableInstallMark()
        mark.rootStepFinished(.failed(exitStatus: 1), action: .repair, log: refusedLog)
        return mark
    }

    static func offered(_ mark: UnresolvableInstallMark, _ health: HealthState = .cliMissing) -> Bool {
        RepairPolicy.refusal(health: health, rootStep: true, payload: v020, unresolvable: mark.isSet) == nil
    }

    @Test("the refusal holds repair back until something changes")
    func refusalSetsTheMark() {
        var mark = Self.refusedMark()
        #expect(mark.isSet && !Self.offered(mark))
        // A still-repairable state read keeps it; another Repair failure for another reason clears it.
        mark.stateRead(.partlyRunning(down: ["io.k3sm.agent"]))
        #expect(mark.isSet)
        mark.rootStepFinished(.failed(exitStatus: 1), action: .repair, log: Self.otherLog)
        #expect(!mark.isSet && Self.offered(mark))
        // A state Repair is not offered for clears it.
        var healed = Self.refusedMark()
        healed.stateRead(.healthy)
        #expect(!healed.isSet)
    }

    @Test("a refresh on a still-repairable state offers repair again")
    func refreshOffersRepairAgain() {
        var mark = Self.refusedMark()
        mark.stateRead(.partlyRunning(down: ["io.k3sm.agent"]))
        #expect(!Self.offered(mark, .partlyRunning(down: ["io.k3sm.agent"])))
        mark.refreshed(.guidedPanel)
        #expect(Self.offered(mark, .partlyRunning(down: ["io.k3sm.agent"])))
    }

    @Test("a cancelled repair offers repair again")
    func cancelledRepairClearsTheMark() {
        var mark = Self.refusedMark()
        mark.rootStepFinished(.cancelled, action: .repair, log: Self.refusedLog)
        #expect(!mark.isSet && Self.offered(mark))
        var update = Self.refusedMark()
        update.rootStepFinished(.couldNotStart, action: .update(.server), log: Self.refusedLog)
        #expect(!update.isSet, "an Update that never ran says nothing about the install")
    }

    /// Logs that come close to the refusal and are not it.
    static let nearMisses: [String] = {
        let log: String = refusedLog
        let phrase: String = UnresolvableInstall.recoveryPhrase
        var logs: [String] = []
        // The case changed.
        logs.append(log.replacingOccurrences(of: "repair the install", with: "Repair the install"))
        logs.append(log.uppercased())
        // Another install URL.
        logs.append(log.replacingOccurrences(of: "https://k3sm.io/install.sh", with: "https://k3sm.example/install.sh"))
        // The tail window cut the line's start, or the log stops inside it.
        let refusalLine: Substring = log.drop { $0 != "\n" }.dropFirst()
        logs.append(String(refusalLine.dropFirst(40)))
        logs.append(String(log.dropLast(20)))
        logs.append(String(log.dropLast()))
        // The phrase alone, under another prefix, with more after it, or with no cause.
        logs.append(phrase + "\n")
        logs.append("k3sm update: install: x; " + phrase + "\n")
        logs.append("echo k3sm install: install: x; " + phrase + "\n")
        logs.append("k3sm install: install: x; " + phrase + " now\n")
        logs.append("k3sm install: install: ; " + phrase + "\n")
        return logs
    }()

    @Test("near-miss logs are not the refusal", arguments: nearMisses)
    func nearMissLogsDoNotSetTheMark(_ log: String) {
        let failed = PrivilegedOutcome.failed(exitStatus: 1)
        #expect(!UnresolvableInstall.refused(failed, action: .repair, log: log))
        #expect(!UnresolvableInstall.refused(failed, action: .update(.server), log: log))
        var mark = UnresolvableInstallMark()
        mark.rootStepFinished(failed, action: .repair, log: log)
        #expect(!mark.isSet)
    }

    static let recoveryPhrase = UnresolvableInstall.recoveryPhrase

    @Test("a development build's payload shows the unpinned install command", arguments: [
        SemanticVersion("0.0.0"), nil,
    ])
    func developmentPayloadShowsTheUnpinnedCommand(_ payload: SemanticVersion?) {
        for action: CopyOutAction in [.repair, .update(.server)] {
            let text = UnresolvableInstall.sentence(for: action, payload: payload)
            #expect(text.contains("curl -fsSL https://k3sm.io/install.sh | sh, then click Refresh."))
            #expect(!text.contains("K3SM_INSTALL_VERSION"))
        }
        #expect(RepairRefusal.installedUnresolvable(payload: payload).text
            == UnresolvableInstall.sentence(for: .repair, payload: payload))
    }

    @Test("an unreadable status clears the mark and no read keeps it")
    func stateReadOnUnreadableAndNil() {
        var mark = Self.refusedMark()
        mark.stateRead(nil)
        #expect(mark.isSet)
        mark.stateRead(.statusUnreadable)
        #expect(!mark.isSet)
    }

    @Test("the bare refresh is an app-made read and never lifts the hold")
    func bareRefreshKeepsTheHold() {
        #expect(!RefreshSource.bareRefresh.liftsUnresolvableHold)
        var mark = UnresolvableInstallMark()
        mark.rootStepFinished(UpdateUnresolvableTests.failed, action: .update(.server),
                              log: UpdateUnresolvableTests.refusedLog, state: nil)
        #expect(mark.isSet)
        mark.refreshed(.bareRefresh)
        #expect(mark.isSet)
    }

    @Test("only a refresh the user asked for lifts the hold", arguments: RefreshSource.allCases)
    func refreshSourcesThatLiftTheHold(_ source: RefreshSource) {
        var mark = Self.refusedMark()
        mark.refreshed(source)
        let user: [RefreshSource] = [.guidedPanel, .menu, .popover, .firstRunCheckAgain]
        #expect(source.liftsUnresolvableHold == user.contains(source))
        #expect(mark.isSet == !user.contains(source))
        // The read right after the refused step never lifts it.
        #expect(!RefreshSource.afterRootStep.liftsUnresolvableHold)
    }

    @Test("a successful root step offers repair again", arguments: [
        CopyOutAction.update(.server), .repair, .startServer,
    ])
    func successOffersRepairAgain(_ action: CopyOutAction) {
        var mark = Self.refusedMark()
        mark.rootStepFinished(.failed(exitStatus: 1), action: .uninstall(purge: false), log: "")
        #expect(mark.isSet, "a failed non-Repair step leaves the mark")
        mark.rootStepFinished(.succeeded, action: action, log: "")
        #expect(Self.offered(mark))
    }
}
