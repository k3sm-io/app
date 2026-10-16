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

/// Repair: the install run again over a half-installed k3sm from the app's
/// verified payload, in the CLI's in-place shape (no role flag, no --user).
@Suite("repair")
struct RepairTests {
    static let v020 = SemanticVersion("0.2.0")!
    static let v030 = SemanticVersion("0.3.0")!

    static func plan(_ action: CopyOutAction) throws -> CopyOutPlan {
        try CopyOutPlan(
            bundlePath: "/Applications/k3sm.app", payloadVersion: v020,
            teamID: TeamID("ABCDE12345")!, user: ConsoleUser("alice")!, action: action)
    }

    /// The whole root script Repair runs, byte for byte: the same copy-out as
    /// an install or an update (log, sweep, no-xattr copy, unsafe-entry
    /// refusal, chown, Developer ID verification), then the staged CLI with
    /// `install --from-staging "$stage"` and nothing else.
    static let repairScript = #"""
        set -eu
        umask 077
        cd /
        logdir='/Library/Logs/k3sm'
        log='/Library/Logs/k3sm/copy-out.log'
        if [ -L "$logdir" ] || [ -L "$log" ]; then
        	echo 'copy-out: refused: the log path is a symlink' >&2
        	exit 64
        fi
        /bin/mkdir -p "$logdir"
        /usr/sbin/chown root:admin "$logdir"
        /bin/chmod 0750 "$logdir"
        /bin/rm -f "$log"
        : > "$log"
        /usr/sbin/chown root:admin "$log"
        /bin/chmod 0640 "$log"
        exec >> "$log" 2>&1
        stage=
        finish() {
        	status=$?
        	if [ -n "$stage" ]; then /bin/rm -rf "$stage"; fi
        	echo "copy-out: exit $status"
        }
        trap finish EXIT
        trap 'exit 130' HUP INT TERM
        root='/Library/k3sm.staging'
        if [ -L "$root" ]; then
        	echo 'copy-out: refused: the staging root is a symlink'
        	exit 64
        fi
        /bin/mkdir -p "$root"
        /usr/sbin/chown root:wheel "$root"
        /bin/chmod 0700 "$root"
        echo 'copy-out: sweeping stale staging entries'
        /usr/bin/find "$root" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
        stage=$(/usr/bin/mktemp -d '/Library/k3sm.staging/0.2.0.XXXXXXXX')
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 0700 "$stage"
        echo 'copy-out: copying the app bundle'
        /usr/bin/ditto --norsrc --noextattr --noqtn --noacl '/Applications/k3sm.app' "$stage"/'k3sm.app'
        bad=$(/usr/bin/find "$stage"/'k3sm.app' \( ! \( -type f -o -type d \) -o -perm +6022 \) -print | /usr/bin/head -n 1)
        if [ -n "$bad" ]; then
        	echo "copy-out: refused: $bad is a symlink, a special file, setuid or setgid, or writable by group or others"
        	exit 65
        fi
        /usr/sbin/chown -R root:wheel "$stage"/'k3sm.app'
        echo 'copy-out: verifying the signature'
        if ! /usr/bin/codesign --verify --strict --deep '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$stage"/'k3sm.app'; then
        	echo 'copy-out: refused: the app is not signed by the k3sm Developer ID'
        	exit 77
        fi
        k3sm="$stage"/'k3sm.app'/'Contents/Resources/payload/k3sm'
        echo 'copy-out: running k3sm install (repair)'
        "$k3sm" 'install' '--from-staging' "$stage"

        """#

    @Test("the repair script, byte for byte")
    func repairScriptGolden() throws {
        let script = RootScriptBuilder.render(try Self.plan(.repair))
        #expect(script.text == Self.repairScript)
        #expect(script.prompt == "k3sm wants to repair the k3sm installed on this Mac.")
        #expect(!script.readsInput)
        #expect(script.usesStagingLock)
        // Everything before the CLI line is the update's script: Repair adds
        // no step to the copy-out and drops none.
        let update = RootScriptBuilder.render(try Self.plan(.update(.server))).text
        func head(_ text: String) -> Substring {
            text[..<text.range(of: "echo 'copy-out: running k3sm install")!.lowerBound]
        }
        #expect(head(script.text) == head(update))
    }

    @Test("a repair passes no role flag, no token and no --user")
    func repairArgv() throws {
        let argv = RootScriptBuilder.arguments(for: try Self.plan(.repair))
        #expect(argv == [.literal("install"), .literal("--from-staging"), .stagingDirectory])
        for flag in ["--agent", "--server", "--server-join", "--token-file", "--user", "--allow-downgrade"] {
            #expect(!argv.contains(.literal(flag)), "repair passes \(flag)")
        }
    }

    struct RefusalCase: Sendable, CustomTestStringConvertible {
        let name: String
        let health: HealthState?
        let rootStep: Bool
        let payload: SemanticVersion?
        let want: RepairRefusal?
        var testDescription: String { name }
    }

    static let refusalCases: [RefusalCase] = [
        RefusalCase(name: "command missing", health: .cliMissing, rootStep: true, payload: v020, want: nil),
        RefusalCase(name: "command untrusted", health: .cliUntrusted("not owned by root"), rootStep: true, payload: v020, want: nil),
        RefusalCase(name: "netd down", health: .partlyRunning(down: ["io.k3sm.netd"]), rootStep: true, payload: v020, want: nil),
        RefusalCase(name: "node daemon down", health: .partlyRunning(down: ["io.k3sm.agent"]), rootStep: true, payload: v020, want: nil),
        RefusalCase(name: "developer build", health: .cliMissing, rootStep: false, payload: v020, want: .noRootStep),
        RefusalCase(name: "unstamped payload", health: .cliMissing, rootStep: true, payload: nil, want: .payloadUnknown),
        RefusalCase(name: "not checked yet", health: nil, rootStep: true, payload: v020, want: .healthUnknown),
        RefusalCase(name: "nothing installed", health: .notInstalled, rootStep: true, payload: v020, want: .notInstalled),
        RefusalCase(name: "installed is newer",
                    health: .versionMismatch(payload: v020, installed: v030, relation: .older),
                    rootStep: true, payload: v020, want: .installedNewer),
        RefusalCase(name: "installed is older",
                    health: .versionMismatch(payload: v030, installed: v020, relation: .newer),
                    rootStep: true, payload: v030, want: .notHalfInstalled),
        RefusalCase(name: "healthy", health: .healthy, rootStep: true, payload: v020, want: .notHalfInstalled),
        RefusalCase(name: "stopped", health: .installedStopped(nil), rootStep: true, payload: v020, want: .notHalfInstalled),
        RefusalCase(name: "status unreadable", health: .statusUnreadable, rootStep: true, payload: v020, want: .notHalfInstalled),
    ]

    @Test("refusal goldens", arguments: refusalCases)
    func repairRefusalGoldens(_ c: RefusalCase) {
        #expect(RepairPolicy.refusal(health: c.health, rootStep: c.rootStep, payload: c.payload) == c.want)
    }

    @Test("each refusal is one fixed sentence")
    func refusalText() {
        let all: [RepairRefusal] = [.noRootStep, .payloadUnknown, .healthUnknown, .notInstalled, .installedNewer, .notHalfInstalled]
        #expect(Set(all.map(\.text)).count == all.count)
        for r in all {
            #expect(r.text.hasSuffix(".") && !r.text.contains("\n"), "\(r)")
        }
    }

    @Test("the confirmation says what Repair does and what each role keeps")
    func confirmation() {
        let server = RepairConfirmation(payload: Self.v020, role: .server)
        #expect(server.title == "Repair k3sm on this Mac?")
        #expect(server.proceedTitle == "Repair")
        #expect(server.cancelTitle == "Cancel")
        #expect(server.message == "k3sm 0.2.0, the release this app carries, is installed again over the k3sm on this Mac: "
            + "its command, its helpers, its daemons and the k3sm link, and the daemons restart.\n\n"
            + "This Mac stays the control plane, with the server arguments its last install recorded, "
            + "and the cluster's data is kept. The admin kubeconfig is written again for the account the server's record names, "
            + "which may not be the account running this app.\n\n"
            + "k3sm refuses the repair, and the log says why, when no daemon on this Mac says which role it has, "
            + "when the installed release is newer than this app's or its version cannot be read or is not a release, "
            + "when the installed command is signed by another team, or when a worker's node credential is no longer valid. "
            + "Repair names no account, so k3sm also refuses when both daemon plists are on disk, because the role is ambiguous "
            + "(uninstall, then install the role this Mac should have), and, on a control plane, when its arguments record names no admin "
            + "kubeconfig, or the owner of that kubeconfig cannot be read or is root (run the install again from Terminal with --user).")

        let agent = RepairConfirmation(payload: Self.v020, role: .agent)
        #expect(agent.message.contains("\n\nThis Mac stays a worker of the control plane its daemon joins, with its node credential "
            + "and the other arguments its daemon runs with, and its data is kept. An explicit node IP it was installed with is not "
            + "passed again: the worker uses the address the control plane assigned it.\n\n"))
        #expect(!agent.message.contains("control plane, with the server arguments"))
        // The worker's own text never mentions a kubeconfig; only the shared refusals do.
        #expect(!agent.message.replacingOccurrences(of: RepairConfirmation.refusals, with: "").contains("kubeconfig"))
        #expect(!server.message.contains("node credential and"))

        // With the role unknown, both, each named.
        let unknown = RepairConfirmation(payload: Self.v020, role: nil)
        #expect(unknown.message.contains("On a control-plane Mac: " + RepairConfirmation.serverKeeps))
        #expect(unknown.message.contains("On a worker: " + RepairConfirmation.agentKeeps))
        for c in [server, agent, unknown] {
            #expect(c.message.hasSuffix(RepairConfirmation.refusals))
        }
    }

    /// Every case the CLI refuses or keeps, read from k3sm's own source, is
    /// named in the text the app shows before the administrator prompt.
    @Test("the root-step questions name every case the CLI refuses or keeps",
          .enabled(if: LifecycleScriptTests.cliDirectory != nil))
    func rootStepConfirmationsMatchTheCLI() throws {
        let cli = try #require(LifecycleScriptTests.cliDirectory)
        let inplace = try String(contentsOf: cli.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "pkg/install/inplace.go"), encoding: .utf8)
        let update = try String(contentsOf: cli.appending(path: "update.go"), encoding: .utf8)

        // Repair: the refusals a no-account repair raises.
        #expect(inplace.contains("are on disk, so the role to update in place is ambiguous"))
        #expect(inplace.contains("does not record which admin kubeconfig the last install wrote"))
        #expect(inplace.contains("no way to read the owner of"))
        #expect(inplace.contains("is unusable") && inplace.contains("u == \"root\""))
        #expect(inplace.contains("run the install again with --user"))
        let refusals = RepairConfirmation.refusals
        for words in ["both daemon plists are on disk", "the role is ambiguous",
                      "names no admin kubeconfig", "cannot be read or is root", "from Terminal with --user"] {
            #expect(refusals.contains(words), "the repair question does not say: \(words)")
        }

        // Abort: the three cases runUpdateAbort distinguishes.
        let abort = try #require(UpdateAbortTests.body(of: "runUpdateAbort", in: update))
        #expect(abort.contains("case u == nil:") && abort.contains("releasing the nodes only"))
        #expect(abort.contains("updatectl.ReasonSucceeded") && abort.contains("updatectl.ReasonCancelled") && abort.contains("left as it is"))
        #expect(abort.contains("Marked the Update"))
        let text = UpdateConfirmationText.abort
        for words in ["An unfinished update is marked Cancelled", "already succeeded or was cancelled is left as it is",
                      "with no update on record, only the nodes are released"] {
            #expect(text.contains(words), "the abort question does not say: \(words)")
        }
        #expect(!text.contains("and marks it Cancelled"))
    }

    @Test("a failed repair points at the log")
    func outcome() {
        #expect(OutcomeSummary.text(.failed(exitStatus: 1), action: .repair).contains("The log above says why"))
        #expect(OutcomeSummary.text(.failed(exitStatus: CopyOutExit.signatureRejected), action: .repair).contains("signature check"))
    }
}
