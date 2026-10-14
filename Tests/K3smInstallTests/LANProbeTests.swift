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

/// The record and applied markers, and the daemons probe as the checkbox's
/// freshest source.
@Suite("LAN record and probe")
struct LANProbeTests {
    static let now = LANToggleTests.now

    /// A status golden vendored for the decoder's tests.
    static func golden(_ name: String, file: StaticString = #filePath) throws -> StatusReport {
        let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: dir.appending(path: "K3smStatusTests/Fixtures/" + name))
        return try StatusReport.decode(data)
    }

    static func unreadableRecord(applied: LANApplied? = nil, appliedReadable: Bool? = nil) -> LANAccess {
        LANAccess(setting: .off, recorded: true, covers: LANReports.serverCovers, alwaysOn: LANReports.serverAlwaysOn,
                  applied: applied, recordState: .unreadable, appliedReadable: appliedReadable)
    }

    @Test("an unreadable record shows off with a note naming the lan command")
    func unreadableRecordShowsOff() {
        let t = LANToggleTests.evaluate(LANReports.make(Self.unreadableRecord()))
        #expect(t.value == .off && t.enabled && t.clickVerb == .lanOn)
        #expect(!t.showsIndicator)
        #expect(t.notes.count == 1)
        let note = t.notes.first ?? ""
        #expect(note.contains("could not be read"))
        #expect(note.contains("`sudo k3sm network lan on` or `off`"))
        #expect(!note.contains("no setting is recorded"))
    }

    @Test("an unknown record state disables the checkbox and drives nothing")
    func unknownRecordState() {
        let report = LANReports.make(LANAccess(setting: .off, recorded: true, recordState: .unknown))
        let t = LANToggleTests.evaluate(report)
        #expect(!t.enabled && t.value == .unknown && t.clickVerb == nil)
        #expect(t.disabledReason?.contains("does not know") == true)
        #expect(t.value != .off)
    }

    @Test("an applied state only an administrator can read is noted")
    func appliedUnreadableNote() {
        let t = LANToggleTests.evaluate(LANReports.make(LANAccess(
            setting: .off, recorded: true, covers: LANReports.serverCovers, alwaysOn: LANReports.serverAlwaysOn,
            appliedReadable: false)))
        #expect(t.value == .off && t.enabled)
        #expect(t.notes == ["What k3sm is serving can be read by an administrator only. Run `sudo k3sm network lan status` in Terminal to see it."])
    }

    @Test("a status with no network object still reads as on, no setting recorded")
    func absentStaysOn() throws {
        let probe = try Self.golden("status_daemons_json_network-absent.json")
        let t = LANToggleTests.evaluate(probe)
        #expect(t.value == .on && t.enabled && t.showsIndicator)
        #expect(t.notes.contains { $0.contains("no setting is recorded") })
    }

    @Test("the unreadable record golden shows off with the note, from the full report and from the probe", arguments: [
        "status_json_network-unreadable.json", "status_daemons_json_network-unreadable.json",
    ])
    func goldenUnreadable(_ file: String) throws {
        let t = LANToggleTests.evaluate(try Self.golden(file))
        #expect(t.value == .off && t.enabled && !t.showsIndicator)
        #expect(t.notes.contains { $0.contains("sudo k3sm network lan on") })
    }

    // MARK: the probe as the source

    static func read(_ network: LANAccess, ago: TimeInterval) -> LANSource.Read {
        (LANReports.make(network), now.addingTimeInterval(-ago))
    }

    @Test("the newer read drives the checkbox, whichever kind it is")
    func newerWins() {
        let full = Self.read(LANReports.access(.off), ago: 40)
        let probe = Self.read(LANReports.access(.on), ago: 5)
        #expect(LANSource.choose(full: full, probe: probe)?.report.network.setting == .on)
        let olderProbe = Self.read(LANReports.access(.on), ago: 90)
        #expect(LANSource.choose(full: full, probe: olderProbe)?.report.network.setting == .off)
        #expect(LANSource.choose(full: nil, probe: probe)?.report.network.setting == .on)
        #expect(LANSource.choose(full: full, probe: nil)?.report.network.setting == .off)
        #expect(LANSource.choose(full: nil, probe: nil) == nil)
    }

    @Test("a probe keeps the checkbox fresh past the full read's age limit")
    func probeRefreshes() {
        let full = Self.read(LANReports.access(.off), ago: LANToggle.maxAge + 30)
        let probe = Self.read(LANReports.access(.off), ago: 4)
        let source = LANSource.choose(full: full, probe: probe)
        let t = LANToggle.evaluate(report: source?.report, readAt: source?.at, now: Self.now, lastReadFailed: false,
                                   trustRefusal: nil, blocked: nil)
        #expect(t.enabled && t.value == .off)
        let alone = LANToggle.evaluate(report: full.report, readAt: full.at, now: Self.now, lastReadFailed: false,
                                       trustRefusal: nil, blocked: nil)
        #expect(!alone.enabled)
    }

    @Test("a change made in Terminal reaches the checkbox and the dot at the probe's rate")
    func changeFollowsProbe() {
        let full = Self.read(LANReports.access(.off), ago: 50)
        let probe = Self.read(LANReports.access(.on), ago: 5)
        let source = LANSource.choose(full: full, probe: probe)
        let t = LANToggle.evaluate(report: source?.report, readAt: source?.at, now: Self.now, lastReadFailed: false,
                                   trustRefusal: nil, blocked: nil)
        #expect(t.value == .on && t.showsIndicator)
    }

    @Test("the full read's applied state rides a newer probe only while they agree")
    func appliedRidesWhileAgreeing() {
        let applied = LANApplied(setting: .on, error: "ingress: bind :80 in use")
        let full = Self.read(LANReports.access(.off, applied: applied), ago: 30)
        let sameProbe = Self.read(LANReports.access(.off), ago: 5)
        #expect(LANSource.choose(full: full, probe: sameProbe)?.report.network.applied == applied)
        let changed = Self.read(LANReports.access(.on), ago: 5)
        #expect(LANSource.choose(full: full, probe: changed)?.report.network.applied == nil)
        let unreadable = Self.read(Self.unreadableRecord(), ago: 5)
        #expect(LANSource.choose(full: full, probe: unreadable)?.report.network.applied == nil)
        let fullHidden = Self.read(Self.unreadableRecord(appliedReadable: false), ago: 30)
        #expect(LANSource.choose(full: fullHidden, probe: unreadable)?.report.network.appliedReadable == false)
    }

    @Test("an unknown record state in the live status refuses before the prompt")
    func unknownRecordRefuses() {
        let live = LANReports.make(LANAccess(setting: .off, recorded: true, recordState: .unknown))
        guard case .refused(let why) = LANPrecondition.check(.lanOn, expected: .off, live: live) else {
            Issue.record("not refused")
            return
        }
        #expect(why.contains("does not know"))
        #expect(LANPrecondition.check(.lanOn, expected: .off, live: LANReports.make(Self.unreadableRecord())) == .proceed)
    }
}
