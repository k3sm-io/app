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

/// AppUpdateTrust is the one source of what the compiled Team ID pin
/// authorizes for a self-update: replacing the app with a new bundle, and
/// accepting a release index as signed by the same team. Both are built from
/// `TeamIDPin.teamID` and nothing else, so a self-update adds no key, no
/// signer and no trust root beside the one the root step already pins.
///
/// This is policy as data. It verifies nothing itself: the bundle check
/// (`SecStaticCodeCheckValidity` or `codesign --verify -R`) and the index
/// check (CMS and `SecTrust`) consume these values.
public enum AppUpdateTrust {
    /// The code signing identifier a replacement must carry, which the
    /// requirement's `identifier` clause tests. It is the identifier sealed in
    /// the code signature, not `CFBundleIdentifier`; the staged bundle's
    /// verifier also checks that its Info.plist `CFBundleIdentifier` equals
    /// this value.
    public static let bundleIdentifier = "io.k3sm.app"

    /// The code signing identifier of the swap helper the app ships at
    /// `Contents/Helpers/k3sm-app-update`.
    public static let helperIdentifier = "io.k3sm.app.update"

    /// The code requirement a staged replacement of the app must satisfy:
    /// the Developer ID Application requirement for `teamID` (an Apple
    /// anchor, the Developer ID intermediate and leaf markers, the leaf OU
    /// equal to the team), the app's bundle identifier, and Apple's
    /// notarization. The four Developer ID clauses come from
    /// `DesignatedRequirement.developerID(teamID:)`, the same text the root
    /// step checks the installed CLI against.
    public static func appRequirement(teamID: TeamID) -> String {
        DesignatedRequirement.developerID(teamID: teamID)
            + " and identifier \"\(bundleIdentifier)\""
            + " and notarized"
    }

    /// The code requirement the swap helper must satisfy before it runs from
    /// its private copy: the same Developer ID clauses for `teamID` as the
    /// app requirement, and the helper's own identifier. It has no
    /// `notarized` clause: the copy runs as a loose Mach-O, which carries no
    /// stapled ticket, and it is verified as a member of the app bundle
    /// that already passed `appRequirement(teamID:)`, `notarized` included.
    public static func helperRequirement(teamID: TeamID) -> String {
        DesignatedRequirement.developerID(teamID: teamID)
            + " and identifier \"\(helperIdentifier)\""
    }

    /// The app-update requirement for the team this binary pins, or nil for
    /// a developer build, which never updates itself.
    public static var pinnedAppRequirement: String? {
        TeamIDPin.teamID.map(appRequirement(teamID:))
    }

    /// The policy a release index signer must satisfy for `teamID`.
    public static func indexSigner(teamID: TeamID) -> IndexSignerPolicy {
        IndexSignerPolicy(teamID: teamID)
    }

    /// The index signer policy for the team this binary pins, or nil for a
    /// developer build, which never checks for updates.
    public static var pinnedIndexSigner: IndexSignerPolicy? {
        TeamIDPin.teamID.map(indexSigner(teamID:))
    }

    /// Whether a staged bundle whose compiled pin is `staged` may replace a
    /// running app whose compiled pin is `running`. Only the same team is
    /// authorized: a developer build replaces nothing and is never a
    /// replacement, and a bundle pinning another team is always refused, so
    /// a change of signing team can never ride an update.
    public static func authorizesReplacement(running: TeamID?, staged: TeamID?) -> Bool {
        guard let running, let staged else { return false }
        return running == staged
    }
}

/// IndexSignerPolicy is what a release index's CMS signer must be: the
/// Developer ID Application identity of the pinned team, with a secure
/// timestamp, evaluated at the time that timestamp attests.
public struct IndexSignerPolicy: Equatable, Sendable {
    /// The OID marking Apple's Developer ID Certification Authority
    /// intermediate (`certificate 1` of the chain).
    public static let intermediateMarkerOID = "1.2.840.113635.100.6.2.6"

    /// The OID marking a Developer ID Application leaf certificate.
    public static let leafMarkerOID = "1.2.840.113635.100.6.1.13"

    /// The extended key usage the leaf must carry: code signing
    /// (id-kp-codeSigning, RFC 5280 section 4.2.1.12). The requirement
    /// language cannot test an extended key usage value, so the verifier
    /// checks it through the Apple code-signing trust policy.
    public static let codeSigningUsageOID = "1.3.6.1.5.5.7.3.3"

    /// The number of signers the index carries: exactly one.
    public static let signerCount = 1

    /// The number of certificates in the signer's chain: leaf, intermediate,
    /// root.
    public static let chainLength = 3

    /// The fixed domain-separation string the signed content carries, so a
    /// signature over any other document the same identity signs never reads
    /// as a release index. It equals k3sm's `ReleaseIndexContext`
    /// (`pkg/update/releaseindex.go`).
    public static let contextString = "io.k3sm.release-index/v1"

    /// The team the leaf subject OU must equal.
    public let teamID: TeamID

    public init(teamID: TeamID) {
        self.teamID = teamID
    }

    /// The certificate facts in the code requirement language, for a
    /// verifier that evaluates the signer chain against a requirement. It is
    /// the app requirement without the clauses that only code has (the
    /// bundle identifier and notarization).
    public var requirement: String {
        DesignatedRequirement.developerID(teamID: teamID)
    }

    /// The checks a verifier makes, each a fixed sentence. This list is the
    /// complete, ordered contract the release index verifier implements: it
    /// makes every check, in this order, and decodes the index only as the
    /// last one (the context string is read by that decode); its tests
    /// cover every entry. An index that fails any of them is
    /// "could not verify", never an update.
    ///
    /// The anchor check is `anchor apple generic` and no hash of a particular
    /// Apple root is compiled in: a pinned root hash would lock every
    /// installed app out of updates, fleet-wide, the day Apple re-roots the
    /// Developer ID chain, and only a manual reinstall would recover it.
    public var checks: [String] {
        [
            "exactly \(Self.signerCount) CMS signer",
            "the CMS signature and content digest are valid (kCMSSignerValid)",
            "a secure timestamp countersignature from a trusted timestamp authority; none refuses",
            "the signing time taken only from that countersignature",
            "the chain evaluated at the signing time with the Apple code-signing policy, revocation included",
            "anchor apple generic",
            "certificate 1 carries \(Self.intermediateMarkerOID)",
            "the leaf carries \(Self.leafMarkerOID)",
            "the leaf extended key usage includes \(Self.codeSigningUsageOID)",
            "the leaf subject OU equals \(teamID.value)",
            "the chain is exactly \(Self.chainLength) certificates: leaf, intermediate, root",
            "the signed content carries the context string \(Self.contextString)",
        ]
    }
}
