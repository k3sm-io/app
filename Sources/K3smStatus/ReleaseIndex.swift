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

/// ReleaseIndex is one `k3sm-release-index/v1` document: the latest final
/// release and the version set it ships, the app's disk image and the k3sm
/// archive. k3sm owns the contract (`docs/design/release-index.md` and
/// `ParseReleaseIndex` in `pkg/update/releaseindex.go`); this decoder follows
/// it check for check, and its tests run k3sm's golden document and refusal
/// corpus, vendored byte for byte.
///
/// `parse` decodes content a signature check has already accepted. It never
/// verifies a signature, and it never clips a value into shape: anything
/// outside the grammar is refused.
public struct ReleaseIndex: Equatable, Sendable {
    /// The document format and its version.
    public static let schema = "k3sm-release-index/v1"
    /// The fixed domain-separation string inside the signed content. It
    /// equals k3sm's `ReleaseIndexContext` and the app's
    /// `IndexSignerPolicy.contextString` (a test holds the two together).
    public static let context = "io.k3sm.release-index/v1"
    /// The byte cap, checked before anything is read.
    public static let maxBytes = 65536
    /// The largest disk image an index may name, in bytes.
    public static let maxImageBytes: Int64 = 536_870_912
    /// The only bundle identifier an index may name.
    public static let bundleID = "io.k3sm.app"
    /// The hosts a release asset is fetched from, on the first request and on
    /// every redirect. The URL an index names is always on github.com
    /// (`downloadURL`); the others are where GitHub redirects that request.
    /// It equals k3sm's `AllowedHosts`.
    public static let allowedHosts = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// The one URL an index may name for a release asset: the k3sm-io/k3sm
    /// release download of `name` under `tag`, on github.com with no port.
    public static func downloadURL(tag: String, name: String) -> String {
        "https://github.com/k3sm-io/k3sm/releases/download/" + tag + "/" + name
    }

    /// The app half of the set.
    public struct App: Equatable, Sendable {
        /// `ReleaseIndex.bundleID`.
        public let bundleID: String
        /// The app's CFBundleShortVersionString: the tag without its v.
        public let shortVersion: String
        /// The signed, notarized disk image.
        public let image: Image
    }

    /// The app's disk image release asset.
    public struct Image: Equatable, Sendable {
        /// `k3sm_<version>_darwin_arm64.dmg`.
        public let name: String
        /// `downloadURL(tag:name:)`, exactly.
        public let url: String
        /// The image's lowercase hex sha256.
        public let sha256: String
        /// The image's size in bytes, 1 to `maxImageBytes`.
        public let size: Int64
    }

    /// The k3sm half of the set.
    public struct K3sm: Equatable, Sendable {
        /// `k3sm_<version>_darwin_arm64.tar.gz`.
        public let archive: String
        /// The archive's lowercase hex sha256.
        public let archiveSHA256: String
        /// The lowercase hex sha256 of the build set's PAYLOAD-SHA256 manifest.
        public let payloadManifestSHA256: String
    }

    /// `ReleaseIndex.schema`.
    public let schema: String
    /// `ReleaseIndex.context`.
    public let context: String
    /// When the release wrote the index: `YYYY-MM-DDTHH:MM:SSZ`, UTC.
    public let issuedAt: String
    /// The final release tag, `vMAJOR.MINOR.PATCH`.
    public let tag: String
    /// The tag as a version (never a pre-release).
    public let version: SemanticVersion
    /// The lowest macOS release the set runs on, `MAJOR[.MINOR[.PATCH]]`.
    public let minimumMacOS: String
    /// The app half of the set.
    public let app: App
    /// The k3sm half of the set.
    public let k3sm: K3sm

    /// Decodes one release index and checks every field, in k3sm's order: the
    /// byte cap before anything is read; then the one JSON object, refusing a
    /// key that is not a schema key at its place in exact case (compared after
    /// escapes are decoded), a key repeated in one object, any array, a value
    /// of the wrong type (`null` included), and anything after the object
    /// other than JSON whitespace; then the field grammar.
    public static func parse(_ raw: Data) throws(ReleaseIndexError) -> ReleaseIndex {
        if raw.count > maxBytes {
            throw .tooLarge(raw.count)
        }
        var scanner = StrictJSONScanner(Array(raw))
        let root = try scanner.document(keys: schemaKeys)
        let draft = try decode(root)
        try scanner.end()
        return draft.with(version: try draft.check())
    }

    /// The macOS check made before any download.
    public enum MacOSSupport: Equatable, Sendable {
        /// This macOS runs the release.
        case supported
        /// The release needs at least this macOS, as the index writes it.
        case requiresNewer(String)
    }

    /// Whether a Mac on `macOS` runs this release: a part `minimumMacOS`
    /// leaves out counts as 0.
    public func supports(macOS: OperatingSystemVersion) -> MacOSSupport {
        var parts = minimumMacOS.split(separator: ".").map { Int($0) ?? Int.max }
        while parts.count < 3 { parts.append(0) }
        let have = [macOS.majorVersion, macOS.minorVersion, macOS.patchVersion]
        return have.lexicographicallyPrecedes(parts) ? .requiresNewer(minimumMacOS) : .supported
    }
}

/// ReleaseIndexError is why a release index was refused. Each description
/// names k3sm's reason for the same refusal.
public enum ReleaseIndexError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The document is over `ReleaseIndex.maxBytes`.
    case tooLarge(Int)
    /// The bytes are not one well-formed JSON value, or a value has the
    /// wrong type; the detail says where.
    case invalidDocument(String)
    /// The document is not a JSON object.
    case notAnObject
    /// A key is not a schema key at its place, in exact case.
    case unknownKey(String)
    /// A key appears twice in one object.
    case duplicateKey(String)
    /// A key holds an array.
    case arrayValue(String)
    /// Something follows the one object.
    case trailingData
    case schema
    case context
    case tag
    case minimumMacOS
    case issuedAt
    case bundleID
    case shortVersion(String)
    case imageName(String)
    case imageSHA256
    case imageSize(Int64)
    case imageURL(String)
    case archive(String)
    case archiveSHA256
    case payloadManifestSHA256

    public var description: String {
        switch self {
        case .tooLarge(let n): "\(n) bytes, over the \(ReleaseIndex.maxBytes) byte cap"
        case .invalidDocument(let detail): "not a valid document: \(detail)"
        case .notAnObject: "the document is not a JSON object"
        case .unknownKey(let key): "unknown key \(Self.quoted(key))"
        case .duplicateKey(let key): "duplicate key \(Self.quoted(key))"
        case .arrayValue(let key): "key \(Self.quoted(key)) holds an array"
        case .trailingData: "trailing data after the document"
        case .schema: "schema is not \(ReleaseIndex.schema)"
        case .context: "context is not \(ReleaseIndex.context)"
        case .tag: "tag is not a final release tag vMAJOR.MINOR.PATCH"
        case .minimumMacOS: "minimumMacOS is not MAJOR[.MINOR[.PATCH]]"
        case .issuedAt: "issuedAt is not a UTC time YYYY-MM-DDTHH:MM:SSZ"
        case .bundleID: "app: bundleID is not \(ReleaseIndex.bundleID)"
        case .shortVersion(let core): "app: shortVersion is not \(core)"
        case .imageName(let core): "app: image name is not k3sm_\(core)_darwin_arm64.dmg"
        case .imageSHA256: "app: image sha256 is not a lowercase hex sha256"
        case .imageSize(let n): "app: image size \(n) is outside 1 to \(ReleaseIndex.maxImageBytes) bytes"
        case .imageURL(let want): "app: image url is not \(want)"
        case .archive(let core): "k3sm: archive is not k3sm_\(core)_darwin_arm64.tar.gz"
        case .archiveSHA256: "k3sm: archiveSHA256 is not a lowercase hex sha256"
        case .payloadManifestSHA256: "k3sm: payloadManifestSHA256 is not a lowercase hex sha256"
        }
    }

    /// A key as a quoted, escaped, bounded literal: the text came from the
    /// document, so it is never shown raw.
    private static func quoted(_ key: String) -> String {
        let limit = 64
        var out = ""
        for (i, scalar) in key.unicodeScalars.enumerated() {
            if i == limit {
                out += "..."
                break
            }
            if scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7F, scalar != "\"", scalar != "\\" {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "\\u{%X}", scalar.value)
            }
        }
        return "\"" + out + "\""
    }
}

// MARK: - The field grammar

extension ReleaseIndex {
    /// The v1 key tree: each object's keys, mapped to the keys of the object
    /// that key holds (empty for a scalar, so any key inside one is unknown).
    static let schemaKeys = KeyTree([
        "schema": .scalar, "context": .scalar, "issuedAt": .scalar, "tag": .scalar, "minimumMacOS": .scalar,
        "app": KeyTree([
            "bundleID": .scalar, "shortVersion": .scalar,
            "image": KeyTree(["name": .scalar, "url": .scalar, "sha256": .scalar, "size": .scalar]),
        ]),
        "k3sm": KeyTree(["archive": .scalar, "archiveSHA256": .scalar, "payloadManifestSHA256": .scalar]),
    ])

    /// Maps the checked tree onto the fields. A missing field is its zero
    /// value, as in k3sm, so the grammar check names it; a value of the wrong
    /// type is refused here.
    private static func decode(_ root: [JSONKey: JSONValue]) throws(ReleaseIndexError) -> ReleaseIndex {
        let app = try object(root, "app")
        let image = try object(app, "image")
        let k3sm = try object(root, "k3sm")
        let tag = try string(root, "tag")
        // A placeholder until check() has accepted the tag; parse replaces it.
        guard let placeholder = SemanticVersion("0.0.0") else { throw .tag }
        return ReleaseIndex(
            schema: try string(root, "schema"),
            context: try string(root, "context"),
            issuedAt: try string(root, "issuedAt"),
            tag: tag,
            version: placeholder,
            minimumMacOS: try string(root, "minimumMacOS"),
            app: App(
                bundleID: try string(app, "bundleID"),
                shortVersion: try string(app, "shortVersion"),
                image: Image(
                    name: try string(image, "name"),
                    url: try string(image, "url"),
                    sha256: try string(image, "sha256"),
                    size: try integer(image, "size"))),
            k3sm: K3sm(
                archive: try string(k3sm, "archive"),
                archiveSHA256: try string(k3sm, "archiveSHA256"),
                payloadManifestSHA256: try string(k3sm, "payloadManifestSHA256")))
    }

    private static func string(_ obj: [JSONKey: JSONValue], _ key: String) throws(ReleaseIndexError) -> String {
        switch obj[Array(key.utf8)] {
        case nil: return ""
        case .string(let s): return s
        default: throw .invalidDocument("key \"\(key)\" is not a string")
        }
    }

    private static func object(_ obj: [JSONKey: JSONValue], _ key: String) throws(ReleaseIndexError) -> [JSONKey: JSONValue] {
        switch obj[Array(key.utf8)] {
        case nil: return [:]
        case .object(let o): return o
        default: throw .invalidDocument("key \"\(key)\" is not an object")
        }
    }

    /// An integer written as one: no fraction, no exponent, within Int64.
    private static func integer(_ obj: [JSONKey: JSONValue], _ key: String) throws(ReleaseIndexError) -> Int64 {
        switch obj[Array(key.utf8)] {
        case nil: return 0
        case .number(let text, let isInteger):
            guard isInteger, let n = Int64(text) else {
                throw .invalidDocument("key \"\(key)\" is not an integer")
            }
            return n
        default: throw .invalidDocument("key \"\(key)\" is not an integer")
        }
    }

    /// This document with `version` in place of the placeholder.
    private func with(version: SemanticVersion) -> ReleaseIndex {
        ReleaseIndex(
            schema: schema, context: context, issuedAt: issuedAt, tag: tag, version: version,
            minimumMacOS: minimumMacOS, app: app, k3sm: k3sm)
    }

    /// The grammar check, in k3sm's order; it returns the tag as a version.
    private func check() throws(ReleaseIndexError) -> SemanticVersion {
        guard Self.same(schema, Self.schema) else { throw .schema }
        guard Self.same(context, Self.context) else { throw .context }
        guard Self.isFinalTag(tag), let parsed = SemanticVersion(tag), parsed.prerelease.isEmpty else { throw .tag }
        guard Self.isMacOSVersion(minimumMacOS) else { throw .minimumMacOS }
        guard Self.isIssuedAt(issuedAt) else { throw .issuedAt }
        let core = String(tag.dropFirst())
        guard Self.same(app.bundleID, Self.bundleID) else { throw .bundleID }
        guard Self.same(app.shortVersion, core) else { throw .shortVersion(core) }
        let im = app.image
        guard Self.same(im.name, "k3sm_" + core + "_darwin_arm64.dmg") else { throw .imageName(core) }
        guard Self.isSHA256Hex(im.sha256) else { throw .imageSHA256 }
        guard im.size >= 1, im.size <= Self.maxImageBytes else { throw .imageSize(im.size) }
        let want = Self.downloadURL(tag: tag, name: im.name)
        guard Self.same(im.url, want) else { throw .imageURL(want) }
        guard Self.same(k3sm.archive, "k3sm_" + core + "_darwin_arm64.tar.gz") else { throw .archive(core) }
        guard Self.isSHA256Hex(k3sm.archiveSHA256) else { throw .archiveSHA256 }
        guard Self.isSHA256Hex(k3sm.payloadManifestSHA256) else { throw .payloadManifestSHA256 }
        return parsed
    }

    /// Byte equality of the UTF-8 encodings, as k3sm compares. Swift's `==`
    /// on strings is canonical equivalence (U+212A KELVIN SIGN equals `K`),
    /// so no field or key is ever compared with it.
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// `^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$`.
    static func isFinalTag(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.first == UInt8(ascii: "v") else { return false }
        let parts = b.dropFirst().split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { isNumber($0, maxDigits: 9) }
    }

    /// `^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){0,2}$`.
    static func isMacOSVersion(_ s: String) -> Bool {
        let parts = Array(s.utf8).split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts[0].first != UInt8(ascii: "0") else { return false }
        return parts.allSatisfy { isNumber($0, maxDigits: 3) }
    }

    /// `0` or a digit run of at most `maxDigits` with no leading zero.
    private static func isNumber(_ part: ArraySlice<UInt8>, maxDigits: Int) -> Bool {
        guard (1...maxDigits).contains(part.count), part.allSatisfy(isDigit) else { return false }
        return part.count == 1 || part.first != UInt8(ascii: "0")
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`, a real proleptic Gregorian date, hours 00-23,
    /// minutes and seconds 00-59: exactly the strings Go's time.Parse with
    /// that layout accepts and formats back unchanged.
    static func isIssuedAt(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 20 else { return false }
        let digitAt: Set<Int> = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        let literal: [Int: Character] = [4: "-", 7: "-", 10: "T", 13: ":", 16: ":", 19: "Z"]
        for i in 0..<20 {
            if digitAt.contains(i) {
                guard isDigit(b[i]) else { return false }
            } else if let c = literal[i] {
                guard b[i] == c.asciiValue else { return false }
            }
        }
        func num(_ from: Int, _ count: Int) -> Int {
            b[from..<from + count].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        let year = num(0, 4), month = num(5, 2), day = num(8, 2)
        let hour = num(11, 2), minute = num(14, 2), second = num(17, 2)
        guard (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...days).contains(day)
    }

    /// 64 lowercase hex characters.
    static func isSHA256Hex(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == 64 && b.allSatisfy { isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
    }
}

// MARK: - The strict scanner

/// KeyTree is the set of keys an object may hold, each with the keys of the
/// object it may hold in turn.
final class KeyTree: Sendable {
    /// Keyed by the UTF-8 bytes of each key, never by `String`, whose
    /// hashing and equality are canonical equivalence.
    let keys: [JSONKey: KeyTree]

    init(_ keys: [String: KeyTree]) {
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { (Array($0.key.utf8), $0.value) })
    }

    /// A scalar's tree: no key is allowed inside it.
    static let scalar = KeyTree([:])
}

/// A decoded object key: its UTF-8 bytes, compared and hashed as bytes.
typealias JSONKey = [UInt8]

/// One decoded JSON value. Arrays never reach a value: they are refused where
/// they are found.
enum JSONValue: Equatable {
    case string(String)
    /// The number's text as written, and whether it is an integer (no
    /// fraction, no exponent).
    case number(String, isInteger: Bool)
    case bool(Bool)
    case null
    case object([JSONKey: JSONValue])
}

/// StrictJSONScanner reads one RFC 8259 JSON object from UTF-8 bytes and
/// refuses what common decoders let through: a byte order mark or any
/// encoding other than UTF-8, invalid UTF-8, a lone surrogate escape, a raw
/// control character in a string, whitespace other than space, tab, CR and
/// LF, and a repeated key (compared after escapes are decoded, so `"tag"` and
/// `"tag"` are the same key). It checks each key against the schema as
/// it reads it. Recursion is bounded by the schema: a key that is not in it
/// is refused before its value is read.
struct StrictJSONScanner {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The one top-level value, which must be an object.
    mutating func document(keys: KeyTree) throws(ReleaseIndexError) -> [JSONKey: JSONValue] {
        skipSpace()
        guard let c = peek() else { throw .invalidDocument("no JSON value") }
        switch c {
        case UInt8(ascii: "{"):
            pos += 1
            return try object(keys: keys)
        case UInt8(ascii: "["):
            throw .notAnObject
        default:
            _ = try scalar(key: "")
            throw .notAnObject
        }
    }

    /// Refuses anything after the document but JSON whitespace.
    mutating func end() throws(ReleaseIndexError) {
        skipSpace()
        if pos != bytes.count { throw .trailingData }
    }

    /// The members of an object and its closing brace; the opening brace is read.
    private mutating func object(keys: KeyTree) throws(ReleaseIndexError) -> [JSONKey: JSONValue] {
        var members: [JSONKey: JSONValue] = [:]
        skipSpace()
        if peek() == UInt8(ascii: "}") {
            pos += 1
            return members
        }
        while true {
            skipSpace()
            guard peek() == UInt8(ascii: "\"") else { throw syntax("a key") }
            pos += 1
            let key = try stringBody()
            let bytes = Array(key.utf8)
            guard let sub = keys.keys[bytes] else { throw .unknownKey(key) }
            guard members[bytes] == nil else { throw .duplicateKey(key) }
            skipSpace()
            guard peek() == UInt8(ascii: ":") else { throw syntax("':'") }
            pos += 1
            skipSpace()
            switch peek() {
            case UInt8(ascii: "{"):
                pos += 1
                members[bytes] = .object(try object(keys: sub))
            case UInt8(ascii: "["):
                throw .arrayValue(key)
            default:
                members[bytes] = try scalar(key: key)
            }
            skipSpace()
            switch peek() {
            case UInt8(ascii: ","):
                pos += 1
            case UInt8(ascii: "}"):
                pos += 1
                return members
            default:
                throw syntax("',' or '}'")
            }
        }
    }

    /// A string, number, true, false or null.
    private mutating func scalar(key: String) throws(ReleaseIndexError) -> JSONValue {
        guard let c = peek() else { throw syntax("a value") }
        switch c {
        case UInt8(ascii: "\""):
            pos += 1
            return .string(try stringBody())
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        default:
            throw syntax("a value")
        }
    }

    private mutating func literal(_ word: String) throws(ReleaseIndexError) {
        let w = Array(word.utf8)
        guard bytes.count - pos >= w.count, Array(bytes[pos..<pos + w.count]) == w else { throw syntax("a value") }
        pos += w.count
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    private mutating func number() throws(ReleaseIndexError) -> JSONValue {
        let start = pos
        var isInteger = true
        if peek() == UInt8(ascii: "-") { pos += 1 }
        if peek() == UInt8(ascii: "0") {
            pos += 1
        } else if digits() == 0 {
            throw syntax("a digit")
        }
        if peek() == UInt8(ascii: ".") {
            pos += 1
            isInteger = false
            if digits() == 0 { throw syntax("a digit after '.'") }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            pos += 1
            isInteger = false
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { pos += 1 }
            if digits() == 0 { throw syntax("a digit in the exponent") }
        }
        return .number(String(decoding: bytes[start..<pos], as: UTF8.self), isInteger: isInteger)
    }

    private mutating func digits() -> Int {
        let start = pos
        while let c = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { pos += 1 }
        return pos - start
    }

    /// A string's body and its closing quote; the opening quote is read.
    private mutating func stringBody() throws(ReleaseIndexError) -> String {
        var out: [UInt8] = []
        while true {
            guard let c = peek() else { throw syntax("the end of a string") }
            pos += 1
            switch c {
            case UInt8(ascii: "\""):
                guard let s = String(validating: out, as: UTF8.self) else {
                    throw .invalidDocument("a string is not valid UTF-8")
                }
                return s
            case UInt8(ascii: "\\"):
                try escape(into: &out)
            case 0x00..<0x20:
                throw .invalidDocument("a control character in a string")
            default:
                out.append(c)
            }
        }
    }

    private mutating func escape(into out: inout [UInt8]) throws(ReleaseIndexError) {
        guard let c = peek() else { throw syntax("an escape") }
        pos += 1
        switch c {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(c)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
            var value = try hex4()
            if (0xD800..<0xDC00).contains(value) {
                guard bytes.count - pos >= 2, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                    throw .invalidDocument("a lone surrogate escape")
                }
                pos += 2
                let low = try hex4()
                guard (0xDC00..<0xE000).contains(low) else { throw .invalidDocument("a lone surrogate escape") }
                value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00..<0xE000).contains(value) {
                throw .invalidDocument("a lone surrogate escape")
            }
            guard let scalar = Unicode.Scalar(value) else { throw .invalidDocument("an invalid escape") }
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw syntax("a valid escape")
        }
    }

    private mutating func hex4() throws(ReleaseIndexError) -> UInt32 {
        guard bytes.count - pos >= 4 else { throw syntax("four hex digits") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[pos]
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: throw syntax("four hex digits")
            }
            value = value << 4 | UInt32(d)
            pos += 1
        }
        return value
    }

    /// JSON whitespace only: space, tab, CR, LF.
    private mutating func skipSpace() {
        while let c = peek(), c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { pos += 1 }
    }

    private func peek() -> UInt8? {
        pos < bytes.count ? bytes[pos] : nil
    }

    private func syntax(_ want: String) -> ReleaseIndexError {
        pos < bytes.count
            ? .invalidDocument("want \(want) at offset \(pos)")
            : .invalidDocument("unexpected end of input, want \(want)")
    }
}
