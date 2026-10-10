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

/// ShellQuote renders a value as one POSIX shell word. The value is wrapped in
/// single quotes and every embedded single quote becomes `'\''`, so no byte of
/// the value is interpreted by the shell: not `$`, not a backtick, not a
/// newline, not a glob.
public enum ShellQuote {
    /// Returns `value` as a single-quoted shell word.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// AppleScriptText renders a value as an AppleScript string literal, for the
/// one `do shell script` the privileged runner compiles.
public enum AppleScriptText {
    /// Returns `value` as a double-quoted AppleScript string literal with
    /// backslash, double quote, and the line and tab controls escaped.
    public static func literal(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += #"\\"#
            case "\"": out += #"\""#
            case "\n": out += #"\n"#
            case "\r": out += #"\r"#
            case "\t": out += #"\t"#
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
