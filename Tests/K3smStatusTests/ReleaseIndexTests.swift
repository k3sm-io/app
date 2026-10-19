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

/// The vendored copy of k3sm's pkg/update/testdata/release-index: the golden
/// document, the host pin list and the refusal corpus, byte for byte, with a
/// SHA256SUMS manifest. hack/ci.sh compares the directory with k3sm's.
private func releaseIndexDirectory() throws -> URL {
    guard let url = Bundle.module.url(forResource: "release-index", withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureError.missing("release-index")
    }
    return url
}

private func releaseIndexFixture(_ name: String) throws -> Data {
    try Data(contentsOf: releaseIndexDirectory().appendingPathComponent(name))
}

private func golden() throws -> String {
    String(decoding: try releaseIndexFixture("index.json"), as: UTF8.self)
}

/// One change to the golden text; it fails when `from` is absent, so a stale
/// case cannot pass vacuously.
private func replacing(_ from: String, _ to: String, in text: String) throws -> String {
    guard text.contains(from) else { throw FixtureError.missing("the mutation \(from.debugDescription) matched nothing") }
    guard let range = text.range(of: from) else { throw FixtureError.missing(from) }
    return text.replacingCharacters(in: range, with: to)
}

/// Replaces the text from `start` up to (not including) `end` with `with`.
private func between(_ start: String, _ end: String, in text: String, with: String) throws -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
        throw FixtureError.missing("\(start)...\(end)")
    }
    return text.replacingCharacters(in: a.lowerBound..<b.lowerBound, with: with)
}

@Suite("release index")
struct ReleaseIndexTests {
    /// The reason k3sm's corpus names for each vendored red file
    /// (releaseIndexReds in pkg/update/releaseindex_test.go). Its keys must be
    /// exactly the vendored red files.
    static let redReasons: [String: String] = [
        "red-unknown-field.json": #"unknown key "channel""#,
        "red-case-variant-key.json": #"unknown key "Tag""#,
        "red-case-variant-duplicate.json": #"unknown key "TAG""#,
        "red-case-variant-nested-key.json": #"unknown key "bundleId""#,
        "red-duplicate-key.json": #"duplicate key "tag""#,
        "red-duplicate-nested-sha256.json": #"duplicate key "sha256""#,
        "red-array-value.json": "holds an array",
        "red-not-an-object.json": "not a JSON object",
        "red-null-document.json": "not a JSON object",
        "red-trailing-garbage.json": "trailing data",
        "red-trailing-brace.json": "trailing data",
        "red-second-value.json": "trailing data",
        "red-truncated.json": "not a valid document",
        "red-schema-v2.json": "schema is not",
        "red-other-context.json": "context is not",
        "red-no-context.json": "context is not",
        "red-rc-tag.json": "not a final release tag",
        "red-build-metadata-tag.json": "not a final release tag",
        "red-tag-without-v.json": "not a final release tag",
        "red-tag-leading-zero.json": "not a final release tag",
        "red-issued-at-offset.json": "issuedAt is not",
        "red-issued-at-fractional.json": "issuedAt is not",
        "red-issued-at-impossible-date.json": "issuedAt is not",
        "red-minimum-macos-word.json": "minimumMacOS is not",
        "red-minimum-macos-four-parts.json": "minimumMacOS is not",
        "red-other-bundle-id.json": "bundleID is not",
        "red-short-version-mismatch.json": "shortVersion is not",
        "red-image-name-mismatch.json": "image name is not",
        "red-foreign-host.json": "image url is not",
        "red-redirect-host-as-url.json": "image url is not",
        "red-uppercase-host.json": "image url is not",
        "red-foreign-repo.json": "image url is not",
        "red-url-other-tag.json": "image url is not",
        "red-url-dot-dot.json": "image url is not",
        "red-url-port-443.json": "image url is not",
        "red-url-empty-port.json": "image url is not",
        "red-url-http.json": "image url is not",
        "red-url-user.json": "image url is not",
        "red-url-query.json": "image url is not",
        "red-url-fragment.json": "image url is not",
        "red-url-other-asset.json": "image url is not",
        "red-image-sha-too-long.json": "image sha256 is not",
        "red-image-sha-uppercase.json": "image sha256 is not",
        "red-image-zero-size.json": "image size 0 is outside",
        "red-image-negative-size.json": "image size -1 is outside",
        "red-image-oversized.json": "image size 536870913 is outside",
        "red-archive-mismatch.json": "archive is not",
        "red-archive-sha-short.json": "archiveSHA256 is not",
        "red-payload-manifest-missing.json": "payloadManifestSHA256 is not",
    ]

    /// The golden decodes to k3sm's values; every vendored red file is
    /// refused for k3sm's reason; the reason table covers exactly the
    /// vendored reds; every vendored file matches the manifest, which lists
    /// exactly the directory; the byte cap holds at k3sm's boundary; and the
    /// host pins equal k3sm's.
    @Test func releaseIndexDecodesK3smGolden() throws {
        let ix = try ReleaseIndex.parse(try releaseIndexFixture("index.json"))
        #expect(ix.schema == "k3sm-release-index/v1")
        #expect(ix.context == "io.k3sm.release-index/v1")
        #expect(ix.issuedAt == "2026-11-02T18:04:11Z")
        #expect(ix.tag == "v0.2.0")
        #expect(ix.version == SemanticVersion("0.2.0"))
        #expect(ix.version.prerelease.isEmpty)
        #expect(ix.minimumMacOS == "26.0")
        #expect(ix.app.bundleID == "io.k3sm.app")
        #expect(ix.app.shortVersion == "0.2.0")
        #expect(ix.app.image.name == "k3sm_0.2.0_darwin_arm64.dmg")
        #expect(ix.app.image.url == "https://github.com/k3sm-io/k3sm/releases/download/v0.2.0/k3sm_0.2.0_darwin_arm64.dmg")
        #expect(ix.app.image.url == ReleaseIndex.downloadURL(tag: ix.tag, name: ix.app.image.name))
        #expect(ix.app.image.sha256 == "6105d6cc76af400325e94d588ce511be5bfdbb73b437dc51eca43917d7a43e3d")
        #expect(ix.app.image.size == 123_456_789)
        #expect(ix.k3sm.archive == "k3sm_0.2.0_darwin_arm64.tar.gz")
        #expect(ix.k3sm.archiveSHA256 == "0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3")
        #expect(ix.k3sm.payloadManifestSHA256 == "05b3abf2579a5eb66403cd78be557fd860633a1fe2103c7642030defe32c657f")

        let files = try FileManager.default.contentsOfDirectory(atPath: releaseIndexDirectory().path)
        let reds = Set(files.filter { $0.hasPrefix("red-") && $0.hasSuffix(".json") })
        #expect(reds.count == 49)
        #expect(reds == Set(Self.redReasons.keys), "the reason table and the vendored reds differ")
        for name in reds.sorted() {
            let raw = try releaseIndexFixture(name)
            do {
                let accepted = try ReleaseIndex.parse(raw)
                Issue.record("\(name) was accepted as \(accepted)")
            } catch {
                let reason = Self.redReasons[name] ?? "<no reason>"
                #expect(error.description.contains(reason), "\(name): got \(error), want \(reason)")
            }
        }

        // The manifest names every vendored file, and only those, and each
        // file's sha256 matches it.
        let manifest = String(decoding: try releaseIndexFixture("SHA256SUMS"), as: UTF8.self)
        var listed: [String: String] = [:]
        for line in manifest.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            #expect(fields.count == 2, "a manifest line is not <sha256>  <name>: \(line)")
            guard fields.count == 2 else { continue }
            listed[String(fields[1])] = String(fields[0])
        }
        #expect(Set(listed.keys) == Set(files).subtracting(["SHA256SUMS"]), "the manifest and the directory differ")
        for (name, want) in listed.sorted(by: { $0.key < $1.key }) {
            let got = SHA256.hash(data: try releaseIndexFixture(name)).map { String(format: "%02x", $0) }.joined()
            #expect(got == want, "\(name) does not match SHA256SUMS; re-copy it from k3sm")
        }

        // The byte cap: a valid document padded to exactly 65536 bytes
        // decodes; one byte more is refused on size, and so is garbage that
        // would otherwise fail to parse.
        let gold = try releaseIndexFixture("index.json")
        let atCap = Data(repeating: 0x20, count: ReleaseIndex.maxBytes - gold.count) + gold
        #expect(atCap.count == 65536)
        #expect(try ReleaseIndex.parse(atCap) == ix)
        #expect(throws: ReleaseIndexError.tooLarge(65537)) { try ReleaseIndex.parse(Data([0x20]) + atCap) }
        #expect(throws: ReleaseIndexError.tooLarge(65537)) { try ReleaseIndex.parse(Data(repeating: 0xFF, count: 65537)) }

        let hosts = try JSONSerialization.jsonObject(with: try releaseIndexFixture("allowed-hosts.json")) as? [String]
        #expect(hosts == ReleaseIndex.allowedHosts)
    }

    struct RedCase {
        let name: String
        let raw: Data
        let want: ReleaseIndexError
    }

    /// Refusals beyond k3sm's corpus: what a permissive JSON reader would let
    /// through on this side.
    static func swiftReds() throws -> [RedCase] {
        let text = try golden()
        let utf8 = Data(text.utf8)
        func red(_ name: String, _ from: String, _ to: String, _ want: ReleaseIndexError) throws -> RedCase {
            RedCase(name: name, raw: Data(try replacing(from, to, in: text).utf8), want: want)
        }
        func bytes(_ name: String, _ from: String, _ insert: [UInt8], _ want: ReleaseIndexError) throws -> RedCase {
            guard let range = utf8.range(of: Data(from.utf8)) else { throw FixtureError.missing(from) }
            var raw = utf8
            raw.insert(contentsOf: insert, at: range.upperBound)
            return RedCase(name: name, raw: raw, want: want)
        }
        let notUTF8 = ReleaseIndexError.invalidDocument("a string is not valid UTF-8")
        let lone = ReleaseIndexError.invalidDocument("a lone surrogate escape")
        return [
            RedCase(name: "byte order mark", raw: Data([0xEF, 0xBB, 0xBF]) + utf8,
                    want: .invalidDocument("want a value")),
            RedCase(name: "UTF-16 with a byte order mark", raw: text.data(using: .utf16) ?? Data(),
                    want: .invalidDocument("want a value")),
            RedCase(name: "UTF-16LE", raw: text.data(using: .utf16LittleEndian) ?? Data(),
                    want: .invalidDocument("want a key")),
            RedCase(name: "UTF-32BE", raw: text.data(using: .utf32BigEndian) ?? Data(),
                    want: .invalidDocument("want a value")),
            RedCase(name: "empty", raw: Data(), want: .invalidDocument("no JSON value")),
            RedCase(name: "whitespace only", raw: Data(" \n".utf8), want: .invalidDocument("no JSON value")),
            try bytes("invalid UTF-8 in a value", #""sha256": ""#, [0xFF], notUTF8),
            try bytes("invalid UTF-8 in a key", #""t"#, [0xC0, 0xAF], notUTF8),
            try bytes("UTF-8 encoded surrogate in a value", #""shortVersion": ""#, [0xED, 0xA0, 0x80], notUTF8),
            try bytes("raw tab in a string", #""tag": "v0.2.0"#, [0x09], .invalidDocument("a control character in a string")),
            try bytes("raw NUL in a key", #""t"#, [0x00], .invalidDocument("a control character in a string")),
            try red("form feed between tokens", #""tag": "#, "\"tag\":\u{0C} ", .invalidDocument("want a value")),
            try red("vertical tab between tokens", "\n  \"tag\"", "\u{0B}\n  \"tag\"", .invalidDocument("want a key")),
            try red("non-breaking space between tokens", #""tag": "#, "\"tag\":\u{A0}", .invalidDocument("want a value")),
            try red("size 1.0", "123456789", "1.0", .invalidDocument(#"key "size" is not an integer"#)),
            try red("size with a fraction", "123456789", "123456789.0", .invalidDocument(#"key "size" is not an integer"#)),
            try red("size 1e3", "123456789", "1e3", .invalidDocument(#"key "size" is not an integer"#)),
            try red("size 1E+3", "123456789", "1E+3", .invalidDocument(#"key "size" is not an integer"#)),
            try red("size as a string", "123456789", #""1""#, .invalidDocument(#"key "size" is not an integer"#)),
            try red("size over Int64", "123456789", "9223372036854775808", .invalidDocument(#"key "size" is not an integer"#)),
            try red("size with a leading zero", "123456789", "0123", .invalidDocument("want ',' or '}'")),
            try red("size with a plus sign", "123456789", "+1", .invalidDocument("want a value")),
            try red("size -0", "123456789", "-0", .imageSize(0)),
            try red("size true", "123456789", "true", .invalidDocument(#"key "size" is not an integer"#)),
            try red("tag null", #""tag": "v0.2.0""#, #""tag": null"#, .invalidDocument(#"key "tag" is not a string"#)),
            try red("tag a number", #""tag": "v0.2.0""#, #""tag": 2"#, .invalidDocument(#"key "tag" is not a string"#)),
            try red("tag an empty object", #""tag": "v0.2.0""#, #""tag": {}"#, .invalidDocument(#"key "tag" is not a string"#)),
            try red("a key inside a scalar's object", #""tag": "v0.2.0""#, #""tag": {"x": 1}"#, .unknownKey("x")),
            // An unknown key is found before a value of the wrong type, as in k3sm.
            try red("app null, then an unknown key", #""app": {"#, #""app": null, "x": {"#, .unknownKey("x")),
            RedCase(name: "app null", raw: Data(try between(#""app": {"#, "\n  \"k3sm\"", in: text, with: "\"app\": null,").utf8),
                    want: .invalidDocument(#"key "app" is not an object"#)),
            RedCase(name: "k3sm a string", raw: Data(try between(#""k3sm": {"#, "\n}\n", in: text, with: #""k3sm": "x""#).utf8),
                    want: .invalidDocument(#"key "k3sm" is not an object"#)),
            try red("seconds 60", "18:04:11Z", "23:59:60Z", .issuedAt),
            try red("hour 24", "18:04:11Z", "24:00:00Z", .issuedAt),
            try red("lowercase t", "2026-11-02T18", "2026-11-02t18", .issuedAt),
            try red("lowercase z", "18:04:11Z", "18:04:11z", .issuedAt),
            try red("not a leap year", "2026-11-02", "2026-02-29", .issuedAt),
            try red("fullwidth digit in the tag", #""tag": "v0.2.0""#, "\"tag\": \"v０.2.0\"", .tag),
            try red("lone high surrogate in a key", #""tag""#, #""\uD800tag""#, lone),
            try red("lone low surrogate in a key", #""tag""#, #""\uDC00tag""#, lone),
            try red("high surrogate before a non-surrogate", #""tag""#, #""\uD800tag""#, lone),
            try red("tag and its escaped twin", #""tag": "v0.2.0","#, #""tag": "v0.2.0", "tag": "v0.2.0","#, .duplicateKey("tag")),
            try red("escaped case variant", #""tag""#, #""Tag""#, .unknownKey("Tag")),
            try red("unknown escape", #""tag""#, #""\qtag""#, .invalidDocument("want a valid escape")),
            try red("short unicode escape", #""tag""#, #""\u07""#, .invalidDocument("want four hex digits")),
            try red("a single-quoted key", #""tag""#, "'tag'", .invalidDocument("want a key")),
            try red("a trailing comma", "\n  }\n}", ",\n  }\n}", .invalidDocument("want a key")),
            try red("an array nested in an unknown place", #""minimumMacOS": "26.0""#, #""minimumMacOS": [[["26.0"]]]"#, .arrayValue("minimumMacOS")),
            RedCase(name: "a top-level string", raw: Data(#""x""#.utf8), want: .notAnObject),
            RedCase(name: "a top-level array of objects", raw: Data("[\(text)]".utf8), want: .notAnObject),
            RedCase(name: "a top-level garbage word", raw: Data("garbage".utf8), want: .invalidDocument("want a value")),
        ]
    }

    /// Each case is refused for its reason. A syntax refusal (`want ...`)
    /// is matched without its byte offset; every other refusal exactly. The
    /// cases run in one test, not as arguments, to keep the test log short.
    @Test func swiftSpecificRefusals() throws {
        for c in try Self.swiftReds() {
            do {
                let accepted = try ReleaseIndex.parse(c.raw)
                Issue.record("\(c.name): accepted as \(accepted)")
            } catch {
                if case .invalidDocument(let want) = c.want, want.hasPrefix("want ") {
                    guard case .invalidDocument(let got) = error else {
                        Issue.record("\(c.name): got \(error), want \(c.want)")
                        continue
                    }
                    #expect(got.hasPrefix(want + " at offset ") || got.hasSuffix(", " + want), "\(c.name): got \(error), want \(c.want)")
                } else {
                    #expect(error == c.want, "\(c.name)")
                }
            }
        }
    }

    struct AcceptCase {
        let name: String
        let raw: Data
    }

    /// Spellings k3sm's decoder accepts as the same document; this side must
    /// too, and decode them to the golden's value.
    static func accepted() throws -> [AcceptCase] {
        let text = try golden()
        func ok(_ name: String, _ from: String, _ to: String) throws -> AcceptCase {
            AcceptCase(name: name, raw: Data(try replacing(from, to, in: text).utf8))
        }
        let reordered = try replacing("{\n", "{\n  \"tag\": \"v0.2.0\",\n", in: try replacing("  \"tag\": \"v0.2.0\",\n", "", in: text))
        let nestedFirst = try replacing("{\n  \"schema\"", "{\n  \"k3sm\": {\"payloadManifestSHA256\": \"05b3abf2579a5eb66403cd78be557fd860633a1fe2103c7642030defe32c657f\", \"archiveSHA256\": \"0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3\", \"archive\": \"k3sm_0.2.0_darwin_arm64.tar.gz\"},\n  \"schema\"",
                                      in: String(text[..<(text.range(of: ",\n  \"k3sm\"")?.lowerBound ?? text.endIndex)]) + "\n}\n")
        let compact = String(text.filter { $0 != " " && $0 != "\n" })
        return [
            AcceptCase(name: "keys in another order", raw: Data(reordered.utf8)),
            AcceptCase(name: "a nested object first, its keys reversed", raw: Data(nestedFirst.utf8)),
            AcceptCase(name: "no whitespace", raw: Data(compact.utf8)),
            AcceptCase(name: "CRLF, tabs and surrounding whitespace", raw: Data(("\r\n\t " + text.replacingOccurrences(of: "\n", with: "\r\n") + "\t\r\n ").utf8)),
            try ok("an escaped exact key", #""tag""#, #""tag""#),
            try ok("an escaped exact nested key", #""sha256""#, #""sha256""#),
            try ok("an escaped slash in the url", "https://github.com/k3sm-io/k3sm/releases/download/v0.2.0/", #"https:\/\/github.com\/k3sm-io\/k3sm\/releases\/download\/v0.2.0\/"#),
            try ok("a unicode escape in a value", #""io.k3sm.app""#, #""io.k3sm.app""#),
            try ok("an uppercase unicode escape in a value", #""k3sm-release-index/v1""#, #""k3sm-release-index/v1""#),
        ]
    }

    @Test func goAcceptedVariants() throws {
        let want = try ReleaseIndex.parse(try releaseIndexFixture("index.json"))
        for c in try Self.accepted() {
            do {
                #expect(try ReleaseIndex.parse(c.raw) == want, "\(c.name)")
            } catch {
                Issue.record("\(c.name): refused: \(error)")
            }
        }
    }

    struct MacOSCase {
        let minimum: String
        let macOS: [Int]
        let want: ReleaseIndex.MacOSSupport
        var testDescription: String { "\(minimum) on \(macOS)" }
    }

    static let macOSCases: [MacOSCase] = [
        MacOSCase(minimum: "26.0", macOS: [26, 0, 0], want: .supported),
        MacOSCase(minimum: "26.0", macOS: [27, 0, 0], want: .supported),
        MacOSCase(minimum: "26.0", macOS: [25, 9, 9], want: .requiresNewer("26.0")),
        MacOSCase(minimum: "26.1", macOS: [26, 0, 5], want: .requiresNewer("26.1")),
        MacOSCase(minimum: "26.1", macOS: [26, 1, 0], want: .supported),
        MacOSCase(minimum: "26", macOS: [26, 0, 0], want: .supported),
        MacOSCase(minimum: "26", macOS: [25, 99, 0], want: .requiresNewer("26")),
        MacOSCase(minimum: "26.1.2", macOS: [26, 1, 1], want: .requiresNewer("26.1.2")),
        MacOSCase(minimum: "26.1.2", macOS: [26, 1, 2], want: .supported),
        MacOSCase(minimum: "26.1.2", macOS: [26, 2, 0], want: .supported),
        MacOSCase(minimum: "100", macOS: [27, 0, 0], want: .requiresNewer("100")),
    ]

    @Test func supportsMacOS() throws {
        for c in Self.macOSCases {
            let raw = try replacing(#""minimumMacOS": "26.0""#, "\"minimumMacOS\": \"\(c.minimum)\"", in: try golden())
            let ix = try ReleaseIndex.parse(Data(raw.utf8))
            let v = OperatingSystemVersion(majorVersion: c.macOS[0], minorVersion: c.macOS[1], patchVersion: c.macOS[2])
            #expect(ix.supports(macOS: v) == c.want, "\(c.testDescription)")
        }
    }
}
