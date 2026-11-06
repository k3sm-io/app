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

@testable import K3smHost
@testable import K3smInstall
import K3smStatus

/// Answers every fetch with one file's bytes, whatever is asked.
private struct FixedFetcher: AppIndexFetcher {
    let bytes: Data
    func fetch(_ request: URLRequest) async throws -> Data { bytes }
}

/// The signature step run for real, under a test-only signer root. The documents
/// and the root are TEST ONLY (`hack/release-index-cms/make-kind-fixtures.sh`):
/// a throwaway chain shaped like a Developer ID one, with a real timestamp from
/// Apple's public service, because the system's decoder trusts no other.
///
/// The root reaches the verifier only through its internal test initializer,
/// which `@testable` opens in a test build. `pinned` cannot name it, and
/// `shippedRootsRefuseTheTestOnlySigner` shows the shipped roots refuse the chain.
@Suite("signed documents through the shipped wiring")
struct SignedDocumentKindTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("K3smInstallTests/Fixtures/test-only-signed-kinds")
    static let candidateTag = "v0.3.0-rc.2"
    static let candidate = ReleaseIndexKind.candidate(tag: candidateTag)
    static let own = AppUpdateOwn(tag: "v0.1.0", pinned: true)
    static let policy = IndexSignerPolicy(teamID: TeamID("ABCDE12345")!)

    static func file(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The test-only root for the signer; Apple's roots for the timestamp, as
    /// the shipped verifier holds them.
    static func verifier() throws -> ReleaseIndexVerifier {
        let root = try #require(SecCertificateCreateWithData(nil, try file("test-only-root.cer") as CFData))
        let apple = ReleaseIndexVerifier.appleRoots().compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        return ReleaseIndexVerifier(policy: policy, anchors: [root], timestampAnchors: apple, clock: { Date() })
    }

    /// One check through the closure `AppUpdateChecker.pinned` builds.
    static func check(_ name: String, as kind: ReleaseIndexKind) async throws -> AppUpdateChecker.Outcome {
        let checker = AppUpdateChecker.checker(fetcher: FixedFetcher(bytes: try file(name)), verifier: try verifier())
        return await checker.check(.user, checksOn: false, own: own, firstRun: false, kind: kind,
                                   record: AppUpdateRecord(), candidateRecord: AppUpdateCandidateRecord())
    }

    static func refusal(_ error: ReleaseIndexVerifierError) -> AppUpdateChecker.Outcome {
        .init(result: .failed(String(describing: error)), record: AppUpdateRecord(), candidateRecord: AppUpdateCandidateRecord())
    }

    /// One identity signs both documents, so only the kind keeps them apart:
    /// each is accepted under its own kind and refused under the other, and a
    /// refusal moves neither floor.
    @Test func signedDocumentsAcceptedOnlyUnderTheirKind() async throws {
        let candidateP7M = try Self.file("test-only-candidate.p7m")
        let stableP7M = try Self.file("test-only-stable.p7m")
        let verifier = try Self.verifier()

        // The verifier itself, end to end.
        let acceptedCandidate = try verifier.verified(p7m: candidateP7M, expected: Self.candidate)
        #expect(acceptedCandidate.index.tag == Self.candidateTag)
        let acceptedStable = try verifier.verified(p7m: stableP7M, expected: .stable)
        #expect(acceptedStable.index.tag == "v0.2.0")
        #expect(throws: ReleaseIndexVerifierError.index(.schema)) { try verifier.verified(p7m: candidateP7M, expected: .stable) }
        #expect(throws: ReleaseIndexVerifierError.index(.candidateSchema)) { try verifier.verified(p7m: stableP7M, expected: Self.candidate) }

        // The same documents through the closure, down to the stored floors.
        let candidate = try await Self.check("test-only-candidate.p7m", as: Self.candidate)
        let candidateLatest = try #require(AppUpdateLatest(index: acceptedCandidate.index))
        #expect(candidate == .init(result: .verified(candidateLatest), record: AppUpdateRecord(),
                                   candidateRecord: AppUpdateCandidateRecord(highTag: Self.candidateTag, highIssuedAt: acceptedCandidate.index.issuedAt)))
        let stable = try await Self.check("test-only-stable.p7m", as: .stable)
        let stableLatest = try #require(AppUpdateLatest(index: acceptedStable.index))
        #expect(stable == .init(result: .verified(stableLatest), record: AppUpdateRecord(highTag: "v0.2.0", highIssuedAt: acceptedStable.index.issuedAt),
                                candidateRecord: AppUpdateCandidateRecord()))

        #expect(try await Self.check("test-only-candidate.p7m", as: .stable) == Self.refusal(.index(.schema)))
        #expect(try await Self.check("test-only-stable.p7m", as: Self.candidate) == Self.refusal(.index(.candidateSchema)))
        // A candidate signed for one tag is refused for another.
        #expect(try await Self.check("test-only-candidate.p7m", as: .candidate(tag: "v0.3.0-rc.3"))
            == Self.refusal(.index(.requestedTag(Self.candidateTag, "v0.3.0-rc.3"))))
    }

    /// The confinement: under the Apple roots `pinned` uses, these documents are
    /// refused at the signer chain, whichever kind is asked for. The policy here
    /// is the fixture's team, so only the root can be what refuses them.
    @Test func shippedRootsRefuseTheTestOnlySigner() throws {
        let apple = ReleaseIndexVerifier.appleRoots().compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        #expect(!apple.isEmpty)
        let shipped = ReleaseIndexVerifier(policy: Self.policy, anchors: apple, timestampAnchors: apple, clock: { Date() })
        for (name, kind) in [("test-only-candidate.p7m", Self.candidate), ("test-only-stable.p7m", ReleaseIndexKind.stable)] {
            do {
                _ = try shipped.verified(p7m: try Self.file(name), expected: kind)
                Issue.record("\(name) was accepted under the Apple roots")
            } catch let error {
                guard case .chainUntrusted = error as? ReleaseIndexVerifierError else {
                    Issue.record("\(name) refused for \(error), not at the chain")
                    continue
                }
            }
        }
    }
}
