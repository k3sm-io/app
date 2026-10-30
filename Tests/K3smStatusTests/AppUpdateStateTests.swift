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

private func own(_ tag: String?, pinned: Bool = true) -> AppUpdateOwn {
    AppUpdateOwn(tag: tag, pinned: pinned)
}

private func latest(_ tag: String, issuedAt: String = "2026-11-02T18:04:11Z", minimumMacOS: String = "26.0") -> AppUpdateLatest {
    AppUpdateLatest(tag: tag, issuedAt: issuedAt, minimumMacOS: minimumMacOS)!
}

@Suite("the app's own update check")
struct AppUpdateStateTests {
    static let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let own: AppUpdateOwn
        let result: AppUpdateResult?
        let download: AppUpdateDownload
        let state: AppUpdateState
        let line: String
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "no Team ID pin is a development build", own: own("v0.2.0", pinned: false),
            result: .verified(latest("v0.2.1")), download: .idle,
            state: .development, line: "Development build: updates are not checked."),
        Row(name: "no payload release is a development build", own: own(nil),
            result: nil, download: .idle,
            state: .development, line: "Development build: updates are not checked."),
        Row(name: "never checked", own: own("v0.2.0"), result: nil, download: .idle,
            state: .notChecked, line: "k3sm.app has not checked for updates yet."),
        Row(name: "the index names this release", own: own("v0.2.0"), result: .verified(latest("v0.2.0")), download: .idle,
            state: .upToDate("0.2.0"), line: "k3sm.app 0.2.0 is the latest release."),
        Row(name: "the index names a newer release", own: own("v0.2.0"), result: .verified(latest("v0.2.1")), download: .idle,
            state: .available("0.2.1", .idle), line: "k3sm.app 0.2.1 is available."),
        Row(name: "a newer release downloading", own: own("v0.2.0"), result: .verified(latest("v0.2.1")), download: .inFlight,
            state: .available("0.2.1", .inFlight), line: "Downloading and verifying k3sm.app 0.2.1."),
        Row(name: "a newer release verified", own: own("v0.2.0"), result: .verified(latest("v0.2.1")), download: .verified,
            state: .available("0.2.1", .verified), line: "k3sm.app 0.2.1 is ready: restart to update."),
        Row(name: "a newer release this macOS cannot run", own: own("v0.2.0"),
            result: .verified(latest("v0.2.1", minimumMacOS: "27.1")), download: .idle,
            state: .requiresNewerMacOS("0.2.1", minimum: "27.1"),
            line: "k3sm.app 0.2.1 needs macOS 27.1 or later; nothing was downloaded."),
        Row(name: "a release candidate is newer than the final before it", own: own("v0.3.0-rc.1"),
            result: .verified(latest("v0.2.1")), download: .idle,
            state: .buildNewer(own: "0.3.0-rc.1", latest: "0.2.1"),
            line: "This build (0.3.0-rc.1) is newer than the latest release (0.2.1)."),
        Row(name: "a release candidate is older than its final", own: own("v0.3.0-rc.1"),
            result: .verified(latest("v0.3.0")), download: .idle,
            state: .available("0.3.0", .idle), line: "k3sm.app 0.3.0 is available."),
        Row(name: "a failed check is never an offer", own: own("v0.2.0"),
            result: .failed("the signing certificate is not the pinned team's"), download: .idle,
            state: .couldNotCheck("the signing certificate is not the pinned team's"),
            line: "Could not check for updates: the signing certificate is not the pinned team's."),
        Row(name: "a failure reason is cleaned for the screen", own: own("v0.2.0"),
            result: .failed("bad\u{1B}[31m\nreason"), download: .verified,
            state: .couldNotCheck(StatusDisplay.errorText("bad\u{1B}[31m\nreason")),
            line: "Could not check for updates: " + StatusDisplay.errorText("bad\u{1B}[31m\nreason") + "."),
    ]

    /// The named gate: every state of the app's own release line, from what
    /// the app is, the last check's result and the download.
    @Test("appUpdateStateTable", arguments: rows)
    func appUpdateStateTable(_ row: Row) {
        let state = AppUpdateState.decide(own: row.own, result: row.result, download: row.download, macOS: Self.macOS26)
        #expect(state == row.state)
        #expect(state.line == row.line)
        #expect(state.isOffer == ({ if case .available = row.state { true } else { false } })())
    }

    @Test("the floor is the high-water mark or the running bundle's tag, whichever is higher")
    func floor() {
        let none = AppUpdateRecord()
        #expect(AppUpdateRecord.accept(latest("v0.2.1"), signedAt: Self.date("2026-11-02T18:05:00Z"), record: none)
            == .accepted(AppUpdateRecord(highTag: "v0.2.1", highIssuedAt: "2026-11-02T18:04:11Z")))
        let high = AppUpdateRecord(highTag: "v0.2.1", highIssuedAt: "2026-11-02T18:04:11Z")
        // A replayed older release is refused.
        #expect(AppUpdateRecord.accept(latest("v0.2.0"), signedAt: Self.date("2026-11-02T18:05:00Z"), record: high)
            == .refused(AppUpdateRecord.olderThanSeen))
        // The same release with an older issue time is refused; the same one again is accepted.
        #expect(AppUpdateRecord.accept(latest("v0.2.1", issuedAt: "2026-11-01T00:00:00Z"), signedAt: Self.date("2026-11-02T18:05:00Z"),
                                       record: high) == .refused(AppUpdateRecord.olderThanSeen))
        #expect(AppUpdateRecord.accept(latest("v0.2.1"), signedAt: Self.date("2026-11-02T18:05:00Z"), record: high)
            == .accepted(high))
        // Resetting the preferences cannot lower the floor below the running
        // bundle: an old index is taken but reads as this build being newer.
        #expect(AppUpdateRecord.accept(latest("v0.1.9"), signedAt: Self.date("2026-11-02T18:05:00Z"), record: none)
            == .accepted(AppUpdateRecord(highTag: "v0.1.9", highIssuedAt: "2026-11-02T18:04:11Z")))
        let replayed = AppUpdateState.decide(own: own("v0.2.0"), result: .verified(latest("v0.1.9")), download: .idle, macOS: Self.macOS26)
        #expect(replayed == .buildNewer(own: "0.2.0", latest: "0.1.9") && !replayed.isOffer)
        // An index issued well after its timestamp is refused.
        #expect(AppUpdateRecord.accept(latest("v0.2.1", issuedAt: "2026-11-03T18:04:11Z"), signedAt: Self.date("2026-11-02T18:05:00Z"),
                                       record: none) == .refused(AppUpdateRecord.issuedAfterSigning))
    }

    @Test("the age of the last successful check")
    func lastCheckAge() {
        let now = Self.date("2026-11-02T18:00:00Z")
        #expect(AppUpdateState.lastCheckLine(nil, now: now) == "Last successful check: never")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(-30), now: now) == "Last successful check: just now")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(-60), now: now) == "Last successful check: 1 minute ago")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(-59 * 60), now: now) == "Last successful check: 59 minutes ago")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(-2 * 3600), now: now) == "Last successful check: 2 hours ago")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(-3 * 86400), now: now) == "Last successful check: 3 days ago")
        #expect(AppUpdateState.lastCheckLine(now.addingTimeInterval(60), now: now) == "Last successful check: just now")
    }

    @Test("the app ahead of the cluster is a standing line")
    func aheadOfCluster() {
        #expect(AppUpdateState.aheadOfCluster(own: own("v0.3.0"), cluster: SemanticVersion("0.2.1"))
            == "This app carries k3sm 0.3.0; this Mac's k3sm runs 0.2.1.")
        #expect(AppUpdateState.aheadOfCluster(own: own("v0.3.0"), cluster: SemanticVersion("0.3.0")) == nil)
        #expect(AppUpdateState.aheadOfCluster(own: own("v0.3.0"), cluster: SemanticVersion("0.4.0")) == nil)
        #expect(AppUpdateState.aheadOfCluster(own: own("v0.3.0"), cluster: nil) == nil)
        #expect(AppUpdateState.aheadOfCluster(own: own(nil), cluster: SemanticVersion("0.2.1")) == nil)
    }

    @Test("the cadence: a minute after launch, then a day spread by jitter, doubled under Low power")
    func cadence() {
        #expect(AppUpdateSchedule.firstDelay == .seconds(60))
        #expect(AppUpdateSchedule.wait(profile: .normal, unit: 0) == .seconds(86_400))
        #expect(AppUpdateSchedule.wait(profile: .normal, unit: 1) == PollJitter.spread(.seconds(86_400), unit: 1))
        #expect(AppUpdateSchedule.wait(profile: .lowPower, unit: 0) == .seconds(2 * 86_400))
    }

    @Test("checks off sends nothing unless the user asks; a development build never asks")
    func checksOffSendsNothing() {
        let release = own("v0.2.0")
        #expect(!AppUpdateSchedule.mayRequest(.automatic, checksOn: false, own: release, firstRun: false))
        #expect(AppUpdateSchedule.mayRequest(.user, checksOn: false, own: release, firstRun: false))
        #expect(AppUpdateSchedule.mayRequest(.automatic, checksOn: true, own: release, firstRun: false))
        #expect(!AppUpdateSchedule.mayRequest(.automatic, checksOn: true, own: release, firstRun: true))
        #expect(!AppUpdateSchedule.mayRequest(.user, checksOn: true, own: own("v0.2.0", pinned: false), firstRun: false))
        #expect(!AppUpdateSchedule.mayRequest(.automatic, checksOn: true, own: own(nil), firstRun: false))
    }

    @Test("an app update never starts a roll: the follow-ups are notify and download only")
    func appUpdateNeverStartsARoll() {
        let available = AppUpdateState.available("0.2.1", .idle)
        #expect(AppUpdateFollowUp.decide(available, downloadOn: true, notifyOn: true, notified: nil) == [.notify("0.2.1"), .download("0.2.1")])
        #expect(AppUpdateFollowUp.decide(available, downloadOn: false, notifyOn: true, notified: "0.2.1") == [])
        #expect(AppUpdateFollowUp.decide(available, downloadOn: false, notifyOn: false, notified: nil) == [])
        for state in [AppUpdateState.development, .notChecked, .upToDate("0.2.0"), .buildNewer(own: "0.3.0-rc.1", latest: "0.2.1"),
                      .couldNotCheck("x"), .requiresNewerMacOS("0.2.1", minimum: "27.1"), .available("0.2.1", .verified)] {
            for followUp in AppUpdateFollowUp.decide(state, downloadOn: true, notifyOn: true, notified: nil) {
                switch followUp {
                case .notify, .download: break
                }
            }
        }
        #expect(AppUpdateFollowUp.decide(.available("0.2.1", .verified), downloadOn: true, notifyOn: false, notified: nil) == [])
    }

    @Test("the request: a fixed https GET with a versionless user agent and no query")
    func requestGolden() throws {
        let url = try #require(URL(string: AppUpdateRequest.url))
        #expect(AppUpdateRequest.url == "https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m")
        #expect(url.query == nil && url.fragment == nil && url.user == nil && url.port == nil)
        #expect(AppUpdateRequest.method == "GET")
        #expect(AppUpdateRequest.headers == ["User-Agent": "k3sm-app"])
        #expect(AppUpdateRequest.allowsHop(url))
        #expect(AppUpdateRequest.allowsHop(URL(string: "https://release-assets.githubusercontent.com/a/b?sig=x")!))
        #expect(!AppUpdateRequest.allowsHop(URL(string: "http://github.com/k3sm-io/k3sm")!))
        #expect(!AppUpdateRequest.allowsHop(URL(string: "https://example.com/k3sm_release-index.p7m")!))
        #expect(!AppUpdateRequest.allowsHop(URL(string: "https://github.com:8443/k3sm-io")!))
        #expect(!AppUpdateRequest.allowsHop(URL(string: "https://u:p@github.com/k3sm-io")!))
        #expect(!AppUpdateRequest.allowsHop(URL(string: "https://github.com.example.com/k3sm-io")!))
    }

    @Test("an app release is announced once")
    func notice() {
        let available = AppUpdateState.available("0.2.1", .idle)
        let notice = AppUpdateNotice.decide(available, enabled: true, notified: nil)
        #expect(notice?.release == "0.2.1")
        #expect(notice?.title == "k3sm.app 0.2.1 is available")
        #expect(AppUpdateNotice.decide(available, enabled: true, notified: "0.2.1") == nil)
        #expect(AppUpdateNotice.decide(available, enabled: false, notified: nil) == nil)
        #expect(AppUpdateNotice.decide(.upToDate("0.2.1"), enabled: true, notified: nil) == nil)
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
