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

import K3smStatus

/// JoinTokenMint is the closed set of tokens the app mints as root through
/// the installed CLI. There is one: a worker join token with a fixed
/// 15-minute lifetime. Its argv is a compile-time constant
/// (`arguments(for:)`): never `--server` (a server token does not expire and
/// can rebuild the cluster CAs), and never a string from the user.
public enum JoinTokenMint: String, CaseIterable, Hashable, Sendable {
    case workerToken = "worker-token"

    /// The token's lifetime: 15 minutes, the one definition. The CLI flag
    /// and every sentence that names the lifetime derive from it.
    public static let ttl: Duration = .seconds(15 * 60)

    /// The lifetime in whole minutes.
    public static var ttlMinutes: Int { Int(ttl.components.seconds / 60) }

    /// The lifetime as the CLI's `--ttl` value (a Go duration).
    public static var ttlFlag: String { "\(ttlMinutes)m" }

    /// The argv after the CLI path, the one definition of the command line.
    /// The golden tests pin it against `cmd/k3sm/token.go`.
    public static func arguments(for mint: JoinTokenMint) -> [String] {
        switch mint {
        case .workerToken: return ["token", "create", "--ttl", ttlFlag]
        }
    }

    /// The administrator prompt. Fixed text.
    public var prompt: String {
        switch self {
        case .workerToken:
            return "k3sm wants to create a join token for another Mac. It expires in \(Self.ttlMinutes) minutes."
        }
    }

    /// Renders the mint script for the installed CLI at `K3smCLI.path`.
    public static func render(_ mint: JoinTokenMint, teamID: TeamID) -> RootScript {
        render(mint, teamID: teamID, cliPath: K3smCLI.path)
    }

    /// Renders the mint script for a CLI at `cliPath`: the same checks as
    /// every lifecycle verb (`InstalledCLIPreamble`), then the CLI with its
    /// standard output held in a variable and printed only after the CLI
    /// exited 0. A failed mint therefore writes nothing to standard output,
    /// and the runner's error path carries only standard error. The script
    /// asks for its output as a secret (`RootScript.ResultUse.secret`), so
    /// only the capturing call returns it. Only the tests pass another path.
    static func render(_ mint: JoinTokenMint, teamID: TeamID, cliPath: String) -> RootScript {
        let argv = arguments(for: mint).map(ShellQuote.quote).joined(separator: " ")
        let text = InstalledCLIPreamble.render(teamID: teamID, cliPath: cliPath)
            + "token=$(\"$k3sm\" \(argv))\n"
            + "printf '%s\\n' \"$token\"\n"
        return RootScript(text: text, prompt: mint.prompt, readsInput: false, usesStagingLock: false, result: .secret)
    }
}

/// JoinToken is a worker join token that passed the grammar the k3sm CLI
/// prints (`bootstrap.FormatToken`): `K10`, the cluster CA's SHA-256 as 64
/// lowercase hex digits, `::`, the token user, `:`, the hex secret. The
/// grammar admits no quote, space or shell character. The value is a secret:
/// its description is redacted, so string interpolation and logging never
/// print it.
public struct JoinToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The token text. Read it only to render the copied command.
    public let value: String

    /// Validates `text` exactly; nothing is trimmed.
    public init?(validating text: String) {
        guard Self.isToken(Substring(text)) else { return nil }
        value = text
    }

    /// Reads the token from the mint's standard output: surrounding line
    /// breaks are dropped, comment lines (`# ...`) are ignored, and exactly
    /// one remaining line must pass the grammar.
    public init?(output: String) {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).filter { !$0.hasPrefix("# ") }
        guard lines.count == 1, Self.isToken(lines[0]) else { return nil }
        value = String(lines[0])
    }

    public var description: String { "<join token>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    static let prefix = "K10"
    static let caHashLength = 64
    static let userLengths = 1...64
    static let secretLengths = 32...128

    static func isToken(_ s: Substring) -> Bool {
        guard s.hasPrefix(prefix) else { return false }
        let rest = s.dropFirst(prefix.count)
        guard let sep = rest.range(of: "::") else { return false }
        let ca = rest[..<sep.lowerBound]
        let cred = rest[sep.upperBound...]
        guard let colon = cred.firstIndex(of: ":") else { return false }
        let user = cred[..<colon]
        let secret = cred[cred.index(after: colon)...]
        let hex: (UInt8) -> Bool = { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        let userByte: (UInt8) -> Bool = { (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) || $0 == UInt8(ascii: "-") }
        return ca.utf8.count == caHashLength && ca.utf8.allSatisfy(hex)
            && userLengths.contains(user.utf8.count) && user.utf8.allSatisfy(userByte) && user.first != "-"
            && secretLengths.contains(secret.utf8.count) && secret.utf8.allSatisfy(hex)
    }

    /// Replaces anything in `text` that starts like a token (`K10` and the
    /// characters a token can hold) with `<redacted>`. Every error text from
    /// the mint passes through it before the app shows it.
    public static func redact(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        let tokenByte: (Character) -> Bool = { c in
            c.isASCII && (c.isLetter || c.isNumber || c == ":" || c == "-" || c == "_")
        }
        while let r = rest.range(of: prefix) {
            out += rest[..<r.lowerBound]
            var end = r.upperBound
            while end < rest.endIndex, tokenByte(rest[end]) { end = rest.index(after: end) }
            out += "<redacted>"
            rest = rest[end...]
        }
        return out + rest
    }
}
