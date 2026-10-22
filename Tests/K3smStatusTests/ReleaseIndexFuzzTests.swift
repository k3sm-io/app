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

@Suite("release index fuzz")
struct ReleaseIndexFuzzTests {
    /// The fixed seed and count: the same mutants on every run.
    static let seed: UInt64 = 0x6B33_736D_5249_4458
    static let count = 5000
    /// Each parse of a mutant (at most a few hundred bytes over the golden)
    /// takes microseconds; the bound only has to catch a runaway, under load.
    static let perCallBound = Duration.seconds(1)

    /// Seeded mutants of the golden index: bit flips, truncations, and
    /// insertions of `\u`, `{`, `[` and digits. For every one, parse returns
    /// or throws (a trap would end the test process), each call finishes
    /// within the bound, and the same bytes give the same verdict twice. An
    /// accepted mutant re-parses to an equal value, and so does its
    /// re-encoding with Foundation's encoder. The cases loop inside one test
    /// so the test log stays one line.
    @Test func mutantsOfTheGoldenNeverTrapOrHang() throws {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "json", subdirectory: "Fixtures/release-index") else {
            throw FixtureError.missing("release-index/index.json")
        }
        let golden = Array(try Data(contentsOf: url))
        let mutants = ReleaseIndexMutator.mutants(of: golden, count: Self.count, seed: Self.seed)
        #expect(mutants.count == Self.count)
        #expect(Set(mutants).count > Self.count / 2, "the mutants are not varied")
        let clock = ContinuousClock()
        var accepted = 0
        var reasons: Set<String> = []
        for (i, mutant) in mutants.enumerated() {
            let raw = Data(mutant)
            var first: Result<ReleaseIndex, ReleaseIndexError>!
            let elapsed = clock.measure {
                first = Result { () throws(ReleaseIndexError) in try ReleaseIndex.parse(raw) }
            }
            #expect(elapsed < Self.perCallBound, "mutant \(i) took \(elapsed)")
            let second = Result { () throws(ReleaseIndexError) in try ReleaseIndex.parse(raw) }
            switch (first!, second) {
            case (.success(let a), .success(let b)):
                accepted += 1
                #expect(Self.sameBytes(a, b), "mutant \(i) re-parsed to another value")
                let again = try ReleaseIndex.parse(Self.reencode(a))
                #expect(Self.sameBytes(a, again), "mutant \(i) re-encoded to another value")
            case (.failure(let a), .failure(let b)):
                #expect(a == b, "mutant \(i) was refused for two reasons")
                reasons.insert(String(String(describing: a).prefix(24)))
            default:
                Issue.record("mutant \(i) was accepted once and refused once")
            }
        }
        // Non-vacuous: some mutants survive (a flipped digest digit) and many
        // kinds of refusal are reached.
        #expect(accepted > 0)
        #expect(accepted < Self.count)
        #expect(reasons.count >= 10, "only \(reasons.count) kinds of refusal: \(reasons.sorted())")
    }

    /// The same mutants twice from the same seed, and other mutants from
    /// another: the corpus is fixed by the seed alone.
    @Test func theMutantsAreFixedBySeed() {
        let base = Array("{\"tag\": \"v0.2.0\"}".utf8)
        let a = ReleaseIndexMutator.mutants(of: base, count: 50, seed: 7)
        #expect(a == ReleaseIndexMutator.mutants(of: base, count: 50, seed: 7))
        #expect(a != ReleaseIndexMutator.mutants(of: base, count: 50, seed: 8))
    }

    /// Field-by-field byte equality, stricter than `==` on strings.
    static func sameBytes(_ a: ReleaseIndex, _ b: ReleaseIndex) -> Bool {
        Array(String(describing: a).utf8) == Array(String(describing: b).utf8)
    }

    /// The value written back as JSON by Foundation's encoder, keys sorted.
    static func reencode(_ ix: ReleaseIndex) throws -> Data {
        let doc: [String: Any] = [
            "schema": ix.schema, "context": ix.context, "issuedAt": ix.issuedAt, "tag": ix.tag,
            "minimumMacOS": ix.minimumMacOS, "minimumSupportedTag": ix.minimumSupportedTag,
            "app": [
                "bundleID": ix.app.bundleID, "shortVersion": ix.app.shortVersion,
                "image": ["name": ix.app.image.name, "url": ix.app.image.url,
                          "sha256": ix.app.image.sha256, "size": NSNumber(value: ix.app.image.size)] as [String: Any],
            ] as [String: Any],
            "k3sm": ["archive": ix.k3sm.archive, "archiveSHA256": ix.k3sm.archiveSHA256,
                     "payloadManifestSHA256": ix.k3sm.payloadManifestSHA256],
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }
}
