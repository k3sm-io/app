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

/// The channel's root step: a closed enum selects one of two fixed scripts, and
/// nothing a caller supplies reaches either.
@Suite("update channel root step")
struct UpdateChannelScriptTests {
    static let team = TeamID("TEAMTEAM12")!

    /// The whole table: the fixture, the verb, the last line, the prompt.
    static let table: [(channel: UpdateChannel, fixture: String, verb: LifecycleVerb, argv: [String], prompt: String)] = [
        (.stable, "update-channel-stable.sh", .updateChannelStable, ["update", "channel", "stable"],
         "k3sm wants to set this cluster's update channel to stable, which offers final releases only."),
        (.rc, "update-channel-rc.sh", .updateChannelRC, ["update", "channel", "rc"],
         "k3sm wants to set this cluster's update channel to rc, which also offers release candidates to every node."),
    ]

    @Test("each channel's root script and prompt, byte for byte")
    func updateChannelRootScriptGolden() throws {
        // The entry point takes the enum and a Team ID and nothing else: a String
        // parameter, or a policy that admits developer mode, does not compile here.
        let render: (UpdateChannel, TeamID) -> RootScript = LifecycleScriptBuilder.renderUpdateChannel
        #expect(Self.table.map(\.channel) == UpdateChannel.allCases)
        for row in Self.table {
            let script = render(row.channel, Self.team)
            let bytes = try Data(contentsOf: RootScriptGoldenTests.fixtureDirectory.appending(path: row.fixture))
            #expect(script.text == String(decoding: bytes, as: UTF8.self), "\(row.fixture)")
            #expect(script.prompt == row.prompt)
            #expect(row.verb.prompt == row.prompt)
            // It reads nothing in, takes no staging lock and returns nothing.
            #expect(!script.readsInput && !script.usesStagingLock && !script.capturesOutput)
            // The checked preamble, then one line: nothing else runs as root.
            let line = "exec \"$k3sm\" " + row.argv.map(ShellQuote.quote).joined(separator: " ") + "\n"
            #expect(script.text == InstalledCLIPreamble.render(teamID: Self.team, cliPath: K3smCLI.path) + line)
            #expect(script.text.contains("codesign --verify"))
            #expect(!script.text.contains(DeveloperMode.markerPath))
        }
    }

    @Test("no caller-supplied string reaches the root script")
    func closedInput() throws {
        // Only the two exact words make a channel: every hostile string, and every
        // near miss, makes none, so there is nothing to pass.
        #expect(UpdateChannel.allCases == [.stable, .rc])
        for word in hostileStrings + ["Stable", "RC", " rc", "rc ", "rc\n", "beta", "stable; id", "rc --yes"] {
            #expect(UpdateChannel(rawValue: word) == nil, "\(word)")
        }
        for row in Self.table {
            #expect(LifecycleVerb.updateChannel(row.channel) == row.verb)
            #expect(row.verb.channel == row.channel)
            #expect(row.verb.command == row.argv.joined(separator: " "))
            #expect(K3smCLI.updateChannelArguments(row.channel) == row.argv)
            // The argv /bin/sh hands the CLI is exactly the constant.
            let last = try #require(LifecycleScriptBuilder.renderUpdateChannel(row.channel, teamID: Self.team).text
                .split(separator: "\n").last)
            let prefix = "exec \"$k3sm\" "
            try #require(last.hasPrefix(prefix))
            let probe = "set -- " + last.dropFirst(prefix.count) + "\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
            let result = try shell(["-c", probe])
            #expect(result.status == 0)
            #expect(result.output == row.argv.joined(separator: "\n") + "\n")
        }
        // The two verbs are all the channel verbs, and none is a verb any other
        // renderer takes: they render only through `renderUpdateChannel`.
        #expect(LifecycleVerb.channelVerbs == Self.table.map(\.verb))
        for verb in LifecycleVerb.channelVerbs {
            #expect(LifecycleScriptBuilder.FixedVerb(verb) == nil)
            #expect(LifecycleScriptBuilder.FixedVerb(rawValue: verb.rawValue) == nil)
            #expect(verb.isChannel && !verb.isUpdate && !verb.isLAN && verb.requiredState == nil)
        }
        #expect(LifecycleVerb.allCases.filter(\.isChannel) == LifecycleVerb.channelVerbs)
    }

    @Test("each refusal stops the channel script before the CLI runs", arguments: LifecycleScriptTests.refusals)
    func refusal(_ r: LifecycleScriptTests.Refusal) throws {
        let line = LifecycleScriptBuilder.renderUpdateChannel(.rc, teamID: TeamID("ABCDE12345")!, cliPath: r.cliPath).command(inputPath: "/dev/null")
        let result = try LifecycleScriptTests.run(line)
        #expect(result.status == r.status, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(r.message), "stderr: \(result.stderr)")
    }

    @Test("no other driver runs a channel verb", arguments: LifecycleVerb.channelVerbs)
    func otherDrivers(_ verb: LifecycleVerb) async {
        let runner = LANRunner()
        let lifecycle = LifecycleDriver(policy: .developerID(Self.team), readStatus: { Self.report("stable") },
                                        confirm: { _ in true }, runner: runner)
        guard case .refused = await lifecycle.perform(verb, expected: .running) else {
            Issue.record("the lifecycle driver ran \(verb.rawValue)")
            return
        }
        #expect(runner.scripts.isEmpty)
    }

    // MARK: - the outcome of each exit

    static let notVerifiedRC = "The update channel is set to rc, but the check after it failed, so what it offers is not verified. "
        + "No update started. Run `sudo k3sm update check` in Terminal, or wait for the server's next check."

    @Test("each exit of k3sm update channel maps to its own outcome")
    func exitMapping() {
        func text(_ status: Int32, _ verb: LifecycleVerb = .updateChannelRC) -> String {
            LifecycleOutcome.text(.failed(exitStatus: status), verb: verb)
        }
        #expect(LifecycleOutcome.text(.succeeded, verb: .updateChannelRC)
            == "The update channel is now rc: this cluster is also offered release candidates. No update started.")
        #expect(LifecycleOutcome.text(.succeeded, verb: .updateChannelStable)
            == "The update channel is now stable: this cluster is offered final releases only. No update started.")
        #expect(text(1) == "k3sm could not confirm setting the update channel to rc: the cluster could not be reached, refused the write, or does not serve the setting yet. "
            + "The setting may or may not have been applied; the picker shows what the cluster reports. "
            + "No update started. Try again in a minute; if it keeps failing, check the server's k3sm version and log.")
        #expect(text(2) == "The installed k3sm did not accept `k3sm update channel rc`. Update k3sm, or run `sudo k3sm update channel rc` in Terminal.")
        // Exit 3 is a write that took: never the root refusal the shared table gives it.
        #expect(LifecycleExit.channelSetNotVerified == LifecycleExit.needsRoot)
        #expect(text(3) == Self.notVerifiedRC)
        #expect(text(3, .updateChannelStable) == Self.notVerifiedRC.replacingOccurrences(of: "to rc", with: "to stable"))
        #expect(text(3) != LifecycleOutcome.text(.failed(exitStatus: 3), verb: .stop))
        #expect(!text(3).contains("nothing was done"))
        // The checked preamble's refusals keep their own words.
        #expect(text(100) == LifecycleOutcome.text(.failed(exitStatus: 100), verb: .updateCancel))
        #expect(text(101) == LifecycleOutcome.text(.failed(exitStatus: 101), verb: .updateCancel))
        // Any other status claims nothing about the channel.
        #expect(text(9) == "k3sm update channel rc failed with exit status 9. The logs say why.")
        #expect(LifecycleOutcome.text(.cancelled, verb: .updateChannelRC) == "Cancelled. Nothing was changed.")
        // Exit 3 on every other verb stays what it was.
        #expect(LifecycleOutcome.text(.failed(exitStatus: 3), verb: .updateCancel) == "k3sm did not run as root, so nothing was done.")
    }

    @Test("a refused write adds the CLI's cleaned words, and a written one claims no failure of the write")
    func classify() {
        let refused = PrivilegedRun(outcome: .failed(exitStatus: 1),
                                    errorOutput: "k3sm update channel: setting the channel takes cluster-admin, \u{1B}[31mwhich these credentials do not have\n")
        guard case .ran(.failed(exitStatus: 1), let text) = UpdateChannelDriver.classify(refused, channel: .rc) else {
            Issue.record("a refused write was not shown as one")
            return
        }
        #expect(text.hasPrefix("k3sm could not confirm setting the update channel to rc:"))
        #expect(text.contains("takes cluster-admin") && !text.contains("\u{1B}"))

        // The check's own error after a write is not the outcome's sentence.
        let written = PrivilegedRun(outcome: .failed(exitStatus: 3), errorOutput: "k3sm update check: no route\n")
        #expect(UpdateChannelDriver.classify(written, channel: .rc) == .ran(.failed(exitStatus: 3), Self.notVerifiedRC))
    }

    // MARK: - the driver

    static func report(_ channel: String?, role: String = "server", state: String = "ok") -> StatusReport {
        var wide = ["latest": "v0.3.0"]
        if let channel { wide["channel"] = channel }
        let rows = [StatusRow(name: "server", state: "running", detail: "d"),
                    StatusRow(name: "update", state: state, detail: "every node runs k3sm v0.3.0", wide: wide)]
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "s", rows: rows, workers: [])
    }

    static func driver(_ reads: StatusSequence, runner: LANRunner, answer: Bool, asked: Questions? = nil) -> UpdateChannelDriver {
        // The driver takes a Team ID, never a `TrustPolicy`: a build with no pin
        // has no value to construct it with, developer mode or not.
        UpdateChannelDriver(teamID: team, readStatus: { reads.next() }, confirm: { c in
            asked?.append(c)
            return answer
        }, runner: runner)
    }

    @Test("it asks, re-reads, then runs the one script for that channel", arguments: table.map(\.channel))
    func driverRuns(_ channel: UpdateChannel) async {
        let other = channel == .rc ? "stable" : "rc"
        let reads = StatusSequence([Self.report(other), Self.report(other)])
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, answer: true, asked: asked).perform(channel)
        #expect(result == .ran(.succeeded, LifecycleOutcome.text(.succeeded, verb: .updateChannel(channel))))
        #expect(reads.reads == 2)
        #expect(asked.all.map(\.verb) == [.updateChannel(channel)])
        #expect(runner.scripts == [LifecycleScriptBuilder.renderUpdateChannel(channel, teamID: Self.team)])
    }

    @Test("answering no runs nothing")
    func declined() async {
        let runner = LANRunner()
        let reads = StatusSequence([Self.report("stable")])
        #expect(await Self.driver(reads, runner: runner, answer: false).perform(.rc) == .declined)
        #expect(runner.scripts.isEmpty)
    }

    @Test("it refuses before the question and again after it")
    func refusals() async {
        let picker = UpdateChannelPicker.self
        for (name, first, second, want) in [
            ("no report", nil, nil, "k3sm could not read the status of this Mac just now, so it did not change the update channel."),
            ("already there", Self.report("rc"), nil, "The update channel is already rc. Nothing was changed."),
            ("a worker", Self.report("stable", role: "agent"), nil, picker.workerReason + " Nothing was changed."),
            ("an unknown channel", Self.report("beta"), nil, picker.unknownChannelReason + " Nothing was changed."),
            ("no channel", Self.report(nil), nil, picker.noChannelReason + " Nothing was changed."),
            ("a roll", Self.report("stable", state: "rolling"), nil, picker.rollingReason + " Nothing was changed."),
            ("gone while asked", Self.report("stable"), nil, "k3sm could not read the status of this Mac just now, so it did not change the update channel."),
            ("rolling while asked", Self.report("stable"), Self.report("stable", state: "rolling"), picker.rollingReason + " Nothing was changed."),
            ("set while asked", Self.report("stable"), Self.report("rc"), "The update channel is already rc. Nothing was changed."),
        ] as [(String, StatusReport?, StatusReport?, String)] {
            let runner = LANRunner()
            let result = await Self.driver(StatusSequence([first, second]), runner: runner, answer: true).perform(.rc)
            #expect(result == .refused(want), "\(name)")
            #expect(runner.scripts.isEmpty, "\(name)")
        }
    }

    @Test("the question says what is offered and what going back costs")
    func question() {
        let rc = LifecycleConfirmation(verb: .updateChannelRC, report: Self.report("stable"))
        #expect(rc.title == "Offer release candidates on this cluster?")
        #expect(rc.message == UpdateConfirmationText.channelRC)
        for words in ["release candidates", "starts no update", "does not move a node down", "waits for a higher final release"] {
            #expect(rc.message.contains(words), "the question does not say: \(words)")
        }
        // Opting in takes a deliberate click.
        #expect(rc.cancelIsDefault && rc.update == nil && !rc.offersDowngrade && rc.warning == nil)

        let stable = LifecycleConfirmation(verb: .updateChannelStable, report: Self.report("rc"))
        #expect(stable.title == "Offer only final releases on this cluster?")
        #expect(stable.message == UpdateConfirmationText.channelStable)
        for words in ["final releases", "starts no update", "does not move a node down", "waits for a higher final release"] {
            #expect(stable.message.contains(words), "the question does not say: \(words)")
        }
        #expect(!stable.cancelIsDefault)
    }

    // MARK: - the k3sm CLI contract

    /// The file at `cmd/k3sm/<name>` with its whitespace runs collapsed; nil with no sibling.
    static func cli(_ name: String) -> String? {
        LifecycleScriptTests.cliDirectory
            .flatMap { try? String(contentsOf: $0.appending(path: name), encoding: .utf8) }?
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    /// Whether the pin runs: a caller who set K3SM_DIR (`hack/ci.sh` does whenever it
    /// has a checkout) asked for it, so it runs and fails by name if the source is
    /// missing; with no K3SM_DIR it runs only when the sibling checkout is there.
    static var pinEnabled: Bool {
        ProcessInfo.processInfo.environment["K3SM_DIR"] != nil || cli("updatechannel.go") != nil
    }

    @Test("the exits mapped here are the ones k3sm update channel has", .enabled(if: pinEnabled))
    func exitContract() throws {
        let channel = try #require(Self.cli("updatechannel.go"),
            "no cmd/k3sm/updatechannel.go under K3SM_DIR or the k3sm sibling; the exit pin cannot run")
        #expect(channel.contains("func setUpdateChannel("), "no setUpdateChannel in updatechannel.go; the scrape is stale")
        let update = try #require(Self.cli("update.go"))
        let status = try #require(Self.cli("status.go"))
        #expect(update.contains("case \"channel\":\n return runUpdateChannel("))
        #expect(channel.contains("const exitChannelCheckFailed = \(LifecycleExit.channelSetNotVerified)\n"))
        #expect(status.contains("exitInternalError = \(LifecycleExit.failed)\n"))
        #expect(status.contains("exitUsage = \(LifecycleExit.usage)\n"))
        let set = try #require(UpdateAbortTests.body(of: "setUpdateChannel", in: channel))
        // The value is matched against the two names: the enum holds at both ends.
        #expect(set.contains("channel != updatesv1alpha1.UpdateChannelStable && channel != updatesv1alpha1.UpdateChannelRC"))
        // Exit 3 follows the write and its "now" line, never a root check.
        let written = try #require(set.range(of: "The update channel is now %s"))
        let notVerified = try #require(set.range(of: "return exitChannelCheckFailed"))
        #expect(written.lowerBound < notVerified.lowerBound)
        // setUpdateChannel and the verb that calls it carry no root check, so exit 3
        // (not verified) cannot be a refusal for want of root (LifecycleExit.needsRoot is 3 too).
        let verb = try #require(UpdateAbortTests.body(of: "runUpdateChannel", in: channel))
        for (name, body) in [("setUpdateChannel", set), ("runUpdateChannel", verb)] {
            for gate in ["exitNeedsRoot", "env.root", "requireRoot(", "Geteuid", "Getuid"] {
                #expect(!body.contains(gate), "\(name) now has a root check (\(gate)); exit 3 would be ambiguous")
            }
        }
        // Forbidden and a server with no CRD both exit 1, so one outcome covers them.
        #expect(set.contains("apierrors.IsForbidden(err)"))
        let refusedWrite = try #require(set.range(of: "writeUpdateChannel("))
        #expect(set[refusedWrite.lowerBound..<written.lowerBound].components(separatedBy: "return ").dropFirst()
            .allSatisfy { $0.hasPrefix("exitInternalError") })
    }
}
