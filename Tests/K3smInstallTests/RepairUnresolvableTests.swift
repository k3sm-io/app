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
}
