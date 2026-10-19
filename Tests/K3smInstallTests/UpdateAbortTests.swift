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
import Testing

import K3smStatus
@testable import K3smInstall

/// `k3sm update abort` from the app: the root script byte for byte, its
/// refusals run for real, the question that says what abort leaves, the
/// driver, and the CLI's own abort and update flags, read from
/// cmd/k3sm/update.go so the text and argv cannot drift from what k3sm does.
@Suite("the managed update's abort")
struct UpdateAbortTests {
    static let team = ManagedUpdateTests.team

    @Test("the abort script, byte for byte")
    func updateAbortScriptGolden() {
        let want = #"""
            set -eu
            umask 077
            cd /
            k3sm='/Library/k3sm/k3sm'
            refuse() {
            	echo "k3sm app: refused: $1" >&2
            	exit 100
            }
            nl='
            '
            acl_check() {
            	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
            	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
            	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
            }
            for p in '/' '/Library' '/Library/k3sm' '/Library/k3sm/k3sm'; do
            	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
            	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
            	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$p could not be checked"
            	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
            	acl_check "$p"
            done
            if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
            if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$k3sm"; then
            	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
            	exit 101
            fi
            exec "$k3sm" 'update' 'abort'

            """#
        let script = LifecycleScriptBuilder.render(.updateAbort, teamID: Self.team)
        #expect(script.text == want)
        #expect(script.prompt == "k3sm wants to abort the k3sm update and release every node.")
        #expect(!script.readsInput && !script.usesStagingLock)
        // The abort's argv is a constant: no option or release reaches it.
        #expect(LifecycleScriptBuilder.arguments(for: .updateAbort) == ["update", "abort"])
    }

    @Test("each refusal stops the abort script before the CLI runs", arguments: LifecycleScriptTests.refusals)
    func refusal(_ r: LifecycleScriptTests.Refusal) throws {
        let line = LifecycleScriptBuilder.render(.updateAbort, teamID: Self.team, cliPath: r.cliPath).command(inputPath: "/dev/null")
        let result = try LifecycleScriptTests.run(line)
        #expect(result.status == r.status, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(r.message), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains("unknown option"), "the CLI line ran")
    }

    @Test("the abort is an update verb no other driver runs")
    func verb() async {
        let verb = LifecycleVerb.updateAbort
        #expect(verb.isUpdate && !verb.isLAN && verb.requiredState == nil)
        #expect(verb.command == "update abort" && verb.title == "Abort Update")
        let runner = LANRunner()
        let lifecycle = LifecycleDriver(teamID: Self.team, readStatus: { ManagedUpdateTests.report(latest: "v0.1.8") },
                                        confirm: { _ in true }, runner: runner)
        guard case .refused = await lifecycle.perform(verb, expected: .running) else {
            Issue.record("the lifecycle driver ran the abort")
            return
        }
        #expect(runner.scripts.isEmpty)
    }

    @Test("the question says what abort leaves, and answering no is the default")
    func question() {
        let empty = StatusReport(schemaVersion: StatusReport.supportedSchemaVersion, verdict: .unknown, role: "", summary: "", rows: [])
        let c = LifecycleConfirmation(verb: .updateAbort, report: empty)
        #expect(c.title == "Abort the update?")
        #expect(c.message == UpdateConfirmationText.abort)
        #expect(c.cancelTitle == "Don't Abort" && c.cancelIsDefault)
        #expect(c.warning == nil && c.update == nil && !c.offersDowngrade)
        // Each thing `runUpdateAbort` does, and does not do, is named.
        for words in ["An unfinished update is marked Cancelled", "already succeeded or was cancelled is left as it is",
                      "with no update on record, only the nodes are released", "stays on record until the next update replaces it", "Nothing is rolled back",
                      "every node keeps the release it runs", "a node already installing may still finish",
                      "clears the update's annotations", "lifts the cordon the update set", "A node you cordoned yourself stays cordoned"] {
            #expect(c.message.contains(words), "the question does not say: \(words)")
        }
    }

    @Test("abort asks, then runs the abort script; no runs nothing")
    func driver() async {
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(StatusSequence([]), runner: runner, answer: true, asked: asked).abort()
        #expect(result == .ran(.notStarted, .succeeded, "k3sm released every node from the update, and marked any unfinished update Cancelled. Nothing was rolled back: every node keeps the release it runs, and a node already installing may still finish."))
        #expect(asked.all.map(\.title) == ["Abort the update?"])
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.updateAbort, teamID: Self.team)])

        let declined = LANRunner()
        #expect(await ManagedUpdateTests.driver(StatusSequence([]), runner: declined, answer: false).abort() == .declined)
        #expect(declined.scripts.isEmpty)
    }

    @Test("a failed abort shows the CLI's cleaned text, and the script's refusals their own")
    func outcomes() {
        // A successful abort claims no more than the question did.
        let done = LifecycleOutcome.text(.succeeded, verb: .updateAbort)
        #expect(done == "k3sm released every node from the update, and marked any unfinished update Cancelled. Nothing was rolled back: every node keeps the release it runs, and a node already installing may still finish.")
        for words in ["Nothing was rolled back", "every node keeps the release it runs", "a node already installing may still finish"] {
            #expect(done.contains(words) && UpdateConfirmationText.abort.lowercased().contains(words.lowercased().replacingOccurrences(of: "was", with: "is")),
                    "the outcome and the question disagree on: \(words)")
        }
        // A node the CLI could not release (exit 1) names it.
        let partial = PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm update abort: release node mac-2: \u{1B}[31mconflict\n")
        guard case .ran(.notStarted, .failed(exitStatus: 1), let text) = UpdateDriver.classify(partial, verb: .updateAbort) else {
            Issue.record("a failed abort was not shown as one")
            return
        }
        #expect(text.hasPrefix("k3sm update abort failed: ") && text.contains("release node mac-2") && !text.contains("\u{1B}"))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 100)), verb: .updateAbort)
            == .ran(.notStarted, .failed(exitStatus: 100),
                    "The installed k3sm at /Library/k3sm/k3sm, or a folder above it, is not owned by root or is writable by others, so nothing was run."))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 2)), verb: .updateAbort)
            == .ran(.notStarted, .failed(exitStatus: 2),
                    "The installed k3sm did not accept `k3sm update abort`. Update k3sm, or run `sudo k3sm update abort` in Terminal."))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .cancelled), verb: .updateAbort)
            == .ran(.notStarted, .cancelled, "Cancelled. Nothing was changed."))
    }

    // MARK: the k3sm CLI contract

    static var updateSource: String? {
        LifecycleScriptTests.cliDirectory.flatMap { try? String(contentsOf: $0.appending(path: "update.go"), encoding: .utf8) }
    }

    /// The body of `func <name>(` in `source`, up to the next top-level func.
    static func body(of name: String, in source: String) -> Substring? {
        guard let start = source.range(of: "\nfunc \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\nfunc ")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test("k3sm's abort does what the question says", .enabled(if: updateSource?.contains("\"abort\"") == true))
    func abortContract() throws {
        let update = try #require(Self.updateSource)
        #expect(update.contains("case \"abort\":\n\t\treturn runUpdateAbort("), "k3sm update has no abort subcommand")
        let abort = try #require(Self.body(of: "runUpdateAbort", in: update), "no runUpdateAbort in cmd/k3sm/update.go")
        // It takes no argument: the app passes none.
        #expect(abort.contains("if len(args) > 0 {"))
        // The Update is marked Cancelled through its status, never deleted.
        #expect(abort.contains("abortUpdateStatus(u,") && abort.contains("writeUpdateStatus(ctx, dyn, u)"))
        #expect(!abort.contains(".Delete("), "the abort deletes the Update; the question says it stays on record")
        let mark = try #require(Self.body(of: "abortUpdateStatus", in: update))
        #expect(mark.contains("u.Status.Phase = updatesv1alpha1.UpdatePhaseCancelled"))
        // Every k3sm.io/update-* annotation goes; only the controller's cordon is lifted.
        #expect(abort.contains("strings.HasPrefix(k, updateAnnotationPrefix)"))
        #expect(update.contains("const updateAnnotationPrefix = \"k3sm.io/update-\""))
        #expect(abort.contains("n.Annotations[updatectl.CordonedAnnotation] == \"true\" && n.Spec.Unschedulable"))
        #expect(abort.contains("\"unschedulable\": false"))
        // Nothing in it installs, downloads or restarts: no node's release changes.
        for word in ["install.", "update.Latest", "Restart", "Download"] {
            #expect(!abort.contains(word), "the abort mentions \(word); the question says nothing is rolled back")
        }
    }

    /// The `k3sm update apply` flags the app's update path never passes, each with why. The app's
    /// flags plus these must be every flag the apply declares, so a new apply flag reds the test
    /// until it is either passed or named here. A name may be listed before the CLI declares it.
    static let applyFlagsNeverPassed: [String: String] = [
        // An operator's recovery verb: it removes the server's release pin and exits, takes no
        // other flag, and runs as root from Terminal. No app path removes a pin.
        "clear-pin": "operator recovery, run by hand",
        // Binds a roll to one archive digest. The update menu never passes it; the version-set
        // roll does, through its own root verb (BundledRollScriptBuilder.arguments, with its own
        // argv test), never through UpdateOptions.
        "pin-sha256": "passed only by the version-set root verb, never by the update menu",
    ]

    @Test("every update option the app passes is a flag k3sm update apply declares",
          .enabled(if: updateSource?.contains("func runUpdateApply(") == true))
    func optionFlagsDeclared() throws {
        let update = try #require(Self.updateSource)
        let apply = try #require(Self.body(of: "runUpdateApply", in: update))
        var declared = Set<String>()
        for line in apply.split(separator: "\n") where line.contains("fsFlags.Bool(\"") || line.contains("fsFlags.String(\"") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 2 { declared.insert(String(parts[1])) }
        }
        try #require(declared.contains("yes"), "found no apply flags; the scrape is stale")
        // Every option on: every flag the app can ever pass.
        let all = UpdateOptions(drain: true, allowDowngrade: true, signature: .required).arguments
        #expect(all == ["update", "apply", "--yes", "--drain", "--allow-downgrade", "--signature", "required"])
        for flag in all.dropFirst(2) where flag.hasPrefix("--") {
            #expect(declared.contains(String(flag.dropFirst(2))), "\(flag) is not a k3sm update apply flag")
        }
        // The signature words are the two the CLI accepts, and its default is the app's.
        #expect(update.contains("[--signature if-signed|required]"))
        #expect(UpdateSignaturePolicy.allCases.map(\.rawValue) == ["if-signed", "required"])
        #expect(apply.contains("fsFlags.String(\"signature\", string(updatesv1alpha1.UpdateSignatureIfSigned)"))
        // --version carries the release the user confirmed (UpdateVersionPinTests); with it, the app
        // passes every flag the apply declares.
        let pinned = LifecycleScriptBuilder.updateApplyArguments(options: UpdateOptions(drain: true, allowDowngrade: true, signature: .required),
                                                                 release: ReleaseTag("v0.1.8")!)
        #expect(pinned == all + ["--version", "v0.1.8"])
        let passed = Set(pinned.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) })
        let neverPassed = Set(Self.applyFlagsNeverPassed.keys)
        #expect(passed.isDisjoint(with: neverPassed), "the app passes a flag listed as never passed: \(passed.intersection(neverPassed))")
        #expect(passed == declared.subtracting(neverPassed),
                "the app and k3sm update apply disagree on the flags: app \(passed), CLI \(declared), never passed \(neverPassed)")
    }
}
