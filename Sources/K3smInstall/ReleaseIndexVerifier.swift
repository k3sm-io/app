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

import K3smStatus

/// ReleaseIndexVerifier accepts a release index only as CMS SignedData from
/// the pinned team's Developer ID Application identity, with a secure
/// timestamp, its chain evaluated at the time that timestamp attests. It
/// makes the checks `IndexSignerPolicy.checks` lists, in that order, and only
/// then hands the signed content to `ReleaseIndex.parse`.
///
/// `verified(p7m:)` is the only caller of `ReleaseIndex.parse` in the app
/// (a test holds it so), so an index is never decoded from bytes a signature
/// check has not accepted: not from a cache, not from a preference, not from
/// a download kept beside the `.p7m`. Every failure is a
/// `ReleaseIndexVerifierError`, and the caller shows each one as "could not
/// verify", never as an update.
///
/// No public API evaluates a code requirement against a CMS signer chain, so
/// each Developer ID fact is checked by hand. "anchor apple generic" is held
/// by evaluating the chain against the Apple roots of the system's own anchor
/// store only (`appleRoots()`), and then requiring the chain's root to be one
/// of them; no hash of a particular root is compiled in (see
/// `IndexSignerPolicy.checks`).
///
/// Revocation is checked by the system's trust evaluation: the trust daemon
/// may ask Apple's OCSP responder about the leaf. This type makes no network
/// request of its own.
public struct ReleaseIndexVerifier: Sendable {
    /// The largest signed index accepted, in bytes, refused before the CMS
    /// decoder reads anything. The JSON inside is at most
    /// `ReleaseIndex.maxBytes` (64 KiB); a Developer ID chain and a
    /// timestamp token add under 16 KiB. A fetch reads at most one byte more
    /// than this (`read(from:)`).
    public static let maxSignedBytes = 262_144

    /// How far past this Mac's clock the attested signing time may be. A
    /// timestamp from the future means a wrong clock or a forged time; an
    /// hour leaves room for ordinary clock drift without accepting either.
    public static let maxTimestampLead: TimeInterval = 3_600

    /// A release index the verifier accepted, with the signing time the
    /// timestamp authority attested. The caller enforces the index's own
    /// `issuedAt` against `signedAt`, never against a clock it reads itself.
    public struct VerifiedReleaseIndex: Sendable {
        public let index: ReleaseIndex
        public let signedAt: Date
    }

    /// Where the chain's root, or the timestamp authority's, must come from.
    enum Roots: Sendable {
        /// The Apple roots of the system anchor store: the shipped verifier.
        case apple
        /// Certificates a test injects (DER), trusted only through the test
        /// initializer.
        case injected([Data])
    }

    let policy: IndexSignerPolicy
    let anchors: Roots
    let timestampAnchors: Roots
    let clock: @Sendable () -> Date

    /// The verifier for the team this binary pins, trusting only Apple's
    /// roots; nil for a developer build, which never checks for updates.
    public static var pinned: ReleaseIndexVerifier? {
        AppUpdateTrust.pinnedIndexSigner.map {
            ReleaseIndexVerifier(policy: $0, anchors: .apple, timestampAnchors: .apple, clock: { Date() })
        }
    }

    /// The test initializer: test roots for the signer chain and for the
    /// timestamp authority, and a clock. The shipped verifier is only
    /// `pinned`.
    init(policy: IndexSignerPolicy, anchors: [SecCertificate], timestampAnchors: [SecCertificate], clock: @escaping @Sendable () -> Date) {
        self.init(
            policy: policy,
            anchors: .injected(anchors.map { SecCertificateCopyData($0) as Data }),
            timestampAnchors: .injected(timestampAnchors.map { SecCertificateCopyData($0) as Data }),
            clock: clock
        )
    }

    private init(policy: IndexSignerPolicy, anchors: Roots, timestampAnchors: Roots, clock: @escaping @Sendable () -> Date) {
        self.policy = policy
        self.anchors = anchors
        self.timestampAnchors = timestampAnchors
        self.clock = clock
    }

    /// Reads a signed index from `handle`, at most `maxSignedBytes` plus one
    /// byte, and refuses it when there is more.
    public static func read(from handle: FileHandle) throws(ReleaseIndexVerifierError) -> Data {
        let data: Data
        do {
            data = try handle.read(upToCount: maxSignedBytes + 1) ?? Data()
        } catch {
            throw .unreadable
        }
        guard data.count <= maxSignedBytes else { throw .tooLarge(data.count) }
        return data
    }

    /// The release index inside `p7m`, after every check passed, with the
    /// attested signing time. The signer chain is evaluated only at
    /// `signedAt`, the date `signingTime` derived from the timestamp (a test
    /// holds that no other date reaches `checkSigner`).
    public func verified(p7m: Data) throws(ReleaseIndexVerifierError) -> VerifiedReleaseIndex {
        let signed = try SignedIndex(p7m)
        let signedAt = try signingTime(signed.decoder)
        try checkSigner(signed.trust, at: signedAt)
        return VerifiedReleaseIndex(index: try index(from: signed.content), signedAt: signedAt)
    }

    // MARK: the stages, in order

    /// The steps before any time is known: the size cap, the decode, the
    /// content's shape, exactly one signer, and that signer's signature over
    /// the content (`kCMSSignerValid`). The trust object is kept for
    /// `checkSigner`, which evaluates it; the decoder never chooses the
    /// evaluation time.
    struct SignedIndex {
        let decoder: CMSDecoder
        let trust: SecTrust
        let content: Data

        /// id-data, 1.2.840.113549.1.7.1, as the decoder returns it.
        static let idData = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])

        init(_ p7m: Data) throws(ReleaseIndexVerifierError) {
            guard p7m.count <= ReleaseIndexVerifier.maxSignedBytes else { throw .tooLarge(p7m.count) }
            guard !p7m.isEmpty else { throw .decode(errSecParam) }
            var created: CMSDecoder?
            var status = CMSDecoderCreate(&created)
            guard status == errSecSuccess, let decoder = created else { throw .decode(status) }
            status = p7m.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
            guard status == errSecSuccess else { throw .decode(status) }
            status = CMSDecoderFinalizeMessage(decoder)
            guard status == errSecSuccess else { throw .decode(status) }

            var encrypted: DarwinBoolean = true
            guard CMSDecoderIsContentEncrypted(decoder, &encrypted) == errSecSuccess, !encrypted.boolValue else {
                throw .encrypted
            }
            var type: CFData?
            guard CMSDecoderCopyEncapsulatedContentType(decoder, &type) == errSecSuccess,
                  let type, type as Data == Self.idData
            else { throw .contentType }
            var copied: CFData?
            guard CMSDecoderCopyContent(decoder, &copied) == errSecSuccess,
                  let copied, CFDataGetLength(copied) > 0
            else { throw .noContent }

            var signers = 0
            guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess,
                  signers == IndexSignerPolicy.signerCount
            else { throw .signerCount(signers) }

            var signer = CMSSignerStatus.unsigned
            var trust: SecTrust?
            var certStatus: OSStatus = errSecSuccess
            status = CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &signer, &trust, &certStatus)
            guard status == errSecSuccess, signer == .valid, let trust else {
                throw .signerStatus(signer.rawValue)
            }
            self.decoder = decoder
            self.trust = trust
            self.content = copied as Data
        }
    }

    /// The signing time, taken only from the timestamp authority's
    /// countersignature (never the signer's own signing-time attribute):
    /// the decoder's timestamp check under the time-stamping policy, then
    /// the authority's own chain evaluated at that time against Apple's
    /// roots (or the test's), then the time held to this Mac's clock.
    func signingTime(_ decoder: CMSDecoder) throws(ReleaseIndexVerifierError) -> Date {
        var at: CFAbsoluteTime = 0
        guard let stamping = SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil) else {
            throw .timestamp(errSecParam)
        }
        let status = CMSDecoderCopySignerTimestampWithPolicy(decoder, stamping, 0, &at)
        guard status == errSecSuccess else { throw .timestamp(status) }
        var certificates: CFArray?
        guard CMSDecoderCopySignerTimestampCertificates(decoder, 0, &certificates) == errSecSuccess,
              let list = certificates as? [SecCertificate]
        else { throw .timestampAuthority(errSecTimestampMissing) }
        let date = Date(timeIntervalSinceReferenceDate: at)
        try checkTimestampAuthority(list, at: date)
        try checkNotAhead(date)
        return date
    }

    /// Refuses an attested time more than `maxTimestampLead` past the clock.
    func checkNotAhead(_ date: Date) throws(ReleaseIndexVerifierError) {
        let now = clock()
        guard date <= now.addingTimeInterval(Self.maxTimestampLead) else {
            throw .timestampInFuture(minutesAhead: Int((date.timeIntervalSince(now) / 60).rounded()))
        }
    }

    /// The timestamp authority: exactly one distinct certificate with the
    /// time-stamping extended key usage, its chain valid at `date` under the
    /// time-stamping policy and anchored at one of `timestampAnchors` only.
    func checkTimestampAuthority(_ certificates: [SecCertificate], at date: Date) throws(ReleaseIndexVerifierError) {
        var seen = Set<Data>()
        let distinct = certificates.filter { seen.insert(SecCertificateCopyData($0) as Data).inserted }
        let authorities = distinct.filter { Self.extendedKeyUsage($0).contains(Self.timeStampingUsage) }
        guard authorities.count == 1, let authority = authorities.first else {
            throw .timestampAuthority(errSecTimestampNotTrusted)
        }
        guard let stamping = SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil) else {
            throw .timestampAuthority(errSecParam)
        }
        let others = distinct.filter { $0 !== authority }
        let roots = Self.roots(timestampAnchors)
        let chain = try Self.evaluate([authority] + others, policies: [stamping], anchors: roots, at: date) {
            code throws(ReleaseIndexVerifierError) in .timestampAuthority(code)
        }
        // Redundant by design: the evaluation above sets anchors-only, so a
        // chain it accepts already ends at one of `roots`. Kept as a second,
        // independent check in case a later SDK changes how anchors-only
        // behaves; no input reaches it today.
        guard let root = chain.last, roots.contains(SecCertificateCopyData(root) as Data) else {
            throw .timestampAuthority(errSecTimestampNotTrusted)
        }
    }

    /// The signer chain at `date`: evaluated with the Apple code-signing
    /// policy and revocation against the anchors only, then the Developer
    /// ID facts by hand, in the order `IndexSignerPolicy.checks` lists.
    ///
    /// Revocation: `kSecRevocationUseAnyAvailableMethod` without
    /// `kSecRevocationRequirePositiveResponse` soft-fails, so an unreachable
    /// OCSP responder does not refuse the index. This is an accepted
    /// residual risk. It matches the platform's own Developer ID posture,
    /// where Gatekeeper and notarization revocation are best-effort online
    /// checks, and it is accepted because a hard fail would make updates
    /// impossible on Macs that are offline or behind a filtering proxy. The
    /// (tag, issuedAt) monotonic floor (B827) stops replay of an old index;
    /// it does not cover this: a stolen, revoked key could sign a new index
    /// while the responder is blocked.
    func checkSigner(_ trust: SecTrust, at date: Date) throws(ReleaseIndexVerifierError) {
        let roots = Self.roots(anchors)
        guard let codeSigning = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil),
              let revocation = SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod)),
              SecTrustSetPolicies(trust, [codeSigning, revocation] as CFArray) == errSecSuccess
        else {
            throw .chainUntrusted(errSecParam)
        }
        let chain = try Self.evaluate(trust, anchors: roots, at: date) { code throws(ReleaseIndexVerifierError) in
            .chainUntrusted(code)
        }
        // Redundant by design: anchors-only evaluation already ends the chain
        // at one of `roots`. Kept as defence in depth against a change in
        // that behaviour; unreachable today.
        guard let root = chain.last, roots.contains(SecCertificateCopyData(root) as Data) else { throw .anchor }
        guard chain.count > 1, Self.hasExtension(chain[1], IndexSignerPolicy.intermediateMarkerOID) else {
            throw .intermediateMarker
        }
        let leaf = chain[0]
        guard Self.hasExtension(leaf, IndexSignerPolicy.leafMarkerOID) else { throw .leafMarker }
        guard Self.extendedKeyUsage(leaf).contains(Self.codeSigningUsage) else { throw .codeSigningUsage }
        guard Self.subjectValues(leaf, Self.organizationalUnitOID) == [policy.teamID.value] else { throw .teamOU }
        // Redundant by design in the shipped path: the marker checks above
        // already tie certificates 0 and 1 to Apple's Developer ID
        // intermediate, which chains straight to the Apple root, so no real
        // Developer ID chain is longer than three. The check pins the shape
        // anyway as defence in depth; only the test roots' long-chain fixture
        // reaches it.
        guard chain.count == IndexSignerPolicy.chainLength else { throw .chainLength(chain.count) }
    }

    /// The last check: the signed content is a release index, its context
    /// string included. This is the one call of `ReleaseIndex.parse`.
    func index(from content: Data) throws(ReleaseIndexVerifierError) -> ReleaseIndex {
        do {
            return try ReleaseIndex.parse(content)
        } catch {
            throw .index(error)
        }
    }

    // MARK: roots and certificate facts

    /// The Apple roots of the system anchor store: self-issued certificates
    /// whose subject organization is Apple Inc. The store is the system's
    /// own (a root a user or an administrator adds is not in it), so a name
    /// check over it selects Apple's roots and nothing else. Apple can add a
    /// root (macOS 27 carries the Apple Platform roots beside Apple Root CA)
    /// without an app update.
    ///
    /// Threat model: the system anchor store is root- and SIP-protected, and
    /// an attacker who can write it can replace the app itself, so trusting
    /// it adds no exposure. That a root added by a user or an administrator
    /// is not returned here is verified on a real install in B834: add a
    /// self-issued "Apple Inc." root to the System keychain and to the admin
    /// trust domain, then assert it is absent from `appleRoots()`.
    static func appleRoots() -> [Data] {
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess,
              let list = anchors as? [SecCertificate]
        else { return [] }
        return list.filter { cert in
            subjectValues(cert, organizationOID) == ["Apple Inc."]
                && SecCertificateCopyNormalizedSubjectSequence(cert).map { $0 as Data }
                == SecCertificateCopyNormalizedIssuerSequence(cert).map { $0 as Data }
        }.map { SecCertificateCopyData($0) as Data }
    }

    static func roots(_ roots: Roots) -> [Data] {
        switch roots {
        case .apple: appleRoots()
        case .injected(let list): list
        }
    }

    /// Evaluates `trust` at `date` against `anchors` only and returns the
    /// chain it built.
    static func evaluate(
        _ trust: SecTrust, anchors: [Data], at date: Date,
        refusal: (OSStatus) throws(ReleaseIndexVerifierError) -> ReleaseIndexVerifierError
    ) throws(ReleaseIndexVerifierError) -> [SecCertificate] {
        let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty,
              SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess
        else { throw try refusal(errSecParam) }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw try refusal(error.map { OSStatus(truncatingIfNeeded: CFErrorGetCode($0)) } ?? errSecNotTrusted)
        }
        return (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }

    static func evaluate(
        _ certificates: [SecCertificate], policies: [SecPolicy], anchors: [Data], at date: Date,
        refusal: (OSStatus) throws(ReleaseIndexVerifierError) -> ReleaseIndexVerifierError
    ) throws(ReleaseIndexVerifierError) -> [SecCertificate] {
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policies as CFArray, &made) == errSecSuccess,
              let trust = made
        else { throw try refusal(errSecParam) }
        return try evaluate(trust, anchors: anchors, at: date, refusal: refusal)
    }

    /// id-kp-codeSigning and id-kp-timeStamping, as the certificate's
    /// extended key usage values carry them (the OID's DER content bytes).
    static let codeSigningUsage = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])
    static let timeStampingUsage = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x08])
    static let organizationalUnitOID = "2.5.4.11"
    static let organizationOID = "2.5.4.10"

    static func values(_ cert: SecCertificate, _ key: String) -> Any? {
        let all = SecCertificateCopyValues(cert, [key] as CFArray, nil) as? [String: Any]
        return (all?[key] as? [String: Any])?[kSecPropertyKeyValue as String]
    }

    static func hasExtension(_ cert: SecCertificate, _ oid: String) -> Bool {
        let all = SecCertificateCopyValues(cert, [oid] as CFArray, nil) as? [String: Any]
        return all?[oid] != nil
    }

    static func extendedKeyUsage(_ cert: SecCertificate) -> [Data] {
        (values(cert, kSecOIDExtendedKeyUsage as String) as? [Any] ?? []).compactMap { $0 as? Data }
    }

    /// Every value of the subject attribute `oid`, in order; a value that
    /// is not a string reads as an empty one, so it never matches.
    static func subjectValues(_ cert: SecCertificate, _ oid: String) -> [String] {
        let entries = values(cert, kSecOIDX509V1SubjectName as String) as? [[String: Any]] ?? []
        return entries
            .filter { $0[kSecPropertyKeyLabel as String] as? String == oid }
            .map { $0[kSecPropertyKeyValue as String] as? String ?? "" }
    }
}

/// Why a release index was not accepted. The app shows every case as "could
/// not verify"; the case names the check, for the log and the tests.
public enum ReleaseIndexVerifierError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Over `ReleaseIndexVerifier.maxSignedBytes`, before any decoding.
    case tooLarge(Int)
    /// The bytes could not be read.
    case unreadable
    /// Not CMS the decoder reads (its status).
    case decode(OSStatus)
    /// The content is encrypted.
    case encrypted
    /// The content is not id-data.
    case contentType
    /// No content inside the signature (detached), or empty content.
    case noContent
    /// Not exactly one signer (how many).
    case signerCount(Int)
    /// The signer's signature or content digest is not valid (the decoder's
    /// CMSSignerStatus).
    case signerStatus(UInt32)
    /// No trusted timestamp countersignature (the decoder's status:
    /// missing, invalid or not trusted).
    case timestamp(OSStatus)
    /// The timestamp authority's chain is not one of the trusted roots'.
    case timestampAuthority(OSStatus)
    /// The attested signing time is later than this Mac's clock allows (how
    /// many minutes ahead, rounded): the Mac's date and time look wrong.
    case timestampInFuture(minutesAhead: Int)
    /// The signer chain failed evaluation at the signing time.
    case chainUntrusted(OSStatus)
    /// The chain's root is not a trusted root.
    case anchor
    /// Certificate 1 lacks the Developer ID intermediate marker.
    case intermediateMarker
    /// The leaf lacks the Developer ID Application marker.
    case leafMarker
    /// The leaf's extended key usage lacks code signing.
    case codeSigningUsage
    /// The leaf subject OU is not exactly the pinned Team ID.
    case teamOU
    /// The chain is not leaf, intermediate, root (its length).
    case chainLength(Int)
    /// The signed content is not a release index.
    case index(ReleaseIndexError)

    public var description: String {
        switch self {
        case .tooLarge(let n): "\(n) bytes, over the \(ReleaseIndexVerifier.maxSignedBytes) byte cap"
        case .unreadable: "the signed index could not be read"
        case .decode(let s): "not a CMS signed message (\(s))"
        case .encrypted: "the content is encrypted"
        case .contentType: "the content is not data"
        case .noContent: "the signature carries no content"
        case .signerCount(let n): "\(n) signers, not exactly 1"
        case .signerStatus(let s): "the signature is not valid (signer status \(s))"
        case .timestamp(let s): "no trusted timestamp (\(s))"
        case .timestampAuthority(let s): "the timestamp authority is not trusted (\(s))"
        case .timestampInFuture(let m):
            "this Mac's date and time look wrong: the signed update is dated \(m) minutes ahead of it; check Date & Time in System Settings"
        case .chainUntrusted(let s): "the signing certificate is not trusted at the signing time (\(s))"
        case .anchor: "the signing certificate is not anchored at an Apple root"
        case .intermediateMarker: "the intermediate is not a Developer ID certification authority"
        case .leafMarker: "the signing certificate is not a Developer ID Application certificate"
        case .codeSigningUsage: "the signing certificate is not for code signing"
        case .teamOU: "the signing certificate is not the pinned team's"
        case .chainLength(let n): "the chain has \(n) certificates, not 3"
        case .index(let e): "the signed content is not a release index: \(e)"
        }
    }
}
