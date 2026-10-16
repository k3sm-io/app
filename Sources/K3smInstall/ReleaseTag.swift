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

/// ReleaseTag is a release tag the app may pass to `k3sm update apply
/// --version`: the check is k3sm's own `version.ValidTag`
/// (`pkg/version/release.go`), mirrored rule for rule, so the app never
/// hands the root step a tag the CLI would refuse, and no tag reaches the
/// root script that is not non-empty, at most 128 bytes, free of a leading
/// `-`, and made only of ASCII letters, digits, `.`, `+`, `_` and `-`. The
/// value is still single-quoted (`ShellQuote`) like every other argument.
public struct ReleaseTag: Hashable, Sendable, CustomStringConvertible {
    /// The longest tag, in bytes, as `ValidTag` counts it.
    public static let maxLength = 128

    /// The tag, exactly as given.
    public let value: String

    /// A tag that passes `isValid`, or nil.
    public init?(_ tag: String) {
        guard Self.isValid(tag) else { return nil }
        value = tag
    }

    public var description: String { value }

    /// `version.ValidTag`: Go ranges over runes and refuses any rune outside
    /// the set, so a check over the UTF-8 bytes is the same predicate (every
    /// byte of a non-ASCII rune is outside the set too).
    public static func isValid(_ tag: String) -> Bool {
        let bytes = Array(tag.utf8)
        guard !bytes.isEmpty, bytes.count <= maxLength, bytes.first != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy { b in
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }
}
