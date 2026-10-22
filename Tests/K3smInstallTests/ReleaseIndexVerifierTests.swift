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
import Security
import Testing

@testable import K3smInstall
import K3smStatus

/// The release index verifier against signed fixtures made under throwaway
/// test roots (`hack/release-index-cms/make-fixtures.sh`).
///
/// The macOS CMS decoder trusts a timestamp only from an authority the
/// system trusts, and a test cannot add one (`releaseIndexTimestampAPIBehaviour`
/// pins this). So no test here can accept an index end to end: the accepting
/// path, a moved timestamp caught by its message imprint, and the chain and
/// Developer ID checks reached through a real Apple timestamp are proven
/// against a real Developer ID signature, outside this suite. What the suite
/// proves end to end is every refusal up to and including the timestamp
/// step; the chain, Developer ID and content checks it proves stage by stage,
/// on signatures whose signer status is valid, at a time the test chooses.
@Suite("release index verifier")
struct ReleaseIndexVerifierTests {
    static let team = TeamID("ABCDE12345")!
    static let policy = IndexSignerPolicy(teamID: team)

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/release-index-cms") else {
            throw FixtureMissing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func certificate(_ name: String) throws -> SecCertificate {
        guard let cert = SecCertificateCreateWithData(nil, try fixture(name) as CFData) else {
            throw FixtureMissing(name: name)
        }
        return cert
    }

    struct FixtureMissing: Error {
        let name: String
    }

    /// The test verifier: the test root for the signer chain, the test
    /// timestamp root, the real clock.
    static func verifier(anchors: [String] = ["root.cer"], timestampAnchors: [String] = ["tsa-root.cer"],
                         clock: @escaping @Sendable () -> Date = { Date() }) throws -> ReleaseIndexVerifier {
        ReleaseIndexVerifier(
            policy: policy,
            anchors: try anchors.map(certificate),
            timestampAnchors: try timestampAnchors.map(certificate),
            clock: clock
        )
    }

    static func refusal(_ p7m: Data, _ verifier: ReleaseIndexVerifier) -> ReleaseIndexVerifierError? {
        do {
            _ = try verifier.verified(p7m: p7m)
            return nil
        } catch {
            return error
        }
    }

    static func decoder(_ p7m: Data) -> CMSDecoder {
        var made: CMSDecoder?
        CMSDecoderCreate(&made)
        let decoder = made!
        _ = p7m.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        CMSDecoderFinalizeMessage(decoder)
        return decoder
    }

    // MARK: the gate

    /// The gate: a correctly signed index (one signer, a valid signature over
    /// the content, a chain the test root anchors) with no timestamp is
    /// refused at the timestamp step. It carries the signer's own
    /// signing-time attribute, which is never used as the signing time.
    @Test func releaseIndexVerifierRefusesUntimestampedIndex() throws {
        let p7m = try Self.fixture("index-untimestamped.p7m")
        let signed = try ReleaseIndexVerifier.SignedIndex(p7m)
        var claimed: CFAbsoluteTime = 0
        #expect(CMSDecoderCopySignerSigningTime(signed.decoder, 0, &claimed) == errSecSuccess)
        #expect(claimed > 0, "the fixture carries a signing-time attribute")
        let verifier = try Self.verifier()
        // Everything but the timestamp holds: the chain at the claimed time.
        try verifier.checkSigner(signed.trust, at: Date(timeIntervalSinceReferenceDate: claimed))
        #expect(Self.refusal(p7m, verifier) == .timestamp(errSecTimestampMissing))
        // The same for the leaf that has since expired.
        let expired = try Self.fixture("index-expired-leaf-untimestamped.p7m")
        #expect(Self.refusal(expired, verifier) == .timestamp(errSecTimestampMissing))
    }

    // MARK: what the platform does (the probe, kept as a test)

    /// What the macOS CMS decoder and trust evaluation do with test
    /// certificates, recorded so a platform change shows up here:
    ///
    /// (a) a timestamp from a test authority is not trusted
    ///     (errSecTimestampNotTrusted), with or without the time-stamping
    ///     policy, and its presence turns the signer status invalid; so a
    ///     test cannot accept a timestamped index end to end;
    /// (b) no timestamp is errSecTimestampMissing, the signer status valid;
    /// (c) a genuine token moved from another signature reads exactly like
    ///     (a), so under a test authority a moved token cannot be told from
    ///     an untrusted one;
    /// (d) the timestamp call returns the same whether or not the signer
    ///     status was read first;
    /// (e) the Apple code-signing policy evaluates a chain against an
    ///     injected test anchor, refuses a leaf whose extended key usage lacks
    ///     code signing, and does not check the Developer ID leaf marker
    ///     (the verifier checks it by hand).
    /// (f) the authority's certificates are handed out only after the
    ///     timestamp call, even when that call refused the timestamp.
    @Test func releaseIndexTimestampAPIBehaviour() throws {
        let stamping = try #require(SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil))
        func timestamp(_ name: String, statusFirst: Bool, policy: Bool = true) throws -> (OSStatus, CMSSignerStatus) {
            let decoder = Self.decoder(try Self.fixture(name))
            var signer = CMSSignerStatus.unsigned
            if statusFirst {
                var trust: SecTrust?
                var verify: OSStatus = 0
                CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &signer, &trust, &verify)
            }
            var at: CFAbsoluteTime = 0
            let status = policy
                ? CMSDecoderCopySignerTimestampWithPolicy(decoder, stamping, 0, &at)
                : CMSDecoderCopySignerTimestamp(decoder, 0, &at)
            return (status, signer)
        }
        for name in ["index-timestamped.p7m", "index-untrusted-timestamp.p7m", "index-moved-timestamp.p7m"] {
            // (a), (c)
            #expect(try timestamp(name, statusFirst: true) == (errSecTimestampNotTrusted, .invalidSignature), "\(name)")
            #expect(try timestamp(name, statusFirst: true, policy: false).0 == errSecTimestampNotTrusted, "\(name)")
            // (d)
            #expect(try timestamp(name, statusFirst: false).0 == errSecTimestampNotTrusted, "\(name)")
        }
        // (f)
        let decoder = Self.decoder(try Self.fixture("index-timestamped.p7m"))
        var list: CFArray?
        #expect(CMSDecoderCopySignerTimestampCertificates(decoder, 0, &list) != errSecSuccess)
        var at: CFAbsoluteTime = 0
        #expect(CMSDecoderCopySignerTimestampWithPolicy(decoder, stamping, 0, &at) == errSecTimestampNotTrusted)
        #expect(CMSDecoderCopySignerTimestampCertificates(decoder, 0, &list) == errSecSuccess)
        // (b)
        #expect(try timestamp("index-untimestamped.p7m", statusFirst: true) == (errSecTimestampMissing, .valid))
        #expect(try timestamp("index-untimestamped.p7m", statusFirst: false).0 == errSecTimestampMissing)

        // (e)
        func evaluates(_ name: String) throws -> OSStatus {
            let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture(name))
            let codeSigning = try #require(SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil))
            SecTrustSetPolicies(signed.trust, codeSigning)
            SecTrustSetAnchorCertificates(signed.trust, [try Self.certificate("root.cer")] as CFArray)
            SecTrustSetAnchorCertificatesOnly(signed.trust, true)
            var error: CFError?
            return SecTrustEvaluateWithError(signed.trust, &error)
                ? errSecSuccess : OSStatus(truncatingIfNeeded: CFErrorGetCode(error!))
        }
        #expect(try evaluates("index-untimestamped.p7m") == errSecSuccess)
        #expect(try evaluates("index-no-codesigning-usage.p7m") == errSecInvalidExtendedKeyUsage)
        #expect(try evaluates("index-no-leaf-marker.p7m") == errSecSuccess)
    }

    // MARK: end-to-end refusals

    @Test("refused end to end, at the step named", arguments: [
        ("index-untimestamped.p7m", ReleaseIndexVerifierError.timestamp(errSecTimestampMissing)),
        // A test authority's timestamp is never trusted by the decoder, and a
        // timestamp it does not trust turns the signer status invalid
        // (kCMSSignerInvalidSignature): refused before any time is read.
        ("index-timestamped.p7m", .signerStatus(CMSSignerStatus.invalidSignature.rawValue)),
        ("index-untrusted-timestamp.p7m", .signerStatus(CMSSignerStatus.invalidSignature.rawValue)),
        ("index-moved-timestamp.p7m", .signerStatus(CMSSignerStatus.invalidSignature.rawValue)),
        ("index-expired-leaf-timestamped.p7m", .signerStatus(CMSSignerStatus.invalidSignature.rawValue)),
        ("index-detached.p7m", .noContent),
        ("index-two-signers.p7m", .signerCount(2)),
        ("index-no-signers.p7m", .signerCount(0)),
        // Signed without a timestamp, so each stops at the timestamp step;
        // the stage tests below reach the check each one breaks.
        ("index-other-ou.p7m", .timestamp(errSecTimestampMissing)),
        ("index-two-ou.p7m", .timestamp(errSecTimestampMissing)),
        ("index-no-leaf-marker.p7m", .timestamp(errSecTimestampMissing)),
        ("index-no-intermediate-marker.p7m", .timestamp(errSecTimestampMissing)),
        ("index-no-codesigning-usage.p7m", .timestamp(errSecTimestampMissing)),
        ("index-long-chain.p7m", .timestamp(errSecTimestampMissing)),
        ("no-context.p7m", .timestamp(errSecTimestampMissing)),
        ("other-context.p7m", .timestamp(errSecTimestampMissing)),
        ("not-an-index.p7m", .timestamp(errSecTimestampMissing)),
    ])
    func refusedEndToEnd(name: String, want: ReleaseIndexVerifierError) throws {
        #expect(Self.refusal(try Self.fixture(name), try Self.verifier()) == want)
    }

    @Test func aTimestampIsReadOnlyFromATrustedAuthority() throws {
        // The decoder's own refusal of each timestamp the test authorities
        // made, under the time-stamping policy the verifier passes.
        for name in ["index-timestamped.p7m", "index-untrusted-timestamp.p7m", "index-moved-timestamp.p7m"] {
            let verifier = try Self.verifier()
            #expect(throws: ReleaseIndexVerifierError.timestamp(errSecTimestampNotTrusted), "\(name)") {
                _ = try verifier.signingTime(Self.decoder(try Self.fixture(name)))
            }
        }
    }

    @Test func tamperedContentIsRefused() throws {
        var bytes = [UInt8](try Self.fixture("index-untimestamped.p7m"))
        let needle = Array(#""size": 123456789"#.utf8)
        let at = try #require(bytes.indices.first { bytes[$0...].starts(with: needle) })
        bytes[at + needle.count - 1] = UInt8(ascii: "8")
        #expect(Self.refusal(Data(bytes), try Self.verifier()) == .signerStatus(CMSSignerStatus.invalidSignature.rawValue))
    }

    @Test func sizeAndShapeAreRefusedBeforeTheSignature() throws {
        let verifier = try Self.verifier()
        let cap = ReleaseIndexVerifier.maxSignedBytes
        #expect(Self.refusal(Data(count: cap + 1), verifier) == .tooLarge(cap + 1))
        // Over the cap is refused on size even when it is a valid signature
        // followed by padding.
        let padded = try Self.fixture("index-untimestamped.p7m") + Data(count: cap)
        #expect(Self.refusal(padded, verifier) == .tooLarge(padded.count))
        #expect(Self.refusal(Data(), verifier) == .decode(errSecParam))
        guard case .decode = Self.refusal(Data("{\"tag\": \"v0.2.0\"}".utf8), verifier) else {
            Issue.record("JSON outside a signature was not refused as undecodable")
            return
        }
        guard case .decode = Self.refusal(Data(count: cap), verifier) else {
            Issue.record("zero bytes at the cap were not refused as undecodable")
            return
        }
    }

    @Test func aBoundedReadStopsOneBytePastTheCap() throws {
        let cap = ReleaseIndexVerifier.maxSignedBytes
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = dir.appendingPathComponent("at-cap.p7m")
        let over = dir.appendingPathComponent("over.p7m")
        try Data(count: cap).write(to: at)
        try Data(count: cap * 4).write(to: over)

        let atHandle = try FileHandle(forReadingFrom: at)
        defer { try? atHandle.close() }
        #expect(try ReleaseIndexVerifier.read(from: atHandle).count == cap)

        let overHandle = try FileHandle(forReadingFrom: over)
        defer { try? overHandle.close() }
        #expect(throws: ReleaseIndexVerifierError.tooLarge(cap + 1)) {
            _ = try ReleaseIndexVerifier.read(from: overHandle)
        }
        #expect(try overHandle.offset() == UInt64(cap + 1), "the read went past the cap plus one byte")
    }

    // MARK: stage by stage

    /// The golden index passes every check after the timestamp at the
    /// signing time, and the content decodes to the vendored golden.
    @Test func theSignerAndContentChecksAcceptTheGolden() throws {
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture("index-untimestamped.p7m"))
        let verifier = try Self.verifier()
        try verifier.checkSigner(signed.trust, at: Date())
        let index = try verifier.index(from: signed.content)
        #expect(index.tag == "v0.2.0")
        #expect(index.minimumSupportedTag == "v0.1.0")
        #expect(index.context == IndexSignerPolicy.contextString)
        #expect(index.app.image.size == 123_456_789)
    }

    @Test("each Developer ID fact is checked after the chain evaluates", arguments: [
        ("index-other-ou.p7m", ReleaseIndexVerifierError.teamOU),
        ("index-two-ou.p7m", .teamOU),
        ("index-no-leaf-marker.p7m", .leafMarker),
        ("index-no-intermediate-marker.p7m", .intermediateMarker),
        // The Apple code-signing policy refuses a leaf whose extended key
        // usage lacks code signing (errSecInvalidExtendedKeyUsage) before the
        // verifier's own check of the same fact.
        ("index-no-codesigning-usage.p7m", .chainUntrusted(errSecInvalidExtendedKeyUsage)),
        ("index-long-chain.p7m", .chainLength(4)),
    ])
    func signerStage(name: String, want: ReleaseIndexVerifierError) throws {
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture(name))
        #expect(throws: want) { try Self.verifier().checkSigner(signed.trust, at: Date()) }
    }

    @Test func theChainMustEndAtAnInjectedRoot() throws {
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture("index-untimestamped.p7m"))
        let other = try Self.verifier(anchors: ["other-root.cer"])
        #expect(throws: ReleaseIndexVerifierError.chainUntrusted(errSecNotTrusted)) {
            try other.checkSigner(signed.trust, at: Date())
        }
    }

    /// A leaf that expired after it signed is accepted at the time it
    /// signed and refused now: what a trusted timestamp, and only a trusted
    /// timestamp, decides.
    @Test func anExpiredLeafIsValidOnlyAtItsSigningTime() throws {
        let leaf = try Self.certificate("leaf-expired.cer")
        let validity = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any]
        let entry = validity?[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any]
        let notAfter = Date(timeIntervalSinceReferenceDate: try #require((entry?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue))
        #expect(notAfter < Date(), "the leaf has not expired yet; regenerate the fixtures and wait two minutes")

        let p7m = try Self.fixture("index-expired-leaf-untimestamped.p7m")
        let verifier = try Self.verifier()
        try verifier.checkSigner(try ReleaseIndexVerifier.SignedIndex(p7m).trust, at: notAfter.addingTimeInterval(-60))
        #expect(throws: ReleaseIndexVerifierError.chainUntrusted(errSecCertificateExpired)) {
            try verifier.checkSigner(try ReleaseIndexVerifier.SignedIndex(p7m).trust, at: Date())
        }
    }

    @Test("the signed content must be a release index", arguments: [
        ("no-context.p7m", ReleaseIndexVerifierError.index(.context)),
        ("other-context.p7m", .index(.context)),
    ])
    func contentStage(name: String, want: ReleaseIndexVerifierError) throws {
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture(name))
        #expect(throws: want) { try Self.verifier().index(from: signed.content) }
    }

    @Test func signedBytesThatAreNotAnIndexAreRefused() throws {
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture("not-an-index.p7m"))
        let verifier = try Self.verifier()
        do throws(ReleaseIndexVerifierError) {
            _ = try verifier.index(from: signed.content)
            Issue.record("signed text was accepted as an index")
        } catch {
            guard case .index = error else {
                Issue.record("refused for \(error), not as an index")
                return
            }
        }
    }

    /// The timestamp authority's own chain: one distinct time-stamping
    /// certificate, anchored at the timestamp roots only.
    @Test func theTimestampAuthorityIsAnchoredAtItsRootsOnly() throws {
        // The decoder hands out the authority's certificates only after its
        // timestamp call, as the verifier makes them (the probe's (f)).
        func authorityCertificates(_ name: String) throws -> [SecCertificate] {
            let decoder = Self.decoder(try Self.fixture(name))
            var at: CFAbsoluteTime = 0
            _ = CMSDecoderCopySignerTimestampWithPolicy(decoder, SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil), 0, &at)
            var list: CFArray?
            #expect(CMSDecoderCopySignerTimestampCertificates(decoder, 0, &list) == errSecSuccess)
            return try #require(list as? [SecCertificate])
        }
        let trusted = try authorityCertificates("index-timestamped.p7m")
        let untrusted = try authorityCertificates("index-untrusted-timestamp.p7m")
        try Self.verifier().checkTimestampAuthority(trusted, at: Date())
        #expect(throws: ReleaseIndexVerifierError.self) { try Self.verifier().checkTimestampAuthority(untrusted, at: Date()) }
        #expect(throws: ReleaseIndexVerifierError.self) {
            try Self.verifier(timestampAnchors: ["tsa-other-root.cer"]).checkTimestampAuthority(trusted, at: Date())
        }
        // The signer's own chain has no time-stamping certificate.
        let signed = try ReleaseIndexVerifier.SignedIndex(try Self.fixture("index-untimestamped.p7m"))
        let signerChain = try #require(SecTrustCopyCertificateChain(signed.trust) as? [SecCertificate])
        #expect(throws: ReleaseIndexVerifierError.timestampAuthority(errSecTimestampNotTrusted)) {
            try Self.verifier(timestampAnchors: ["root.cer"]).checkTimestampAuthority(signerChain, at: Date())
        }
    }

    @Test func theFutureSkewIsOneHour() {
        #expect(ReleaseIndexVerifier.maxTimestampLead == 3_600)
    }

    @Test func aTimestampFromTheFutureIsRefused() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let verifier = try Self.verifier(clock: { now })
        try verifier.checkNotAhead(now.addingTimeInterval(ReleaseIndexVerifier.maxTimestampLead))
        #expect(throws: ReleaseIndexVerifierError.timestampInFuture(minutesAhead: 60)) {
            try verifier.checkNotAhead(now.addingTimeInterval(ReleaseIndexVerifier.maxTimestampLead + 1))
        }
        #expect(throws: ReleaseIndexVerifierError.timestampInFuture(minutesAhead: 180)) {
            try verifier.checkNotAhead(now.addingTimeInterval(3 * 3_600 + 10))
        }
    }

    @Test func theFutureRefusalTellsTheUserToCheckTheClock() {
        let text = ReleaseIndexVerifierError.timestampInFuture(minutesAhead: 180).description
        #expect(text == "this Mac's date and time look wrong: the signed update is dated 180 minutes ahead of it; check Date & Time in System Settings")
    }

    // MARK: the shipped verifier

    @Test func aDevelopmentBuildHasNoVerifier() {
        #expect(TeamIDPin.teamID == nil)
        #expect(ReleaseIndexVerifier.pinned == nil)
    }

    /// The shipped verifier's roots are the Apple roots of the system anchor
    /// store, found by name there and never typed in: Apple Root CA, which
    /// anchors the Developer ID chain and Apple's timestamp authority, is
    /// one of them, every one is an Apple Inc. self-issued root, and the
    /// store's other roots are left out.
    @Test func theAppleRootsComeFromTheSystemStore() throws {
        var anchors: CFArray?
        #expect(SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess)
        let system = try #require(anchors as? [SecCertificate])
        let apple = ReleaseIndexVerifier.appleRoots()
        let summaries = apple.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            .map { SecCertificateCopySubjectSummary($0) as String? ?? "" }
        #expect(summaries.contains("Apple Root CA"))
        #expect(!apple.isEmpty && apple.count < system.count)
        for der in apple {
            let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
            #expect(ReleaseIndexVerifier.subjectValues(cert, ReleaseIndexVerifier.organizationOID) == ["Apple Inc."])
        }
        let systemDER = Set(system.map { SecCertificateCopyData($0) as Data })
        #expect(Set(apple).isSubset(of: systemDER))
    }

    /// Every check `IndexSignerPolicy.checks` lists is made, and this names
    /// where each is proven: a test here, or only against a real Developer
    /// ID signature with an Apple timestamp.
    @Test func everyListedCheckIsAccountedFor() {
        let proof = [
            "refusedEndToEnd: index-two-signers, index-no-signers",
            "refusedEndToEnd: tampered content, a test authority's timestamp",
            "releaseIndexVerifierRefusesUntimestampedIndex; accepting a trusted one needs a real Apple timestamp",
            "aTimestampIsReadOnlyFromATrustedAuthority; theTimestampAuthorityIsAnchoredAtItsRootsOnly; aTimestampFromTheFutureIsRefused",
            "anExpiredLeafIsValidOnlyAtItsSigningTime; index-no-codesigning-usage",
            "theChainMustEndAtAnInjectedRoot; theAppleRootsComeFromTheSystemStore",
            "signerStage: index-no-intermediate-marker",
            "signerStage: index-no-leaf-marker",
            "signerStage: index-no-codesigning-usage (refused by the policy first)",
            "signerStage: index-other-ou, index-two-ou",
            "signerStage: index-long-chain",
            "contentStage: no-context, other-context",
        ]
        #expect(proof.count == Self.policy.checks.count)
    }

    // MARK: verify, then parse

    /// The signer chain is evaluated only at the attested signing time:
    /// `verified(p7m:)` binds `signingTime`'s result to `signedAt`, passes
    /// that to `checkSigner`, returns it, and reads no clock of its own; and
    /// `checkSigner` has no other caller in the app. Passing `Date()` there
    /// fails this test.
    @Test func checkSignerOnlyReceivesTheAttestedSigningTime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let file = sources.appendingPathComponent("K3smInstall/ReleaseIndexVerifier.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
        let start = try #require(code.firstIndex { $0.contains("func verified(p7m:") })
        let end = try #require(code[start...].firstIndex { $0 == "    }" })
        let body = code[start...end].joined(separator: "\n")
        #expect(body.contains("let signedAt = try signingTime(signed.decoder)"))
        #expect(body.contains("try checkSigner(signed.trust, at: signedAt)"))
        #expect(body.contains("signedAt: signedAt"))
        #expect(!body.contains("Date("), "verified reads a clock: \(body)")
        #expect(!body.contains("clock"), "verified reads a clock: \(body)")

        var users: [String] = []
        for url in try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap({ $0 as? URL })
        where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            users += lines.filter { $0.contains("checkSigner(") && !$0.contains("func checkSigner") }
        }
        #expect(users.count == 1 && users[0].contains("at: signedAt"), "\(users)")
    }

    /// `ReleaseIndexVerifier.verified(p7m:)` is the only way into
    /// `ReleaseIndex.parse` in the app's sources: one call, in the verifier's
    /// last step, and no other reference to the decoder's entry point. So no
    /// index is ever decoded from a cache, a preference or a download that
    /// bypassed the signature check.
    @Test func onlyTheVerifierParsesAReleaseIndex() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the sources were not found at \(sources.path)")

        let call = try Regex(#"ReleaseIndex\s*\.\s*parse\b"#)
        let metatype = try Regex(#"ReleaseIndex\s*\.\s*(self|Type)\b"#)
        let extensionOf = try Regex(#"extension\s+ReleaseIndex\b"#)
        let bareCall = try Regex(#"\bparse\s*\("#)
        var calls: [String] = []
        for file in files {
            let name = file.path.replacingOccurrences(of: sources.path + "/", with: "")
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            for line in code {
                if line.contains(call) { calls.append(name) }
                #expect(!line.contains(metatype), "\(name): \(line)")
                if name != "K3smStatus/ReleaseIndex.swift" {
                    #expect(!line.contains(extensionOf), "\(name): \(line)")
                }
            }
            if name == "K3smStatus/ReleaseIndex.swift" {
                let uses = code.filter { $0.contains(bareCall) }
                #expect(uses.count == 1 && uses[0].contains("func parse("), "ReleaseIndex calls parse itself: \(uses)")
            }
        }
        #expect(calls == ["K3smInstall/ReleaseIndexVerifier.swift"])
    }

    // MARK: fuzz

    /// Seeded mutants of two signed indexes (bit flips, length-shaped bytes,
    /// insertions, truncations), fed to the verifier: each is refused (a
    /// trap would end the test process), within the bound, for the same
    /// reason twice. None can be accepted under the test roots, whose
    /// timestamps are never trusted, so the leg is about the decoder and the
    /// stages before the timestamp handling hostile DER.
    @Test func mutatedSignedIndexesAreRefusedAndNeverTrap() throws {
        let verifier = try Self.verifier()
        let bases = [try Self.fixture("index-untimestamped.p7m"), try Self.fixture("index-timestamped.p7m")]
        var rng = SplitMix64(seed: 0x6B33_736D_5037_4D21)
        let clock = ContinuousClock()
        var kinds: Set<String> = []
        for i in 0..<1500 {
            var m = [UInt8](bases[i % 2])
            for _ in 0..<(1 + rng.below(4)) {
                switch rng.below(10) {
                case 0..<4:
                    m[rng.below(m.count)] ^= UInt8(1) << UInt8(rng.below(8))
                case 4..<6:
                    m[rng.below(m.count)] = [0x00, 0x7F, 0x80, 0x81, 0x82, 0x84, 0x88, 0xFF][rng.below(8)]
                case 6..<8:
                    m.insert(UInt8(truncatingIfNeeded: rng.next()), at: rng.below(m.count + 1))
                default:
                    m.removeSubrange(max(1, rng.below(m.count))...)
                }
            }
            let raw = Data(m)
            var first: ReleaseIndexVerifierError?
            let elapsed = clock.measure { first = Self.refusal(raw, verifier) }
            #expect(elapsed < .seconds(2), "mutant \(i) took \(elapsed)")
            guard let first else {
                Issue.record("mutant \(i) was accepted")
                continue
            }
            #expect(Self.refusal(raw, verifier) == first, "mutant \(i) was refused for two reasons")
            kinds.insert(String(String(describing: first).prefix(16)))
        }
        #expect(kinds.count >= 3, "only \(kinds.count) kinds of refusal: \(kinds.sorted())")
    }
}

/// SplitMix64: a fixed pseudo-random sequence, so a seed always yields the
/// same mutants.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }
}
