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

/// Keys, the schema, the context, the bundle identifier and the names are
/// compared on their UTF-8 bytes, as k3sm compares them, never with `==` on
/// `String`, which is canonical equivalence.
@Suite("release index byte comparison")
struct ReleaseIndexByteComparisonTests {
    static let kelvin = "\u{212A}"

    @Test func canonicalEquivalenceIsNotEquality() {
        // The premise: Swift's String == says these are equal.
        #expect(Self.kelvin == "K")
        #expect(!ReleaseIndex.same(Self.kelvin, "K"))
        #expect(ReleaseIndex.same("K", "K"))
    }

    private func scan(_ text: String, keys: KeyTree) throws(ReleaseIndexError) -> [JSONKey: JSONValue] {
        var scanner = StrictJSONScanner(Array(text.utf8))
        let doc = try scanner.document(keys: keys)
        try scanner.end()
        return doc
    }

    @Test func aKeySpelledWithACanonicallyEquivalentCharacterIsRefused() throws {
        let keys = KeyTree(["K": .scalar])
        _ = try scan(#"{"K": "x"}"#, keys: keys)
        // KELVIN SIGN raw and as an escape: unknown, never read as K.
        #expect(throws: ReleaseIndexError.unknownKey(Self.kelvin)) { try scan("{\"\(Self.kelvin)\": \"x\"}", keys: keys) }
        #expect(throws: ReleaseIndexError.unknownKey(Self.kelvin)) { try scan(#"{"K": "x"}"#, keys: keys) }
        // Beside K it is a second, unknown key, not a duplicate of K.
        #expect(throws: ReleaseIndexError.unknownKey(Self.kelvin)) { try scan(#"{"K": "x", "K": "y"}"#, keys: keys) }
        // A decomposed and a precomposed spelling are two keys.
        let e = KeyTree(["\u{E9}": .scalar])
        #expect(throws: ReleaseIndexError.unknownKey("e\u{301}")) { try scan(#"{"é": 1, "é": 2}"#, keys: e) }
    }

    @Test func schemaKeysAndFieldsAreHeldToTheirBytes() throws {
        let golden = String(decoding: try Data(contentsOf: try #require(
            Bundle.module.url(forResource: "index", withExtension: "json", subdirectory: "Fixtures/release-index"))), as: UTF8.self)
        func refused(_ from: String, _ to: String) -> ReleaseIndexError? {
            do {
                _ = try ReleaseIndex.parse(Data(golden.replacingOccurrences(of: from, with: to).utf8))
                return nil
            } catch {
                return error
            }
        }
        // A non-ASCII letter in a key, a combining mark or a zero-width
        // joiner after a value: each is a different key or value.
        #expect(refused(#""bundleID""#, "\"bundle\u{130}D\"") == .unknownKey("bundle\u{130}D"))
        #expect(refused("io.k3sm.app\"", "io.k3sm.app\u{301}\"") == .bundleID)
        #expect(refused("\"schema\": \"k3sm-release-index/v1\"", "\"schema\": \"k3sm-release-index/v1\u{200D}\"") == .schema)
        #expect(refused("k3sm_0.2.0_darwin_arm64.dmg\",", "k3sm_0.2.0_darwin_arm64.dmg\u{301}\",") == .imageName("0.2.0"))
    }
}
