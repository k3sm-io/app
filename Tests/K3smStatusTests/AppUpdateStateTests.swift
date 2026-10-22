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

@testable import K3smStatus

@Suite("the app's own update check")
struct AppUpdateStateTests {
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 2026-10-01T12:00:00Z.
    static let t0 = Date(timeIntervalSince1970: 1_790_856_000)

    static func pair(_ tag: String, _ issued: Date = t0) -> AppIndexHighWater {
        AppIndexHighWater(tag: tag, issuedAt: issued)!
    }

    static func facts(_ tag: String, issued: Date = t0, signed: Date = t0,
                      macOS: ReleaseIndex.MacOSSupport = .supported) -> AppUpdateCheckOutcome {
        .accepted(AppIndexFacts(tag: tag, issuedAt: issued, signedAt: signed, macOS: macOS))
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let ownTag: String?
        var pinned = true
        var checksOn = true
        let outcome: AppUpdateCheckOutcome?
        var stored: AppIndexHighWater?
        var transfer: AppUpdateTransfer?
        let want: AppUpdateState
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        // The plan's table, with the index's `tag` compared to K3smPayloadTag.
        Row(name: "up to date", ownTag: "v0.2.0", outcome: facts("v0.2.0"), want: .upToDate(tag: "v0.2.0")),
        Row(name: "update available", ownTag: "v0.2.0", outcome: facts("v0.2.1"), want: .available(tag: "v0.2.1")),
        Row(name: "downloading", ownTag: "v0.2.0", outcome: facts("v0.2.1"), transfer: .downloading, want: .downloading),
        Row(name: "verifying", ownTag: "v0.2.0", outcome: facts("v0.2.1"), transfer: .verifying, want: .verifying),
        Row(name: "a transfer never shows without an offer", ownTag: "v0.2.1", outcome: facts("v0.2.1"),
            transfer: .downloading, want: .upToDate(tag: "v0.2.1")),
        Row(name: "this build is newer", ownTag: "v0.3.0", outcome: facts("v0.2.1"),
            want: .buildIsNewer(own: "v0.3.0", latest: "v0.2.1")),
        Row(name: "development: no pin", ownTag: "v0.2.0", pinned: false, outcome: facts("v0.2.1"), want: .development),
        Row(name: "development: no tag", ownTag: nil, outcome: facts("v0.2.1"), want: .development),
        Row(name: "development: 0.0.0", ownTag: "v0.0.0", outcome: nil, want: .development),
        Row(name: "development: a tag outside the grammar", ownTag: "v0.2.0+meta", outcome: nil, want: .development),
        Row(name: "could not check", ownTag: "v0.2.0", outcome: .failed("the server answered 404"),
            want: .couldNotCheck(reason: "the server answered 404")),
        Row(name: "checks off, nothing asked", ownTag: "v0.2.0", checksOn: false, outcome: nil, want: .checksOff),
        Row(name: "checks on, not checked yet", ownTag: "v0.2.0", outcome: nil, want: .notCheckedYet),
        // Release candidates, both directions.
        Row(name: "an rc below the final is offered the final", ownTag: "v0.2.0-rc.1", outcome: facts("v0.2.0"),
            want: .available(tag: "v0.2.0")),
        Row(name: "an rc above the latest final is newer", ownTag: "v0.3.0-rc.1", outcome: facts("v0.2.1"),
            want: .buildIsNewer(own: "v0.3.0-rc.1", latest: "v0.2.1")),
        // The effective floor: max(stored, own).
        Row(name: "a stored mark above the running tag: the same index still offers", ownTag: "v0.2.0",
            outcome: facts("v0.3.0"), stored: pair("v0.3.0"), want: .available(tag: "v0.3.0")),
        Row(name: "a replayed lower tag below the stored mark is never an offer", ownTag: "v0.2.0",
            outcome: facts("v0.2.5"), stored: pair("v0.3.0"),
            want: .couldNotCheck(reason: "the index is older than one already seen")),
        Row(name: "the same tag with an older issuedAt than the stored mark", ownTag: "v0.2.0",
            outcome: facts("v0.3.0", issued: t0.addingTimeInterval(-1)), stored: pair("v0.3.0"),
            want: .couldNotCheck(reason: "the index is older than one already seen")),
        Row(name: "an index below the running tag is newer-build, not a downgrade", ownTag: "v0.4.0",
            outcome: facts("v0.3.0"), stored: pair("v0.3.0"), want: .buildIsNewer(own: "v0.4.0", latest: "v0.3.0")),
        // macOS.
        Row(name: "requires a newer macOS", ownTag: "v0.2.0", outcome: facts("v0.3.0", macOS: .requiresNewer("27")),
            want: .requiresNewerMacOS("27")),
        Row(name: "a macOS floor on the same release is not shown", ownTag: "v0.3.0",
            outcome: facts("v0.3.0", macOS: .requiresNewer("27")), want: .upToDate(tag: "v0.3.0")),
    ]

    /// The named gate: every row of the plan's state table and the floor's
    /// edges, through `AppUpdateState.decide` and `AppUpdateAcceptance`.
    @Test("the app update state table", arguments: rows)
    func appUpdateStateTable(_ row: Row) {
        let got = AppUpdateState.decide(ownTag: row.ownTag, pinned: row.pinned, checksOn: row.checksOn,
                                        outcome: row.outcome, stored: row.stored, transfer: row.transfer)
        #expect(got == row.want, "\(row.name)")
        #expect(got.isOffer == (row.want.isOffer))
        // Every failure is could-not-check, never an offer.
        if case .failed = row.outcome { #expect(!got.isOffer) }
    }

    @Test("acceptance: the issuedAt bound uses the attested signing time, then the monotonic floor")
    func acceptance() {
        let t0 = Self.t0
        let skew = AppUpdateAcceptance.maxIssuedAfterSigning
        #expect(skew == 600)
        // issuedAt exactly at signedAt + skew is accepted; one second past is refused.
        #expect(AppUpdateAcceptance.accept(tag: "v0.2.0", issuedAt: t0.addingTimeInterval(skew), signedAt: t0, stored: nil)
            == .accepted(Self.pair("v0.2.0", t0.addingTimeInterval(skew))))
        #expect(AppUpdateAcceptance.accept(tag: "v0.2.0", issuedAt: t0.addingTimeInterval(skew + 1), signedAt: t0, stored: nil)
            == .refused(.issuedAfterSigning(seconds: 601)))
        // An index dated far before its signature is fine (re-signed later).
        #expect(AppUpdateAcceptance.accept(tag: "v0.2.0", issuedAt: t0.addingTimeInterval(-86_400 * 30), signedAt: t0, stored: nil)
            == .accepted(Self.pair("v0.2.0", t0.addingTimeInterval(-86_400 * 30))))
        // The bound is checked before the floor.
        #expect(AppUpdateAcceptance.accept(tag: "v0.1.0", issuedAt: .distantFuture, signedAt: t0, stored: Self.pair("v0.3.0"))
            .isRefusedForSkew)

        let stored = Self.pair("v0.3.0")
        // A lower tag is refused, whatever its issuedAt.
        #expect(AppUpdateAcceptance.accept(tag: "v0.2.9", issuedAt: t0.addingTimeInterval(500), signedAt: t0.addingTimeInterval(500), stored: stored)
            == .refused(.olderRelease(accepted: "v0.3.0")))
        // The same tag with an older issuedAt is refused.
        #expect(AppUpdateAcceptance.accept(tag: "v0.3.0", issuedAt: t0.addingTimeInterval(-1), signedAt: t0, stored: stored)
            == .refused(.olderIndex))
        // The same pair is accepted and leaves the mark as it is (a re-fetch).
        #expect(AppUpdateAcceptance.accept(tag: "v0.3.0", issuedAt: t0, signedAt: t0, stored: stored) == .accepted(stored))
        // The same tag, re-issued later, raises the mark.
        #expect(AppUpdateAcceptance.accept(tag: "v0.3.0", issuedAt: t0.addingTimeInterval(60), signedAt: t0.addingTimeInterval(60), stored: stored)
            == .accepted(Self.pair("v0.3.0", t0.addingTimeInterval(60))))
        // A higher tag with an older issuedAt is still higher: the pair is lexicographic.
        #expect(AppUpdateAcceptance.accept(tag: "v0.3.1", issuedAt: t0.addingTimeInterval(-60), signedAt: t0, stored: stored)
            == .accepted(Self.pair("v0.3.1", t0.addingTimeInterval(-60))))
        // Semver, not text: v0.10.0 is above v0.9.0.
        #expect(AppUpdateAcceptance.accept(tag: "v0.10.0", issuedAt: t0, signedAt: t0, stored: Self.pair("v0.9.0"))
            == .accepted(Self.pair("v0.10.0")))
        // A tag that is not a final release is refused.
        #expect(AppUpdateAcceptance.accept(tag: "v0.3.1-rc.1", issuedAt: t0, signedAt: t0, stored: nil) == .refused(.tag))
    }

    @Test("the high-water pair and the check's time are records that survive Reset to Defaults; a garbage pair reads as absent")
    func highWaterRecords() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.checkAppUpdates == true)
        #expect(prefs.downloadAppUpdates == true)
        #expect(prefs.appIndexHighWater == .absent)
        #expect(prefs.appUpdateLastCheck == nil)

        prefs.storeHighWater(Self.pair("v0.3.0"))
        prefs.appUpdateLastCheck = Self.t0
        prefs.appUpdateNotifiedRelease = "0.3.0"
        prefs.checkAppUpdates = false
        prefs.downloadAppUpdates = false
        #expect(prefs.appIndexHighWater == .stored(Self.pair("v0.3.0")))

        prefs.reset()
        #expect(prefs.checkAppUpdates == true)
        #expect(prefs.downloadAppUpdates == true)
        #expect(prefs.appIndexHighWater == .stored(Self.pair("v0.3.0")))
        #expect(prefs.appUpdateLastCheck == Self.t0)
        #expect(prefs.appUpdateNotifiedRelease == "0.3.0")

        // Only the pair: the two keys hold a string and a date, nothing else.
        let keys = Set(defaults.dictionaryRepresentation().keys).filter { $0.hasPrefix("appIndex") }
        #expect(keys == [AppPreferences.appIndexHighWaterTagKey, AppPreferences.appIndexHighWaterIssuedAtKey])

        // Garbage of every kind reads as garbage, and its pair is nil.
        let garbage: [(Any?, Any?)] = [
            ("v0.3.0", nil), (nil, Self.t0), ("v0.3.0", "2026-10-01T12:00:00Z"), (3, Self.t0),
            ("v0.3.0-rc.1", Self.t0), ("0.3.0", Self.t0), ("v0.3", Self.t0), ("v00.3.0", Self.t0),
            ("v0.3.0", Date(timeIntervalSince1970: .nan)),
        ]
        for (tag, issued) in garbage {
            let d = Self.fresh()
            if let tag { d.set(tag, forKey: AppPreferences.appIndexHighWaterTagKey) }
            if let issued { d.set(issued, forKey: AppPreferences.appIndexHighWaterIssuedAtKey) }
            let p = AppPreferences(defaults: d)
            #expect(p.appIndexHighWater == .garbage, "\(String(describing: tag)) \(String(describing: issued))")
            #expect(p.appIndexHighWater.pair == nil)
        }
        // A garbage pair is treated as absent: the running tag stays the floor.
        #expect(AppUpdateState.decide(ownTag: "v0.2.0", pinned: true, checksOn: true, outcome: Self.facts("v0.2.0"),
                                      stored: StoredHighWater.garbage.pair) == .upToDate(tag: "v0.2.0"))
        #expect(AppUpdateState.decide(ownTag: "v0.2.0", pinned: true, checksOn: true, outcome: Self.facts("v0.1.0"),
                                      stored: StoredHighWater.garbage.pair) == .buildIsNewer(own: "v0.2.0", latest: "v0.1.0"))
    }

    @Test("the fixed URL, and issuedAt read as a UTC date")
    func indexURLAndIssuedDate() throws {
        let url = try #require(URL(string: ReleaseIndex.latestIndexURL))
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.query == nil)
        #expect(ReleaseIndex.allowedHosts.contains(url.host!))
        #expect(url.path == "/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m")

        let index = try Self.index(issuedAt: "2026-10-01T12:00:00Z")
        #expect(index.issuedDate == Self.t0)
        let iso = ISO8601DateFormatter()
        for text in ["1970-01-01T00:00:00Z", "2000-02-29T23:59:59Z", "2024-12-31T00:00:01Z", "2100-03-01T06:07:08Z",
                     "9999-12-31T23:59:59Z"] {
            #expect(try Self.index(issuedAt: text).issuedDate == iso.date(from: text), "\(text)")
        }
        // Proleptic Gregorian, as Go's time package counts (Foundation's
        // formatter switches to the Julian calendar before 1582):
        // time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC).Unix() == -62135596800.
        #expect(try Self.index(issuedAt: "0001-01-01T00:00:00Z").issuedDate.timeIntervalSince1970 == -62_135_596_800)
        #expect(try Self.index(issuedAt: "0000-03-01T00:00:00Z").issuedDate.timeIntervalSince1970 == -62_162_035_200)
        // Text outside the grammar never reaches here from parse; it reads as the distant future.
        #expect(try Self.index(issuedAt: "2026-02-30T00:00:00Z").issuedDate == .distantFuture)
    }

    /// An index value with `issuedAt`, built directly (never parsed).
    static func index(issuedAt: String) throws -> ReleaseIndex {
        let version = try #require(SemanticVersion("0.2.0"))
        let image = ReleaseIndex.Image(name: "", url: "", sha256: "", size: 1)
        return ReleaseIndex(schema: ReleaseIndex.schema, context: ReleaseIndex.context, issuedAt: issuedAt, tag: "v0.2.0",
                            version: version, minimumMacOS: "26",
                            app: ReleaseIndex.App(bundleID: ReleaseIndex.bundleID, shortVersion: "0.2.0", image: image),
                            k3sm: ReleaseIndex.K3sm(archive: "", archiveSHA256: "", payloadManifestSHA256: ""))
    }

    @Test("the lines each state shows")
    func lines() {
        #expect(AppUpdateState.upToDate(tag: "v0.2.0").line == "k3sm.app 0.2.0 is the latest release.")
        #expect(AppUpdateState.available(tag: "v0.2.1").line == "k3sm.app 0.2.1 is available.")
        #expect(AppUpdateState.buildIsNewer(own: "v0.3.0-rc.1", latest: "v0.2.1").line
            == "This build (0.3.0-rc.1) is newer than the latest release (0.2.1).")
        #expect(AppUpdateState.development.line == "Development build: updates are not checked.")
        #expect(AppUpdateState.requiresNewerMacOS("27").line == "The latest k3sm.app needs macOS 27 or later.")
        #expect(AppUpdateState.couldNotCheck(reason: "a\u{202E}b\nc").line == "Could not check for updates: ab c")
        #expect(AppUpdateState.checksOff.line == "Automatic update checks are off.")

        #expect(AppUpdateAge.line(lastCheck: nil, now: Self.t0) == "Last checked: never.")
        #expect(AppUpdateAge.line(lastCheck: Self.t0, now: Self.t0.addingTimeInterval(30)) == "Last checked: just now.")
        #expect(AppUpdateAge.line(lastCheck: Self.t0, now: Self.t0.addingTimeInterval(-300)) == "Last checked: just now.")
        #expect(AppUpdateAge.line(lastCheck: Self.t0, now: Self.t0.addingTimeInterval(60)) == "Last checked: 1 minute ago.")
        #expect(AppUpdateAge.line(lastCheck: Self.t0, now: Self.t0.addingTimeInterval(3 * 3600 + 5)) == "Last checked: 3 hours ago.")
        #expect(AppUpdateAge.line(lastCheck: Self.t0, now: Self.t0.addingTimeInterval(2 * 86_400)) == "Last checked: 2 days ago.")
    }

    @Test("app ahead of cluster: the sealed payload tag against the server's release")
    func appAheadOfCluster() {
        #expect(AppAheadOfCluster.decide(appTag: "v0.3.0", clusterTag: "v0.2.1")
            == AppAheadOfCluster(app: "v0.3.0", cluster: "v0.2.1"))
        #expect(AppAheadOfCluster.decide(appTag: "v0.3.0", clusterTag: "v0.2.1")?.line
            == "This app carries 0.3.0, newer than the cluster's 0.2.1.")
        #expect(AppAheadOfCluster.decide(appTag: "v0.2.1", clusterTag: "v0.2.1") == nil)
        #expect(AppAheadOfCluster.decide(appTag: "v0.2.0", clusterTag: "v0.2.1") == nil)
        #expect(AppAheadOfCluster.decide(appTag: "v0.3.0-rc.1", clusterTag: "v0.2.1") != nil)
        #expect(AppAheadOfCluster.decide(appTag: nil, clusterTag: "v0.2.1") == nil)
        #expect(AppAheadOfCluster.decide(appTag: "v0.3.0", clusterTag: nil) == nil)
        #expect(AppAheadOfCluster.decide(appTag: "v0.3.0", clusterTag: "v0.2.1-dirty") == nil)

        var server = UpdatePlanFacts(role: .server, installed: nil, payload: nil, payloadTag: "v0.3.0", installedTag: "v0.2.1")
        #expect(AppAheadOfCluster.decide(facts: server)?.cluster == "v0.2.1")
        server.installedTag = "v0.3.0"
        #expect(AppAheadOfCluster.decide(facts: server) == nil)
        let worker = UpdatePlanFacts(role: .agent, installed: nil, payload: nil, controlPlane: SemanticVersion("0.2.0"),
                                     payloadTag: "v0.3.0")
        #expect(AppAheadOfCluster.decide(facts: worker)?.cluster == "v0.2.0")
        #expect(AppAheadOfCluster.decide(facts: UpdatePlanFacts(role: nil, installed: nil, payload: nil, payloadTag: "v0.3.0")) == nil)
    }

    @Test("the app-release notice: once per release, only for an offer, only with the preference on")
    func appNotice() {
        let notice = AppUpdateNotice.decide(state: .available(tag: "v0.3.0"), enabled: true, notified: nil)
        #expect(notice?.release == "0.3.0")
        #expect(notice?.title == "k3sm.app 0.3.0 is available")
        #expect(AppUpdateNotice.decide(state: .available(tag: "v0.3.0"), enabled: true, notified: "0.3.0") == nil)
        #expect(AppUpdateNotice.decide(state: .available(tag: "v0.3.0"), enabled: true, notified: "v0.3.0") == nil)
        #expect(AppUpdateNotice.decide(state: .available(tag: "v0.3.1"), enabled: true, notified: "0.3.0") != nil)
        #expect(AppUpdateNotice.decide(state: .available(tag: "v0.3.0"), enabled: false, notified: nil) == nil)
        for state: AppUpdateState in [.upToDate(tag: "v0.3.0"), .couldNotCheck(reason: "x"), .development, .checksOff,
                                      .requiresNewerMacOS("27"), .buildIsNewer(own: "v0.4.0", latest: "v0.3.0")] {
            #expect(AppUpdateNotice.decide(state: state, enabled: true, notified: nil) == nil)
        }
        #expect(AppUpdateNotice.identifier != "io.k3sm.app.update-available")
    }

    @Test("the schedule: 60 s after launch, a day spread by jitter, two under Low power, held back in the first run or a root step")
    func schedule() {
        #expect(AppUpdateSchedule.firstDelay == .seconds(60))
        #expect(AppUpdateSchedule.turn(checksOn: true, firstRun: false, rootStepRunning: false) == .check)
        #expect(AppUpdateSchedule.turn(checksOn: true, firstRun: true, rootStepRunning: false) == .holdBack)
        #expect(AppUpdateSchedule.turn(checksOn: true, firstRun: false, rootStepRunning: true) == .holdBack)
        #expect(AppUpdateSchedule.turn(checksOn: false, firstRun: false, rootStepRunning: false) == .off)
        #expect(AppUpdateSchedule.turn(checksOn: false, firstRun: true, rootStepRunning: true) == .off)
        let normal = PollProfile.normal.intervals, low = PollProfile.lowPower.intervals
        #expect(AppUpdateSchedule.nextWait(after: .check, intervals: normal, unit: 0) == .seconds(86_400))
        #expect(AppUpdateSchedule.nextWait(after: .check, intervals: normal, unit: 1) == .seconds(86_400) * 1.2)
        #expect(AppUpdateSchedule.nextWait(after: .off, intervals: low, unit: 0) == .seconds(172_800))
        #expect(AppUpdateSchedule.nextWait(after: .holdBack, intervals: low, unit: 1) == .seconds(60))
    }
}

extension AppUpdateAcceptance.Verdict {
    var isRefusedForSkew: Bool {
        if case .refused(.issuedAfterSigning) = self { return true }
        return false
    }
}
