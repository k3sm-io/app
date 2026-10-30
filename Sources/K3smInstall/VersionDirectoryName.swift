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

/// VersionDirectoryName is the one grammar for `<version>` in the installed
/// CLI's versioned chain (`current -> versions/<version>`): the characters
/// of a release tag (`ReleaseTag`), at most `ReleaseTag.maxLength` bytes,
/// starting with a letter or digit (so never `.`, `..` or a hidden name),
/// not a `.partial` staging name, and `unknown-` only when exactly twelve
/// lowercase hex digits follow. `isValid` is the app-side check;
/// `shellLines` is the same rule as the root preamble runs it, and the
/// tests hold the two to one table.
public enum VersionDirectoryName {
    static let digits = "0123456789"
    static let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let hex = "0123456789abcdef"
    static let unknownPrefix = "unknown-"
    static let unknownDigits = 12

    /// Whether `name` is a version directory name the chain may point at.
    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let alnum = Set((digits + letters).utf8)
        let allowed = alnum.union(".+_-".utf8)
        guard let first = bytes.first, alnum.contains(first), bytes.count <= ReleaseTag.maxLength,
              bytes.allSatisfy(allowed.contains), !name.hasSuffix(".partial") else { return false }
        if name.hasPrefix(unknownPrefix) {
            let rest = bytes.dropFirst(unknownPrefix.utf8.count)
            return rest.count == unknownDigits && rest.allSatisfy(Set(hex.utf8).contains)
        }
        return true
    }

    /// The shell form, checking `$ver` and refusing with `refuse "$p names an
    /// invalid version"`. Bracket sets list every character rather than use
    /// ranges, so the root shell's locale cannot widen them.
    static var shellLines: [String] {
        let refusal = #"refuse "$p names an invalid version""#
        let alnum = digits + letters
        let hexDigit = "[" + hex + "]"
        return [
            #"case "$ver" in"#,
            "'' | [!\(alnum)]* | *[!\(alnum).+_-]* | *.partial)",
            "\t\(refusal) ;;",
            "\(unknownPrefix)*)",
            "\tcase \"$ver\" in",
            "\t\(unknownPrefix)\(String(repeating: hexDigit, count: unknownDigits))) ;;",
            "\t*) \(refusal) ;;",
            "\tesac ;;",
            "esac",
            #"if [ "${#ver}" -gt \#(ReleaseTag.maxLength) ]; then \#(refusal); fi"#,
        ]
    }
}
