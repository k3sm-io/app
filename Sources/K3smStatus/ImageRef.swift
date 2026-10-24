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

/// ImageRef is an image reference the app may hand to the root step as one
/// argument of `k3sm image untag` or `k3sm image pull`: the distribution
/// reference grammar, narrowed to ASCII and bounded, so nothing outside it
/// (a space, a quote, `$`, a backtick, a newline, a leading `-`, a format
/// character) can reach a command line:
///
///     reference := name [ ":" tag ] [ "@" digest ]
///     name      := [ domain "/" ] component ( "/" component )*
///     domain    := label ( "." label )* [ ":" port ]
///     label     := [A-Za-z0-9] ( [A-Za-z0-9-]* [A-Za-z0-9] )?
///     port      := [0-9]{1,5}
///     component := [a-z0-9]+ ( ( "." | "_" | "__" | "-"+ ) [a-z0-9]+ )*
///     tag       := [A-Za-z0-9_] [A-Za-z0-9_.-]{0,127}
///     digest    := "sha256:" [0-9a-f]{64}
///
/// The first part of a name is its domain only when more parts follow and
/// it holds a "." or a ":" or is "localhost", the rule the distribution
/// library uses; otherwise it is a path component, so "Library/x" is
/// refused rather than read as a host. The name is at most `maxNameLength`
/// characters, the whole reference at most `maxLength`. The value is only
/// ever shell-quoted as one word (`ShellQuote`); the grammar is the second
/// guard, not the first.
public struct ImageRef: Hashable, Sendable {
    /// The reference, exactly as checked.
    public let value: String

    /// The longest name the distribution library accepts.
    public static let maxNameLength = 255
    /// The longest reference: a name, a 128-character tag and a digest.
    public static let maxLength = maxNameLength + 1 + 128 + 1 + 71

    /// Problem is why a text is not an image reference, as the Pull field says it.
    public enum Problem: Equatable, Sendable {
        case empty
        case tooLong
        case invalidCharacter
        case badDomain
        case badName
        case badTag
        case badDigest

        /// The line shown under the Pull field.
        public var text: String {
            switch self {
            case .empty: return "Enter an image reference, such as docker.io/library/nginx:1.27."
            case .tooLong: return "That reference is longer than an image reference can be."
            case .invalidCharacter: return "An image reference has only letters, digits and . _ - : / @."
            case .badDomain: return "The registry part, before the first /, is not a host name with an optional port."
            case .badName: return "Each part of the name is lowercase letters and digits, joined by . _ or -."
            case .badTag: return "A tag is letters, digits, _ . and -, up to 128, and cannot start with . or -."
            case .badDigest: return "A digest is sha256: and 64 lowercase hex digits."
            }
        }
    }

    /// A reference that passes the grammar, or nil.
    public init?(_ text: String) {
        guard Self.problem(text) == nil else { return nil }
        value = text
    }

    /// Why `text` is not a reference, or nil when it is one.
    public static func problem(_ text: String) -> Problem? {
        if text.isEmpty { return .empty }
        let scalars = Array(text.unicodeScalars)
        if scalars.count > maxLength { return .tooLong }
        let allowed = { (s: Unicode.Scalar) in isAlphanumeric(s) || "._-:/@".unicodeScalars.contains(s) }
        guard scalars.allSatisfy(allowed) else { return .invalidCharacter }
        var rest = Substring(text)
        if let at = rest.firstIndex(of: "@") {
            guard isDigest(rest[rest.index(after: at)...]) else { return .badDigest }
            rest = rest[..<at]
        }
        var name = rest
        let lastPart = rest.lastIndex(of: "/").map { rest.index(after: $0) } ?? rest.startIndex
        if let colon = rest[lastPart...].lastIndex(of: ":") {
            guard isTag(rest[rest.index(after: colon)...]) else { return .badTag }
            name = rest[..<colon]
        }
        guard !name.isEmpty else { return .badName }
        guard name.count <= maxNameLength else { return .tooLong }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 1, let first = parts.first, first.contains(".") || first.contains(":") || first == "localhost" {
            guard isDomain(first) else { return .badDomain }
            parts.removeFirst()
        }
        guard parts.allSatisfy(isComponent) else { return .badName }
        return nil
    }

    /// The registry the image daemon contacts for the reference, by the rule
    /// it resolves names with (go-containerregistry's, `authorityOf` in
    /// runtimed's `pkg/image/mirror.go`): the part before the first "/" when
    /// it holds a "." or a ":"; nil for a name with no registry of its own
    /// ("nginx", "library/nginx", and "localhost/app" too, which that rule
    /// reads as a Docker Hub path), which the daemon asks this node's own
    /// registry for first, when it has one, then Docker Hub.
    public var registryHost: String? {
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let first = value[..<slash]
        guard first.contains(".") || first.contains(":") else { return nil }
        return String(first)
    }

    /// Whether `registryHost` names this Mac's loopback interface, the
    /// node's own registry, whose misses the daemon asks the other nodes'
    /// registries for.
    public var registryIsLoopback: Bool {
        guard let host = registryHost else { return false }
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        return name == "localhost" || name.hasPrefix("127.")
    }

    /// Whether `k3sm image pull` copies the reference into the cluster
    /// registry after the node's pull: a public reference does; one in the
    /// cluster registry, or in a registry with a port, gets no copy (the
    /// CLI's rule, `mirrorPulled` in cmd/k3sm/imagemirror.go).
    public var mirrorsToRegistry: Bool {
        guard let host = registryHost else { return true }
        return host != RegistryTag.registry && !host.contains(":")
    }

    /// Whether the reference carries a digest ("…@sha256:…").
    public var hasDigest: Bool { value.contains("@") }

    static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }

    static func isLowerAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s)
    }

    static func isDigest(_ text: Substring) -> Bool {
        let prefix = "sha256:"
        guard text.hasPrefix(prefix) else { return false }
        let hex = text.dropFirst(prefix.count).unicodeScalars
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func isTag(_ text: Substring) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 128 else { return false }
        guard isAlphanumeric(first) || first == "_" else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || "_.-".unicodeScalars.contains($0) }
    }

    static func isDomain(_ text: Substring) -> Bool {
        var host = text
        if let colon = text.firstIndex(of: ":") {
            let port = text[text.index(after: colon)...]
            guard (1...5).contains(port.count), port.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
            host = text[..<colon]
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            let s = Array(label.unicodeScalars)
            guard let first = s.first, let last = s.last else { return false }
            return isAlphanumeric(first) && isAlphanumeric(last) && s.allSatisfy { isAlphanumeric($0) || $0 == "-" }
        }
    }

    /// One path component: runs of lowercase letters and digits joined by a
    /// single ".", one or two "_", or any number of "-".
    static func isComponent(_ text: Substring) -> Bool {
        let s = Array(text.unicodeScalars)
        guard let first = s.first, let last = s.last, isLowerAlphanumeric(first), isLowerAlphanumeric(last) else { return false }
        var i = 0
        while i < s.count {
            if isLowerAlphanumeric(s[i]) { i += 1; continue }
            var j = i
            while j < s.count, !isLowerAlphanumeric(s[j]) { j += 1 }
            let separator = String(String.UnicodeScalarView(s[i..<j]))
            guard separator == "." || separator == "_" || separator == "__" || separator.allSatisfy({ $0 == "-" }) else { return false }
            i = j
        }
        return true
    }
}
