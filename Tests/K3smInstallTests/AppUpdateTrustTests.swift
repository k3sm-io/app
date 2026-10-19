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

@Suite("app update trust")
struct AppUpdateTrustTests {
    static let team = TeamID("ABCDE12345")!

    /// The ruled app-update requirement, byte for byte.
    static let appGolden =
        #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app" and notarized"#

    /// The swap helper's requirement, byte for byte: no `notarized`.
    static let helperGolden =
        #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app.update""#

    /// The index signer's certificate facts, byte for byte.
    static let indexGolden =
        #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345""#

    /// The index verifier's checks, in order.
    static let checksGolden = [
        "exactly 1 CMS signer",
        "the CMS signature and content digest are valid (kCMSSignerValid)",
        "a secure timestamp countersignature from a trusted timestamp authority; none refuses",
        "the signing time taken only from that countersignature",
        "the chain evaluated at the signing time with the Apple code-signing policy, revocation included",
        "anchor apple generic",
        "certificate 1 carries 1.2.840.113635.100.6.2.6",
        "the leaf carries 1.2.840.113635.100.6.1.13",
        "the leaf extended key usage includes 1.3.6.1.5.5.7.3.3",
        "the leaf subject OU equals ABCDE12345",
        "the chain is exactly 3 certificates: leaf, intermediate, root",
        "the signed content carries the context string io.k3sm.release-index/v1",
    ]

    /// Compiles `text` with the Security framework's requirement parser, the
    /// one `codesign -R` and `SecStaticCodeCheckValidity` use.
    static func compiles(_ text: String) -> Bool {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
            && requirement != nil
    }

    @Test("the app update requirement and index signer are the ruled text")
    func appUpdateRequirementGolden() throws {
        // The Team ID reaches the requirement only through the compiled pin:
        // a developer build has none, so it authorizes nothing.
        #expect(TeamIDPin.teamID == nil)
        #expect(AppUpdateTrust.pinnedAppRequirement == nil)
        #expect(AppUpdateTrust.pinnedIndexSigner == nil)

        // A release stamp, read the way the stamped binary reads it.
        let pinned = try #require(TeamIDPin.parse(TeamIDPin.marker + "ABCDE12345"))
        #expect(pinned == Self.team)

        let app = AppUpdateTrust.appRequirement(teamID: pinned)
        #expect(app == Self.appGolden)
        #expect(app.hasPrefix(DesignatedRequirement.developerID(teamID: pinned)))
        #expect(AppUpdateTrust.bundleIdentifier == "io.k3sm.app")

        let helper = AppUpdateTrust.helperRequirement(teamID: pinned)
        #expect(helper == Self.helperGolden)
        #expect(helper.hasPrefix(DesignatedRequirement.developerID(teamID: pinned)))
        #expect(AppUpdateTrust.helperIdentifier == "io.k3sm.app.update")
        #expect(!helper.contains("notarized"))
        #expect(Self.compiles(helper))

        let signer = AppUpdateTrust.indexSigner(teamID: pinned)
        #expect(signer.teamID == pinned)
        #expect(signer.requirement == Self.indexGolden)
        #expect(signer.requirement == DesignatedRequirement.developerID(teamID: pinned))
        #expect(signer.checks == Self.checksGolden)
        #expect(IndexSignerPolicy.signerCount == 1)
        #expect(IndexSignerPolicy.chainLength == 3)
        #expect(IndexSignerPolicy.contextString == "io.k3sm.release-index/v1")
        #expect(signer.checks.count == Set(signer.checks).count)
        #expect(signer.checks.last == "the signed content carries the context string io.k3sm.release-index/v1")
        #expect(IndexSignerPolicy.codeSigningUsageOID == "1.3.6.1.5.5.7.3.3")

        // The policy's OIDs are the ones the requirement text checks, in the
        // clause each belongs to.
        #expect(app.contains("certificate 1[field.\(IndexSignerPolicy.intermediateMarkerOID)]"))
        #expect(app.contains("certificate leaf[field.\(IndexSignerPolicy.leafMarkerOID)]"))

        // Both texts are valid requirement language.
        #expect(Self.compiles(app))
        #expect(Self.compiles(signer.requirement))

        // Another team gives another OU and nothing else.
        let other = try #require(TeamID("ZYXWV98765"))
        #expect(AppUpdateTrust.appRequirement(teamID: other)
            == Self.appGolden.replacingOccurrences(of: "ABCDE12345", with: "ZYXWV98765"))
    }

    /// Every clause is load-bearing: dropping or changing any one of them
    /// gives a text that is not the ruled one.
    @Test("each clause of the golden is present exactly once", arguments: [
        "anchor apple generic",
        " and certificate 1[field.1.2.840.113635.100.6.2.6]",
        " and certificate leaf[field.1.2.840.113635.100.6.1.13]",
        #" and certificate leaf[subject.OU] = "ABCDE12345""#,
        #" and identifier "io.k3sm.app""#,
        " and notarized",
    ])
    func clause(_ clause: String) {
        let app = AppUpdateTrust.appRequirement(teamID: Self.team)
        #expect(app.components(separatedBy: clause).count == 2, "\(clause) is not in the requirement once")
        #expect(app.replacingOccurrences(of: clause, with: "") != Self.appGolden)
    }

    @Test("each clause of the helper golden is present exactly once", arguments: [
        "anchor apple generic",
        " and certificate 1[field.1.2.840.113635.100.6.2.6]",
        " and certificate leaf[field.1.2.840.113635.100.6.1.13]",
        #" and certificate leaf[subject.OU] = "ABCDE12345""#,
        #" and identifier "io.k3sm.app.update""#,
    ])
    func helperClause(_ clause: String) {
        let helper = AppUpdateTrust.helperRequirement(teamID: Self.team)
        #expect(helper.components(separatedBy: clause).count == 2, "\(clause) is not in the requirement once")
        #expect(helper.replacingOccurrences(of: clause, with: "") != Self.helperGolden)
    }

    @Test("only the same team may replace the app", arguments: [
        ("ABCDE12345", "ABCDE12345", true),
        ("ABCDE12345", "ZYXWV98765", false),
        ("ABCDE12345", nil, false),
        (nil, "ABCDE12345", false),
        (nil, nil, false),
    ] as [(String?, String?, Bool)])
    func replacement(_ running: String?, _ staged: String?, _ want: Bool) {
        let got = AppUpdateTrust.authorizesReplacement(
            running: running.flatMap(TeamID.init), staged: staged.flatMap(TeamID.init))
        #expect(got == want)
    }
}
