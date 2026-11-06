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

import CryptoKit
import Foundation
import Testing

@testable import K3smStatus

/// The vendored copy of k3sm's pkg/update/testdata/release-index-rc, byte for
/// byte, with a SHA256SUMS manifest. hack/ci.sh compares the directory with k3sm's.
private func candidateDirectory() throws -> URL {
    guard let url = Bundle.module.url(forResource: "release-index-rc", withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureError.missing("release-index-rc")
    }
    return url
}

private func candidateFixture(_ name: String) throws -> Data {
    try Data(contentsOf: candidateDirectory().appendingPathComponent(name))
}

private func stableFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/release-index") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

/// The candidate document's decoder, the row's choice of document, its own floor
/// and what the app's line states.
@Suite("the candidate index")
struct CandidateIndexTests {
    static let requested = "v0.3.0-rc.2"
    static let kind = ReleaseIndexKind.candidate(tag: requested)
    static let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    static func latest(_ tag: String, issuedAt: String = "2026-11-05T12:30:45Z", minimumMacOS: String = "26.0") -> AppUpdateLatest {
        AppUpdateLatest(tag: tag, issuedAt: issuedAt, minimumMacOS: minimumMacOS)!
    }

    static func preferences() -> AppPreferences {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppPreferences(defaults: defaults)
    }

    static func report(latest: String?, state: String = "behind") -> StatusReport {
        let row = StatusRow(name: "update", state: state, detail: "d", wide: latest.map { ["latest": $0] } ?? [:])
        return StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: [row])
    }

    static func state(own: String, _ result: AppUpdateResult?, macOS: OperatingSystemVersion = macOS) -> AppUpdateState {
        AppUpdateState.decide(own: AppUpdateOwn(tag: own, pinned: true), result: result, download: .idle, macOS: macOS)
    }

    // MARK: the gate

    /// An app that accepted a candidate and left `rc` still takes the stable
    /// index below it: the two floors share neither a key nor a value, and a
    /// reset moves neither down.
    @Test func candidateIndexKeepsItsOwnFloor() throws {
        let prefs = Self.preferences()
        let stable = AppUpdateRecord(highTag: "v0.3.0", highIssuedAt: "2026-11-01T00:00:00Z")
        prefs.appUpdateRecord = stable

        // On rc: the row names a candidate above the stable mark.
        let onRC = Self.report(latest: "v0.3.1-rc.1")
        #expect(ReleaseIndexKind(report: onRC) == .candidate(tag: "v0.3.1-rc.1"))
        let accepted = AppUpdateCandidateRecord.accept(
            Self.latest("v0.3.1-rc.1"), signedAt: Self.signedAt, record: prefs.appUpdateCandidateRecord, stable: prefs.appUpdateRecord)
        let stored = AppUpdateCandidateRecord(highTag: "v0.3.1-rc.1", highIssuedAt: "2026-11-05T12:30:45Z")
        #expect(accepted == .accepted(stored))
        prefs.appUpdateCandidateRecord = stored
        #expect(prefs.appUpdateRecord == stable, "accepting a candidate moved the stable floor")
        #expect(prefs.appUpdateCandidateRecord == stored)

        // Off rc: the row names the final, so the stable document is asked for,
        // and the floor it meets is still the stable one.
        #expect(ReleaseIndexKind(report: Self.report(latest: "v0.3.0", state: "ahead")) == .stable)
        let back = Self.latest("v0.3.0", issuedAt: "2026-11-01T00:00:00Z")
        #expect(AppUpdateRecord.accept(back, signedAt: Self.signedAt, record: prefs.appUpdateRecord) == .accepted(stable))

        // The app still runs the candidate: above the final, never "could not
        // check", and never an offer of the lower release.
        let line = Self.state(own: "v0.3.1-rc.1", .verified(back))
        #expect(line == .buildNewer(own: "0.3.1-rc.1", latest: "0.3.0"))
        #expect(!line.isOffer)

        // Each floor is under its own keys, and a reset keeps them all.
        #expect(Set([AppPreferences.appUpdateHighTagKey, AppPreferences.appUpdateHighIssuedAtKey,
                     AppPreferences.appUpdateCandidateHighTagKey, AppPreferences.appUpdateCandidateHighIssuedAtKey]).count == 4)
        prefs.reset()
        #expect(prefs.appUpdateRecord == stable)
        #expect(prefs.appUpdateCandidateRecord == stored)

        // A stable index never rides the candidate floor, and the reverse: only
        // a candidate is taken as one.
        #expect(AppUpdateCandidateRecord.accept(back, signedAt: Self.signedAt, record: stored, stable: stable)
            == .refused(AppUpdateCandidateRecord.notACandidate))
    }

    // MARK: a steered listing

    /// A poisoned listing can name an older, genuinely signed candidate. Whatever
    /// the app has seen, one of the floors refuses it or it is no offer.
    @Test func aListingSteeredToAnOlderCandidateIsRefused() throws {
        let old = Self.latest("v0.3.0-rc.1")
        let none = AppUpdateRecord()

        // The candidate floor, by tag, and at one tag by issue time.
        let high = AppUpdateCandidateRecord(highTag: "v0.3.0-rc.3", highIssuedAt: "2026-11-05T12:30:45Z")
        #expect(AppUpdateCandidateRecord.accept(old, signedAt: Self.signedAt, record: high, stable: none)
            == .refused(AppUpdateRecord.olderThanSeen))
        #expect(AppUpdateCandidateRecord.accept(Self.latest("v0.3.0-rc.3", issuedAt: "2026-11-04T00:00:00Z"), signedAt: Self.signedAt,
                                                record: high, stable: none) == .refused(AppUpdateRecord.olderThanSeen))
        // Numbers rank as numbers: rc.10 is above rc.9.
        let nine = AppUpdateCandidateRecord(highTag: "v0.3.0-rc.9", highIssuedAt: "2026-11-05T12:30:45Z")
        #expect(AppUpdateCandidateRecord.accept(Self.latest("v0.3.0-rc.10"), signedAt: Self.signedAt, record: nine, stable: none)
            == .accepted(AppUpdateCandidateRecord(highTag: "v0.3.0-rc.10", highIssuedAt: "2026-11-05T12:30:45Z")))

        // The stable floor, only read: a candidate of a final this app has
        // accepted, on a Mac still running something older.
        let final = AppUpdateRecord(highTag: "v0.3.0", highIssuedAt: "2026-11-01T00:00:00Z")
        #expect(AppUpdateCandidateRecord.accept(old, signedAt: Self.signedAt, record: AppUpdateCandidateRecord(), stable: final)
            == .refused(AppUpdateRecord.olderThanSeen))

        // The running-bundle check, on a Mac with empty floors: accepted, and
        // states the build is newer, whether it runs a candidate or its final.
        #expect(AppUpdateCandidateRecord.accept(old, signedAt: Self.signedAt, record: AppUpdateCandidateRecord(), stable: none)
            == .accepted(AppUpdateCandidateRecord(highTag: "v0.3.0-rc.1", highIssuedAt: "2026-11-05T12:30:45Z")))
        for own in ["v0.3.0-rc.2", "v0.3.0"] {
            let line = Self.state(own: own, .verified(old))
            #expect(line == .buildNewer(own: String(own.dropFirst()), latest: "0.3.0-rc.1"))
            #expect(!line.isOffer)
        }

        // The signed document: one good for rc.1 is refused at rc.2's path.
        let rc1 = String(decoding: try candidateFixture("red-replayed-older-candidate.json"), as: UTF8.self)
        #expect(throws: ReleaseIndexError.requestedTag("v0.3.0-rc.1", Self.requested)) {
            try ReleaseIndex.parse(Data(rc1.utf8), expected: Self.kind)
        }
        #expect(try ReleaseIndex.parse(Data(rc1.utf8), expected: .candidate(tag: "v0.3.0-rc.1")).tag == "v0.3.0-rc.1")

        // A signature newer than the document's own date is fine; the reverse is not.
        #expect(AppUpdateCandidateRecord.accept(Self.latest("v0.3.0-rc.1", issuedAt: "2030-01-01T00:00:00Z"), signedAt: Self.signedAt,
                                                record: AppUpdateCandidateRecord(), stable: none)
            == .refused(AppUpdateRecord.issuedAfterSigning))
    }

    // MARK: no document

    @Test func aTagWithNoDocumentIsNoOfferNotAnError() {
        let line = Self.state(own: "v0.2.0", .noCandidateDocument(Self.requested))
        #expect(line == .noCandidateDocument("0.3.0-rc.2"))
        #expect(!line.isOffer)
        #expect(line.line == "Release candidate 0.3.0-rc.2 has no signed index for the app, so nothing is offered.")
        #expect(!line.line.contains("Could not"))
        #expect(AppUpdateResult.noCandidateDocument(Self.requested).isAnswer)
        #expect(!AppUpdateResult.failed("x").isAnswer)
        #expect(AppUpdateFollowUp.decide(line, downloadOn: true, notifyOn: true, notified: nil).isEmpty)

        // Only a candidate's 404 means this: a rate limit or an outage is a
        // failure, and the stable document always exists.
        #expect(Self.kind.hasNoDocument(status: 404))
        for status in [200, 403, 410, 429, 500, 503] { #expect(!Self.kind.hasNoDocument(status: status)) }
        #expect(!ReleaseIndexKind.stable.hasNoDocument(status: 404))
    }

    /// An accepted candidate is stated and not offered: nothing is notified or
    /// downloaded, since the app has no way to fetch one yet.
    @Test func aVerifiedCandidateIsStatedAndNotOffered() {
        let line = Self.state(own: "v0.2.0", .verified(Self.latest(Self.requested)))
        #expect(line == .candidateVerified("0.3.0-rc.2"))
        #expect(!line.isOffer)
        #expect(line.line == "k3sm.app 0.3.0-rc.2 is a verified release candidate; this app cannot download it yet.")
        #expect(AppUpdateFollowUp.decide(line, downloadOn: true, notifyOn: true, notified: nil).isEmpty)
        #expect(AppUpdateNotice.decide(line, enabled: true, notified: nil) == nil)
        #expect(Self.state(own: Self.requested, .verified(Self.latest(Self.requested))) == .upToDate("0.3.0-rc.2"))
        #expect(Self.state(own: "v0.2.0", .verified(Self.latest(Self.requested, minimumMacOS: "27.1")))
            == .requiresNewerMacOS("0.3.0-rc.2", minimum: "27.1"))
    }

    // MARK: the row picks the request

    @Test func theRowPicksTheRequest() {
        // Anything but a candidate tag takes today's stable request.
        #expect(ReleaseIndexKind(report: nil) == .stable)
        #expect(ReleaseIndexKind(report: Self.report(latest: nil)) == .stable)
        #expect(ReleaseIndexKind(report: Self.report(latest: "v0.3.0")) == .stable)
        #expect(ReleaseIndexKind(report: StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: [])) == .stable)
        for tag in ["v0.3.0-rc.01", "v0.3.0-rc.10000", "v0.3.0-rc", "v0.3.0-beta.1", "v0.3.0-rc.1+x", "0.3.0-rc.1", "v0.3-rc.1",
                    "v0.3.0-rc.1/../../x", "v0.3.0-rc.1?x=1", "v0.3.0-rc.1 ", "v0.3.0-rc.1\u{212A}"] {
            #expect(ReleaseIndexKind(report: Self.report(latest: tag)) == .stable, "\(tag)")
        }
        // A candidate on the row, in whatever state it reads.
        for state in ["behind", "ok", "ahead"] {
            #expect(ReleaseIndexKind(report: Self.report(latest: Self.requested, state: state)) == Self.kind)
        }
    }

    @Test func aCandidateIsRequestedByTagOnAPinnedHost() throws {
        #expect(AppUpdateRequest.url(for: .stable) == AppUpdateRequest.url)
        let url = try #require(AppUpdateRequest.url(for: Self.kind))
        #expect(url == "https://github.com/k3sm-io/k3sm/releases/download/v0.3.0-rc.2/k3sm_0.3.0-rc.2_release-index.p7m")
        #expect(AppUpdateRequest.allowsHop(try #require(URL(string: url))))
        // The grammar stands between a tag and a URL, whoever built the kind.
        for tag in ["", "latest", "v0.3.0", "v0.3.0-rc.1/../../x", "v0.3.0-rc.1?x=1", "v0.3.0-rc.1#x"] {
            #expect(AppUpdateRequest.url(for: .candidate(tag: tag)) == nil, "\(tag)")
        }
    }

    // MARK: the decoder against k3sm's corpus

    /// The reason k3sm's corpus names for each vendored red file
    /// (candidateIndexReds in pkg/update/candidateindex_test.go), every one read
    /// at `requested`. Its keys must be exactly the vendored red files.
    static let redReasons: [String: String] = [
        "red-stable-document.json": "schema is not k3sm-release-index-rc/v1",
        "red-stable-schema.json": "schema is not k3sm-release-index-rc/v1",
        "red-stable-context.json": "context is not io.k3sm.release-index-rc/v1",
        "red-schema-v2.json": "schema is not",
        "red-other-context.json": "context is not",
        "red-no-context.json": "context is not",
        "red-replayed-older-candidate.json": "tag v0.3.0-rc.1 is not the requested v0.3.0-rc.2",
        "red-replayed-newer-candidate.json": "tag v0.3.0-rc.3 is not the requested v0.3.0-rc.2",
        "red-final-tag.json": "not a release candidate tag",
        "red-rc-leading-zero.json": "not a release candidate tag",
        "red-rc-five-digits.json": "not a release candidate tag",
        "red-rc-no-number.json": "not a release candidate tag",
        "red-rc-two-numbers.json": "not a release candidate tag",
        "red-rc-uppercase.json": "not a release candidate tag",
        "red-beta-tag.json": "not a release candidate tag",
        "red-build-metadata-tag.json": "not a release candidate tag",
        "red-tag-without-v.json": "not a release candidate tag",
        "red-tag-leading-zero.json": "not a release candidate tag",
        "red-minimum-supported-tag-own-final.json": "minimumSupportedTag v0.3.0 is above tag v0.3.0-rc.2",
        "red-minimum-supported-tag-above-tag.json": "minimumSupportedTag v0.4.0 is above tag v0.3.0-rc.2",
        "red-minimum-supported-tag-rc.json": "minimumSupportedTag is not a final release tag",
        "red-minimum-supported-tag-missing.json": "minimumSupportedTag is not a final release tag",
        "red-short-version-with-suffix.json": "shortVersion is not 0.3.0",
        "red-short-version-other-core.json": "shortVersion is not 0.3.0",
        "red-image-name-core-only.json": "image name is not k3sm_0.3.0-rc.2_darwin_arm64.dmg",
        "red-archive-core-only.json": "archive is not k3sm_0.3.0-rc.2_darwin_arm64.tar.gz",
        "red-archive-other-candidate.json": "archive is not k3sm_0.3.0-rc.2_darwin_arm64.tar.gz",
        "red-url-other-candidate.json": "image url is not",
        "red-url-final-tag.json": "image url is not",
        "red-url-latest.json": "image url is not",
        "red-foreign-host.json": "image url is not",
        "red-redirect-host-as-url.json": "image url is not",
        "red-foreign-repo.json": "image url is not",
        "red-url-query.json": "image url is not",
        "red-unknown-field.json": #"unknown key "channel""#,
        "red-case-variant-key.json": #"unknown key "Tag""#,
        "red-duplicate-key.json": #"duplicate key "tag""#,
        "red-array-value.json": "holds an array",
        "red-not-an-object.json": "not a JSON object",
        "red-trailing-garbage.json": "trailing data",
        "red-second-value.json": "trailing data",
        "red-truncated.json": "not a valid document",
        "red-issued-at-offset.json": "issuedAt is not",
        "red-minimum-macos-word.json": "minimumMacOS is not",
        "red-other-bundle-id.json": "bundleID is not",
        "red-image-sha-uppercase.json": "image sha256 is not",
        "red-image-zero-size.json": "image size 0 is outside",
        "red-archive-sha-short.json": "archiveSHA256 is not",
        "red-payload-manifest-sha-short.json": "payloadManifestSHA256 is not",
    ]

    @Test func candidateIndexDecodesK3smGolden() throws {
        let ix = try ReleaseIndex.parse(try candidateFixture("index.json"), expected: Self.kind)
        #expect(ix.schema == "k3sm-release-index-rc/v1")
        #expect(ix.context == "io.k3sm.release-index-rc/v1")
        #expect(ix.issuedAt == "2026-11-05T12:30:45Z")
        #expect(ix.tag == Self.requested)
        #expect(ix.version.isReleaseCandidate)
        #expect(ix.minimumSupportedTag == "v0.2.0")
        #expect(ix.app.shortVersion == "0.3.0")
        #expect(ix.app.image.name == "k3sm_0.3.0-rc.2_darwin_arm64.dmg")
        #expect(ix.app.image.url == ReleaseIndex.downloadURL(tag: Self.requested, name: "k3sm_0.3.0-rc.2_darwin_arm64.dmg"))
        #expect(ix.app.image.size == 123_456_789)
        #expect(ix.k3sm.archive == "k3sm_0.3.0-rc.2_darwin_arm64.tar.gz")
        #expect(AppUpdateLatest(index: ix)?.tag == Self.requested)
    }

    @Test func everyCandidateRedIsRefusedForK3smsReason() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: candidateDirectory().path)
        let reds = Set(files.filter { $0.hasPrefix("red-") && $0.hasSuffix(".json") })
        #expect(reds.count == 49)
        #expect(reds == Set(Self.redReasons.keys), "the reason table and the vendored reds differ")
        for name in reds.sorted() {
            do {
                let accepted = try ReleaseIndex.parse(try candidateFixture(name), expected: Self.kind)
                Issue.record("\(name) was accepted as \(accepted)")
            } catch let error as ReleaseIndexError {
                let reason = Self.redReasons[name] ?? "<no reason>"
                #expect(error.description.contains(reason), "\(name): got \(error), want \(reason)")
            }
        }

        // The manifest names every vendored file, and only those.
        let manifest = String(decoding: try candidateFixture("SHA256SUMS"), as: UTF8.self)
        var listed: [String: String] = [:]
        for line in manifest.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            #expect(fields.count == 2, "a manifest line is not <sha256>  <name>: \(line)")
            guard fields.count == 2 else { continue }
            listed[String(fields[1])] = String(fields[0])
        }
        #expect(Set(listed.keys) == Set(files).subtracting(["SHA256SUMS"]), "the manifest and the directory differ")
        for (name, want) in listed.sorted(by: { $0.key < $1.key }) {
            let got = SHA256.hash(data: try candidateFixture(name)).map { String(format: "%02x", $0) }.joined()
            #expect(got == want, "\(name) does not match SHA256SUMS; re-copy it from k3sm")
        }
    }

    @Test func eachKindRefusesTheOthersDocument() throws {
        let golden = try candidateFixture("index.json")
        let stable = try stableFixture("index.json")
        #expect(throws: ReleaseIndexError.candidateSchema) { try ReleaseIndex.parse(stable, expected: .candidate(tag: "v0.2.0")) }
        #expect(throws: ReleaseIndexError.schema) { try ReleaseIndex.parse(golden, expected: .stable) }

        // With both strings swapped, the kind still decides the tag grammar.
        let swapped = String(decoding: golden, as: UTF8.self)
            .replacingOccurrences(of: ReleaseIndex.candidateSchema, with: ReleaseIndex.schema)
            .replacingOccurrences(of: ReleaseIndex.candidateContext, with: ReleaseIndex.context)
        #expect(throws: ReleaseIndexError.tag) { try ReleaseIndex.parse(Data(swapped.utf8), expected: .stable) }

        // The kind is read before the body: a body that would not decode is
        // refused for its kind when the kind is wrong, for itself when it is right.
        let badBody = String(decoding: golden, as: UTF8.self).replacingOccurrences(of: "123456789", with: "\"big\"")
        #expect(throws: ReleaseIndexError.schema) { try ReleaseIndex.parse(Data(badBody.utf8), expected: .stable) }
        #expect(throws: ReleaseIndexError.invalidDocument("key \"size\" is not an integer")) {
            try ReleaseIndex.parse(Data(badBody.utf8), expected: Self.kind)
        }
        // A kind string of the wrong type is still a decode refusal, as in k3sm.
        let numeric = String(decoding: golden, as: UTF8.self).replacingOccurrences(of: "\"k3sm-release-index-rc/v1\"", with: "1")
        #expect(throws: ReleaseIndexError.invalidDocument("key \"schema\" is not a string")) {
            try ReleaseIndex.parse(Data(numeric.utf8), expected: Self.kind)
        }
    }

    @Test func theRequestedTagIsHeldExactly() throws {
        let golden = try candidateFixture("index.json")
        for requested in ["", "v0.3.0", "v0.3.0-rc.1", "latest", "v0.3.0-rc.2 ", "v0.3.0-rc.\u{FF12}"] {
            #expect(throws: ReleaseIndexError.requestedTag(Self.requested, requested)) {
                try ReleaseIndex.parse(golden, expected: .candidate(tag: requested))
            }
        }
        let text = String(decoding: golden, as: UTF8.self)
        for rc in ["rc.0", "rc.1", "rc.10", "rc.9999"] {
            let raw = Data(text.replacingOccurrences(of: "rc.2", with: rc).utf8)
            #expect(try ReleaseIndex.parse(raw, expected: .candidate(tag: "v0.3.0-" + rc)).tag == "v0.3.0-" + rc)
        }
    }

    @Test func theByteCapHoldsForACandidate() throws {
        let golden = try candidateFixture("index.json")
        let atCap = Data(repeating: 0x20, count: ReleaseIndex.maxBytes - golden.count) + golden
        #expect(try ReleaseIndex.parse(atCap, expected: Self.kind).tag == Self.requested)
        #expect(throws: ReleaseIndexError.tooLarge(ReleaseIndex.maxBytes + 1)) {
            try ReleaseIndex.parse(Data([0x20]) + atCap, expected: Self.kind)
        }
    }

    /// Seeded mutants of the candidate golden: none traps, each answers the same
    /// twice, and any accepted one is still a candidate at the requested tag.
    @Test func mutatedCandidateIndexesNeverTrapOrChangeTag() throws {
        let golden = [UInt8](try candidateFixture("index.json"))
        for raw in ReleaseIndexMutator.mutants(of: golden, count: 2000, seed: 0x6B33_736D_7263) {
            let first = Result { () throws(ReleaseIndexError) in try ReleaseIndex.parse(Data(raw), expected: Self.kind) }
            let second = Result { () throws(ReleaseIndexError) in try ReleaseIndex.parse(Data(raw), expected: Self.kind) }
            #expect(first == second)
            if case .success(let ix) = first {
                #expect(ix.tag == Self.requested && ix.schema == ReleaseIndex.candidateSchema && ix.context == ReleaseIndex.candidateContext)
            }
        }
    }
}
