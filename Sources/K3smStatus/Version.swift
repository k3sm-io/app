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

/// SemanticVersion is a k3sm release version: `major.minor.patch` with an
/// optional pre-release, as the CLI prints it (`v0.1.7`, `0.2.0-rc.1`).
/// Build metadata after `+` is accepted and ignored, as semver requires. An
/// unstamped developer build prints `dev`, which is not a version: parsing
/// returns nil and callers treat the installed version as unknown.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The dot-separated pre-release identifiers; empty for a release.
    public let prerelease: [String]

    /// The longest numeric identifier accepted. Nine digits always fit an Int
    /// and are far beyond any real version number.
    private static let maxDigits = 9

    /// Parses a version, with or without one leading `v`.
    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.first == "v" {
            rest = rest.dropFirst()
        }
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...]
            guard Self.validIdentifiers(build, numericRule: false) else { return nil }
            rest = rest[..<plus]
        }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let tail = rest[rest.index(after: dash)...]
            guard Self.validIdentifiers(tail, numericRule: true) else { return nil }
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            rest = rest[..<dash]
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(core[0]),
              let minor = Self.number(core[1]),
              let patch = Self.number(core[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    /// Reads the version from the first line of `k3sm version`, which is
    /// `k3sm <version>`.
    public static func fromVersionCommand(_ output: String) -> SemanticVersion? {
        guard let first = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let words = first.split(separator: " ")
        guard words.count == 2, words[0] == "k3sm" else { return nil }
        return SemanticVersion(String(words[1]))
    }

    /// The canonical form, without the leading `v` and without build metadata.
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A release ranks above any of its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            switch (Int(l), Int(r)) {
            case let (ln?, rn?): return ln < rn
            case (.some, nil): return true    // numeric identifiers rank lower
            case (nil, .some): return false
            case (nil, nil): return l < r      // ASCII order
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func number(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.allSatisfy(\.isASCIIDigit) else { return nil }
        if s.count > 1 && s.first == "0" { return nil }
        return Int(s)
    }

    private static func validIdentifiers(_ s: Substring, numericRule: Bool) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }) else {
                return false
            }
            if numericRule, part.allSatisfy(\.isASCIIDigit), part.count > 1, part.first == "0" {
                return false
            }
        }
        return true
    }
}

/// PayloadRelation is how the version bundled in the app compares with the
/// version installed in /Library/k3sm.
public enum PayloadRelation: Equatable, Sendable {
    /// The payload is a later release: an update is possible.
    case newer
    /// The payload is the installed release.
    case same
    /// The payload is an earlier release: installing it is a downgrade.
    case older

    /// Compares a payload version with the installed one.
    public init(payload: SemanticVersion, installed: SemanticVersion) {
        if payload == installed {
            self = .same
        } else if payload > installed {
            self = .newer
        } else {
            self = .older
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
