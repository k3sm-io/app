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

@testable import K3smMCP
@testable import K3smStatus

/// The channel's reading from `k3sm status -o json`, and everything the app
/// decides from it, one named case per decision.
@Suite("the update channel")
struct UpdateChannelTests {
    enum GateCase: String, CaseIterable, CustomTestStringConvertible {
        case readingAbsentAndUnknown, pickerStateAndReasons, eyebrow, paneStateLine, offerTableDecideUnchanged, mcpField,
             preferencesHoldNoChannelKey
        var testDescription: String { rawValue }
    }

    @Test("reading wide.channel decides the picker, the eyebrow, the pane and the MCP field",
          arguments: GateCase.allCases)
    func updateChannelReadingDecidesPickerAndEyebrow(_ gate: GateCase) throws {
        switch gate {
        case .readingAbsentAndUnknown: try reading()
        case .pickerStateAndReasons: picker()
        case .eyebrow: eyebrow()
        case .paneStateLine: paneStateLine()
        case .offerTableDecideUnchanged: offerTable()
        case .mcpField: mcpField()
        case .preferencesHoldNoChannelKey: try preferences()
        }
    }

    // MARK: - fixtures

    static let rolled = ["latest": "v0.3.0", "checked": "2026-11-05T09:00:00Z"]

    static func row(_ state: String = "ok", detail: String = "every node runs k3sm v0.3.0", channel: String?,
                    wide: [String: String] = rolled) -> StatusRow {
        var wide = wide
        if let channel { wide["channel"] = channel }
        return StatusRow(name: "update", state: state, detail: detail, wide: wide)
    }

    static func report(_ row: StatusRow?, role: String = "server", verdict: Verdict = .running,
                       release: String? = nil, workers: [String] = []) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: verdict, role: role, summary: "s",
                     rows: [StatusRow(name: role, state: "running", detail: "d")] + (row.map { [$0] } ?? []),
                     workers: workers.enumerated().map {
                         StatusWorker(name: "node-\($0.offset)", role: "agent", version: "v1.36.2+k3sm.\($0.element)")
                     },
                     release: release.map { StatusRelease(text: $0) })
    }

    static func channel(_ word: String?) -> StatusReport { report(row(channel: word)) }

    /// The JSON the CLI prints, with `wide` as given, through the real decoder.
    static func decoded(wide: String) throws -> StatusReport {
        let json = """
        {"schemaVersion":1,"verdict":"running","role":"server","summary":"s","rows":[\
        {"name":"update","state":"ok","severity":"ok","detail":"d","wide":\(wide)}]}
        """
        return try StatusReport.decode(Data(json.utf8))
    }

    // MARK: - reading

    private func reading() throws {
        for (wide, want) in [
            (#"{"channel":"stable"}"#, UpdateChannelReading.known(.stable)),
            (#"{"channel":"rc"}"#, .known(.rc)),
            (#"{"latest":"v0.3.0"}"#, .absent), // an older CLI's row, or an older server's pair
            (#"{"channel":""}"#, .absent),
            (#"{"channel":7}"#, .absent), // wide keeps string values only
            (#"{"channel":"beta"}"#, .unknown),
            (#"{"channel":"RC"}"#, .unknown),
            (#"{"channel":" rc"}"#, .unknown),
            (#"{"channel":"rc‮"}"#, .unknown),
            (#"{"channel":"stable\n"}"#, .unknown),
        ] as [(String, UpdateChannelReading)] {
            #expect(UpdateChannelReading(report: try Self.decoded(wide: wide)) == want, "\(wide)")
        }
        #expect(UpdateChannelReading(report: nil) == .absent)
        #expect(UpdateChannelReading(report: Self.report(nil)) == .absent)

        // Only rc reads as rc: absent and unknown both behave as stable.
        #expect(UpdateChannelReading.known(.rc).channel == .rc)
        for stable in [UpdateChannelReading.known(.stable), .absent, .unknown] {
            #expect(stable.channel == .stable)
        }
        #expect(UpdateChannelReading.known(.rc).note == nil)
        #expect(UpdateChannelReading.known(.stable).note == nil)
        #expect(UpdateChannelReading.absent.note == nil)
        // Unknown says why, without repeating what it could not read.
        #expect(UpdateChannelReading.unknown.note == UpdateChannelReading.unknownNote)
        #expect(UpdateChannelReading.unknownNote.contains("stable"))
    }

    // MARK: - picker

    private func picker() {
        let idle = UpdateProgress()
        var rolling = UpdateProgress()
        rolling.applyStarted()
        let rollingRow = StatusRow(name: "update", state: "rolling", detail: "d",
                                   wide: ["target": "v0.3.0", "phase": "Rolling", "channel": "rc"])

        typealias Picker = UpdateChannelPicker
        for (name, report, progress, developer, want) in [
            // Enabled only on a running or degraded server's known channel.
            ("stable", Self.channel("stable"), idle, false, Picker(selection: .stable, enabled: true, reason: nil)),
            ("rc", Self.channel("rc"), idle, false, Picker(selection: .rc, enabled: true, reason: nil)),
            ("degraded", Self.report(Self.row(channel: "rc"), verdict: .degraded), idle, false,
             Picker(selection: .rc, enabled: true, reason: nil)),

            // No cluster: no report, or one from a k3sm not running.
            ("no report", nil, idle, false, Picker(selection: .stable, enabled: false, reason: Picker.noClusterReason)),
            ("stopped", Self.report(Self.row(channel: "rc"), verdict: .stopped), idle, false,
             Picker(selection: .rc, enabled: false, reason: Picker.noClusterReason)),
            ("not installed", Self.report(nil, verdict: .notInstalled), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.noClusterReason)),
            ("verdict unknown", Self.report(Self.row(channel: "stable"), verdict: .unknown), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.noClusterReason)),

            // A role this app cannot read is treated as no cluster.
            ("no role", Self.report(Self.row(channel: "rc"), role: "mystery"), idle, false,
             Picker(selection: .rc, enabled: false, reason: Picker.noClusterReason)),

            // A developer build, and a worker, keep showing what the row says.
            ("developer build", Self.channel("rc"), idle, true,
             Picker(selection: .rc, enabled: false, reason: Picker.developerBuildReason)),
            ("worker", Self.report(Self.row(channel: "rc"), role: "agent"), idle, false,
             Picker(selection: .rc, enabled: false, reason: Picker.workerReason)),

            // No channel reported, or one this app does not know: reads stable.
            ("no row", Self.report(nil), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.noChannelReason)),
            ("older CLI", Self.channel(nil), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.noChannelReason)),
            ("unknown", Self.channel("beta"), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.unknownChannelReason)),

            // During a roll, from the app's progress or from the row.
            ("app rolling", Self.channel("rc"), rolling, false,
             Picker(selection: .rc, enabled: false, reason: Picker.rollingReason)),
            ("row rolling", Self.report(rollingRow), idle, false,
             Picker(selection: .rc, enabled: false, reason: Picker.rollingReason)),

            // A lasting reason is never masked by a passing one.
            ("no cluster over developer", nil, idle, true,
             Picker(selection: .stable, enabled: false, reason: Picker.noClusterReason)),
            ("developer over worker", Self.report(Self.row(channel: "rc"), role: "agent"), idle, true,
             Picker(selection: .rc, enabled: false, reason: Picker.developerBuildReason)),
            ("worker over no channel", Self.report(Self.row(channel: nil), role: "agent"), idle, false,
             Picker(selection: .stable, enabled: false, reason: Picker.workerReason)),
            ("no channel over rolling", Self.channel(nil), rolling, false,
             Picker(selection: .stable, enabled: false, reason: Picker.noChannelReason)),
        ] as [(String, StatusReport?, UpdateProgress, Bool, Picker)] {
            #expect(Picker.decide(report: report, progress: progress, developerBuild: developer) == want, "\(name)")
        }

        // Every reason is a sentence of its own, none blank.
        let reasons = [Picker.noClusterReason, Picker.developerBuildReason, Picker.workerReason, Picker.noChannelReason,
                       Picker.unknownChannelReason, Picker.rollingReason]
        #expect(Set(reasons).count == reasons.count)
        #expect(reasons.allSatisfy { !$0.isEmpty })
        #expect(Picker.workerReason.contains("set on the server"))

        // A developer build is told the command that changes a channel, not the apply.
        #expect(Picker.developerBuildReason != UpdateOffer.developerBuildReason)
        #expect(!Picker.developerBuildReason.contains("update apply"))
        for channel in UpdateChannel.allCases {
            #expect(Picker.developerBuildReason.contains("`sudo k3sm update channel \(channel.rawValue)`"))
        }

        // The picker's items and its help tag.
        #expect(UpdateChannel.allCases.map(\.title) == ["Stable", "Release candidates"])
        #expect(Help.Updates.channel(Picker(selection: .stable, enabled: true, reason: nil)) == Help.Updates.channel.text)
        #expect(Help.Updates.channel(Picker(selection: .rc, enabled: false, reason: Picker.rollingReason)) == Picker.rollingReason)
    }

    // MARK: - eyebrow

    private func eyebrow() {
        let app = AppVersion(info: ["CFBundleShortVersionString": "0.3.0"])
        let installed = SemanticVersion("0.3.0-rc.1")
        let payload = SemanticVersion("0.3.0")
        let plain = app.versionCards(installed: installed, payload: payload)
        let plainLine = app.versionLine(installed: installed, payload: payload)

        // Stable, absent and unknown keep today's words exactly.
        #expect(plain[0].eyebrow == "INSTALLED")
        for reading in [UpdateChannelReading.known(.stable), .absent, .unknown] {
            #expect(app.versionCards(installed: installed, payload: payload, channel: reading) == plain)
            #expect(app.versionLine(installed: installed, payload: payload, channel: reading) == plainLine)
        }

        // rc names the channel on the first card only; the value names the version.
        let rc = app.versionCards(installed: installed, payload: payload, channel: .known(.rc))
        #expect(rc[0].eyebrow == "INSTALLED · RC CHANNEL")
        #expect(rc[0].value == "0.3.0-rc.1")
        #expect(rc[1] == plain[1])
        #expect(app.versionLine(installed: installed, payload: payload, channel: .known(.rc))
            == "Installed · RC channel: 0.3.0-rc.1 · this app carries 0.3.0, a newer release")
        // With the installed release unknown, and with no payload, the same.
        #expect(app.versionCards(installed: nil, payload: nil, channel: .known(.rc))[0].eyebrow == "INSTALLED · RC CHANNEL")
        #expect(app.versionLine(installed: nil, payload: nil, channel: .known(.rc)).hasPrefix("Installed · RC channel: unknown · "))
        #expect(app.versionLine(installed: nil, payload: payload, channel: .known(.rc))
            == "Installed · RC channel: unknown · this app carries 0.3.0")

        // The pane's own label follows, and the card's words are its words.
        let version = SemanticVersion("0.3.0")
        #expect(UpdatesPaneFacts.decide(report: Self.channel("rc"), installed: version).installedLabel == "Installed · RC channel")
        for word in ["stable", nil, "beta"] as [String?] {
            #expect(UpdatesPaneFacts.decide(report: Self.channel(word), installed: version).installedLabel == "Installed")
        }
        #expect(UpdatesPaneFacts.decide(report: nil, installed: version).installedLabel == "Installed")
        #expect(UpdatesPaneFacts.decide(report: Self.report(nil), installed: version).installedLabel == "Installed")

        // Only an unknown channel adds a line to the pane, and it never
        // repeats what it could not read.
        #expect(UpdatesPaneFacts.decide(report: Self.channel("rc"), installed: version).channelNote == nil)
        #expect(UpdatesPaneFacts.decide(report: Self.channel("stable"), installed: version).channelNote == nil)
        #expect(UpdatesPaneFacts.decide(report: Self.channel(nil), installed: version).channelNote == nil)
        let unknown = UpdatesPaneFacts.decide(report: Self.channel("be\u{202E}ta"), installed: version)
        #expect(unknown.channelNote == UpdateChannelReading.unknownNote)
        #expect(unknown.channelNote?.contains("be\u{202E}ta") != true)
    }

    // MARK: - pane state line

    private func paneStateLine() {
        let version = SemanticVersion("0.2.3")
        func state(_ row: StatusRow, release: String = "v0.2.3") -> String {
            UpdatesPaneFacts.decide(report: Self.report(row, release: release), installed: version).state
        }
        let candidate = ["latest": "v0.3.0-rc.1"]

        // A candidate tag is called one, whatever the channel: an explicit
        // roll to a candidate on stable is still a candidate.
        #expect(state(Self.row("behind", detail: "k3sm v0.3.0-rc.1 is available", channel: "rc", wide: candidate))
            == "k3sm v0.3.0-rc.1, a release candidate, is available; at least one node runs an older release.")
        for word in ["rc", "stable"] {
            #expect(state(Self.row("rolling", detail: "d", channel: word, wide: ["target": "v0.3.0-rc.1", "phase": "Rolling"]))
                == "An update to v0.3.0-rc.1, a release candidate, is rolling.")
        }
        #expect(state(Self.row("ok", detail: "d", channel: "rc", wide: candidate), release: "v0.3.0-rc.1")
            == "This cluster runs the latest release, a release candidate.")

        // A final on rc, and a pseudo-version, are not.
        #expect(state(Self.row("behind", detail: "d", channel: "rc"))
            == "k3sm v0.3.0 is available; at least one node runs an older release.")
        #expect(state(Self.row("ok", detail: "d", channel: "rc"), release: "v0.3.0")
            == "This cluster runs the latest release.")
        #expect(state(Self.row("behind", detail: "d", channel: "rc", wide: ["latest": "v0.3.1-0.20261105090000-0123456789ab"]))
            == "k3sm v0.3.1-0.20261105090000-0123456789ab is available; at least one node runs an older release.")

        // Stable reads byte for byte as a row with no channel, in every state.
        for (state, wide) in [
            ("behind", Self.rolled), ("ok", Self.rolled), ("ahead", Self.rolled),
            ("rolling", ["target": "v0.3.0", "phase": "Rolling"]), ("unknown", [:]), ("sideways", [:]),
        ] as [(String, [String: String])] {
            let report = { (word: String?) in Self.report(Self.row(state, detail: "d", channel: word, wide: wide), release: "v0.2.3") }
            #expect(UpdatesPaneFacts.decide(report: report("stable"), installed: version)
                == UpdatesPaneFacts.decide(report: report(nil), installed: version), "\(state)")
        }
    }

    // MARK: - the offer

    /// `decide` reads no channel: each row answers the same under any word.
    private func offerTable() {
        let rc1 = "v0.3.0-rc.1", rc2 = "v0.3.0-rc.2"
        for (name, state, detail, tag, release, workers, want) in [
            ("a candidate on a behind row", "behind", "d", rc1, "v0.2.3", [], UpdateOffer.available(tag: rc1)),
            ("rc.1 to rc.2", "behind", "d", rc2, rc1, [], .available(tag: rc2)),
            ("rc.9 to rc.10", "behind", "d", "v0.3.0-rc.10", "v0.3.0-rc.9", [], .available(tag: "v0.3.0-rc.10")),
            ("a candidate to its final", "behind", "d", "v0.3.0", rc2, [], .available(tag: "v0.3.0")),
            ("ahead after leaving rc", "ahead", "newer than the latest release: a (v0.3.0-rc.2)", "v0.2.3", rc2, [], .hidden),
            ("every node above the tag", "behind", "d", rc1, rc2, ["0.3.0-rc.2"], .hidden),
            ("one node above and one below", "behind", "d", "v0.2.3", rc1, ["0.2.2"], .available(tag: "v0.2.3")),
            ("up to date on a candidate", "ok", "d", rc2, rc2, [], .hidden),
        ] as [(String, String, String, String, String, [String], UpdateOffer)] {
            for word in [nil, "stable", "rc", "beta"] as [String?] {
                let row = Self.row(state, detail: detail, channel: word, wide: ["latest": tag])
                let report = Self.report(row, release: release, workers: workers)
                #expect(UpdateOffer.decide(report: report, progress: UpdateProgress()) == want, "\(name), \(word ?? "absent")")
            }
        }

        // The tag read from the detail survives the trailing channel note.
        let trailing = StatusRow(name: "update", state: "behind",
                                 detail: "k3sm v0.3.0-rc.1 is available; behind: a (v0.2.3); channel rc",
                                 wide: ["channel": "rc"])
        #expect(UpdateOffer.latestTag(in: trailing) == rc1)
        #expect(UpdateOffer.decide(report: Self.report(trailing, release: "v0.2.3"), progress: UpdateProgress())
            == .available(tag: rc1))
    }

    // MARK: - MCP

    private func mcpField() {
        func row(_ word: String?) -> [String: K3smMCP.JSONValue]? {
            ClusterTools.updateRow(Self.channel(word))?.objectValue
        }
        #expect(row("stable")?["channel"] == K3smMCP.JSONValue.string("stable"))
        #expect(row("rc")?["channel"] == K3smMCP.JSONValue.string("rc"))
        #expect(row(nil)?["channel"] == K3smMCP.JSONValue.null)
        #expect(row("stable")?["channelNote"] == K3smMCP.JSONValue.null)
        #expect(row("rc")?["channelNote"] == K3smMCP.JSONValue.null)
        #expect(row(nil)?["channelNote"] == K3smMCP.JSONValue.null)

        // Unknown reads as stable and says so, with the word nowhere in it.
        let unknown = row("be\u{202E}ta")
        #expect(unknown?["channel"] == K3smMCP.JSONValue.string("stable"))
        #expect(unknown?["channelNote"] == K3smMCP.JSONValue.string(UpdateChannelReading.unknownNote))

        // Beside `latest`, and declared in the tool's schema.
        #expect(row("rc")?["latest"] == K3smMCP.JSONValue.string("v0.3.0"))
        let declared = Schema.updateRow.objectValue?["properties"]?.objectValue
        #expect(declared?["channel"] != nil)
        #expect(declared?["channelNote"] != nil)
    }

    // MARK: - preferences

    /// The cluster is the one source: no preference holds a channel. This
    /// asserts the channel key's absence, so a new unrelated key leaves it be.
    private func preferences() throws {
        #expect(!AppPreferences.Key.allCases.contains { $0.rawValue.lowercased().contains("channel") })
        #expect(!AppPreferences.layoutKeys.contains { $0.lowercased().contains("channel") })
        // The string keys have no list to walk, so the source is what is read.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/K3smStatus/AppPreferences.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.isEmpty)
        #expect(!text.lowercased().contains("channel"))
    }
}
