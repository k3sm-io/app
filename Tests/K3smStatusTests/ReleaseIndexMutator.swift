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
#if !RELEASE_INDEX_DIFFERENTIAL
    import K3smStatus
#endif

// Foundation only and no test framework: hack/release-index-differential.sh
// compiles this file into the decoder's module (with
// RELEASE_INDEX_DIFFERENTIAL defined) to run the same mutants through k3sm's
// Go decoder.

/// SplitMix64: a small, fixed pseudo-random sequence, so a seed always yields
/// the same mutants.
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

    /// A value in 0..<n; n must be positive.
    mutating func below(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }
}

/// ReleaseIndexMutator derives mutants of a release index: each is one to
/// four edits of the base, a bit flip, an insertion of `\u`, `{`, `[` or a
/// digit, or a truncation.
enum ReleaseIndexMutator {
    static let insertions: [[UInt8]] =
        [Array(#"\u"#.utf8), Array("{".utf8), Array("[".utf8)] + (0...9).map { [UInt8(ascii: "0") + UInt8($0)] }

    static func mutants(of base: [UInt8], count: Int, seed: UInt64) -> [[UInt8]] {
        var rng = SplitMix64(seed: seed)
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            var m = base
            for _ in 0..<(1 + rng.below(4)) {
                switch rng.below(20) {
                case 0..<9:
                    guard !m.isEmpty else { continue }
                    m[rng.below(m.count)] ^= UInt8(1) << UInt8(rng.below(8))
                case 9..<18:
                    m.insert(contentsOf: insertions[rng.below(insertions.count)], at: rng.below(m.count + 1))
                default:
                    m.removeSubrange(rng.below(m.count + 1)...)
                }
            }
            out.append(m)
        }
        return out
    }

    /// One line per mutant for the differential check: `accept` and every
    /// field, tab-separated, or `refuse`. k3sm's checker prints the same.
    static func verdict(_ raw: [UInt8]) -> String {
        guard let ix = try? ReleaseIndex.parse(Data(raw)) else { return "refuse" }
        return ["accept", ix.schema, ix.context, ix.issuedAt, ix.tag, ix.minimumMacOS,
                ix.minimumSupportedTag,
                ix.app.bundleID, ix.app.shortVersion, ix.app.image.name, ix.app.image.url,
                ix.app.image.sha256, String(ix.app.image.size),
                ix.k3sm.archive, ix.k3sm.archiveSHA256, ix.k3sm.payloadManifestSHA256].joined(separator: "\t")
    }
}
