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

/// JoinPaste is what a pasted join command holds: the server's address, as
/// text for `ServerAddress(parsing:)` (a URL's scheme and trailing slash
/// removed), and the join token. Its descriptions never print the token, so
/// neither a log line nor a test failure can carry it.
public struct JoinPaste: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let server: String
    public let token: String

    public init(server: String, token: String) {
        self.server = server
        self.token = token
    }

    public var description: String { "JoinPaste(server: \(server), token: <hidden>)" }
    public var debugDescription: String { description }
}

/// JoinPasteError says why a paste was refused, in words the join step can
/// show. No case carries the pasted text or the token.
public enum JoinPasteError: Error, Equatable, Sendable {
    case empty
    case tooLong
    /// A shell operator, a substitution, a control character, or a
    /// character outside ASCII that is not a typographic quote or space.
    case unsafeCharacter
    case unbalancedQuote
    /// A command that is not `k3sm install` (or `k3sm agent`), or a stray word.
    case notAJoinCommand
    case missingServer
    case missingToken
    /// `--token-file` names a file the app cannot read; the token itself is needed.
    case tokenInFile
    case invalidToken
    case invalidServer
    /// An option the app's join does not pass; its name only.
    case unsupportedOption(String)
    /// Two different servers or two different tokens.
    case conflicting

    public var message: String {
        switch self {
        case .empty:
            return "Paste the join command from the server, or its address and token."
        case .tooLong:
            return "That is too long to be a join command."
        case .unsafeCharacter:
            return "That holds characters a join command never has, such as ; | & $ or a backquote. Paste only the k3sm install line."
        case .unbalancedQuote:
            return "A quote in that command is not closed."
        case .notAJoinCommand:
            return "That is not a join. Paste the server's address and the token \(JoinHints.pasteExample), as `sudo k3sm token create` prints the token on the server."
        case .missingServer:
            return "The server's address is missing. Add it, for example studio.local."
        case .missingToken:
            return "The join token is missing. Run `sudo k3sm token create` on the server and paste the token too."
        case .tokenInFile:
            return "That command reads the token from a file. Paste the token itself, from `sudo k3sm token create` on the server."
        case .invalidToken:
            return "That is not a join token. A token starts with K10, as `sudo k3sm token create` prints it."
        case .invalidServer:
            return "That is not a server address. Use a host name or an IP address, for example studio.local."
        case .unsupportedOption(let name):
            return "The app joins without \(name). Remove it, or join in Terminal."
        case .conflicting:
            return "That names two different servers or two different tokens."
        }
    }
}

/// JoinCommandParser reads a pasted join command into a `JoinPaste`. It
/// takes a `sudo k3sm install --agent --server <host> --token <token>` line
/// (people write it, though the CLI's own flag is `--token-file`) or its flags alone (with `--flag=value`, single-dash flags, `\` line breaks,
/// quotes, `K3SM_TOKEN=<token>` before the command, `#` comment lines and
/// typographic quotes forgiven), `k3sm agent` with the same flags, or the
/// bare address and token in either order. A server given as a URL loses its
/// `https://` and trailing slash. The grammar is strict: anything a shell
/// would act on (`;`, `|`, `&`, `$`, backquotes, redirections, globs) is
/// refused outright, and nothing is ever executed. The address is validated
/// again by `ServerAddress`, and the token's shape here is `K10<hash>::<user>:<secret>`.
public enum JoinCommandParser {
    /// The longest paste read.
    public static let maxLength = 4096
    /// The longest token accepted.
    public static let maxTokenLength = 512

    /// Whether `b` may appear in a server address (the `ServerAddress` alphabet).
    public static func isAddressByte(_ b: UInt8) -> Bool {
        isAlnum(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "-") || b == UInt8(ascii: ":")
            || b == UInt8(ascii: "[") || b == UInt8(ascii: "]")
    }

    static func isAlnum(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    static func isTokenByte(_ b: UInt8) -> Bool {
        isAlnum(b) || b == UInt8(ascii: ":") || b == UInt8(ascii: ".") || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
    }

    /// Characters a join command never holds, inside quotes or out.
    static let unsafe: Set<Character> = [";", "|", "&", "$", "`", "<", ">", "(", ")", "{", "}", "!", "*", "?"]

    public static func parse(_ text: String) -> Result<JoinPaste, JoinPasteError> {
        let words: [String]
        do {
            words = try split(normalize(text))
        } catch {
            return .failure(error)
        }
        guard !words.isEmpty else { return .failure(.empty) }
        return read(words)
    }

    /// Drops `#` comment lines (`k3sm token create` prints one above the
    /// token), maps typographic quotes and spaces to ASCII, and refuses what
    /// no join command holds.
    static func normalize(_ text: String) throws(JoinPasteError) -> String {
        guard text.utf8.count <= maxLength else { throw .tooLong }
        let kept = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") }
            .joined(separator: "\n")
        var out = String.UnicodeScalarView()
        for scalar in kept.unicodeScalars {
            switch scalar.value {
            case 0x201C, 0x201D: out.append("\"")
            case 0x2018, 0x2019: out.append("'")
            case 0x00A0, 0x2009, 0x202F: out.append(" ")
            case 0x09, 0x0A, 0x20...0x7E: out.append(scalar)
            default: throw .unsafeCharacter
            }
        }
        let joined = String(out)
        guard !joined.contains(where: unsafe.contains) else { throw .unsafeCharacter }
        return joined
    }

    /// Splits into words as a shell would for plain words and quotes: blanks
    /// separate, `'…'` and `"…"` group, a backslash only ends a line.
    static func split(_ text: String) throws(JoinPasteError) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" || c.isNewline { throw .unsafeCharacter } else { word.append(c) }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                // A line continuation: a line break or a blank follows it (a
                // paste into one line can turn the break into a space). A
                // backslash escaping anything else is refused.
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                guard j > i + 1 || j == chars.count || chars[j].isNewline else { throw .unsafeCharacter }
                if inWord { words.append(word); word = ""; inWord = false }
                i = j
            case " ", "\t", "\n":
                if inWord { words.append(word); word = ""; inWord = false }
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        guard quote == nil else { throw .unbalancedQuote }
        if inWord { words.append(word) }
        return words
    }

    /// The flags the reader knows, by the name after its dashes.
    enum Flag: String {
        case agent, server, token
        case tokenFile = "token-file"
    }

    static func read(_ words: [String]) -> Result<JoinPaste, JoinPasteError> {
        var server: String?
        var token: String?
        var tokenFile = false
        var i = 0

        func setServer(_ raw: String) -> JoinPasteError? {
            guard let value = serverText(raw) else { return .invalidServer }
            if let server, server != value { return .conflicting }
            server = value
            return nil
        }
        func setToken(_ raw: String) -> JoinPasteError? {
            guard isToken(raw) else { return .invalidToken }
            if let token, token != raw { return .conflicting }
            token = raw
            return nil
        }

        // A leading sudo, and any K3SM_TOKEN=<token> before the command.
        if words.first == "sudo" { i += 1 }
        while i < words.count, words[i].hasPrefix("K3SM_TOKEN=") {
            if let error = setToken(String(words[i].dropFirst("K3SM_TOKEN=".count))) { return .failure(error) }
            i += 1
        }
        var command = false
        if i < words.count, isProgram(words[i]) {
            command = true
            i += 1
            guard i < words.count, words[i] == "install" || words[i] == "agent" else { return .failure(.notAJoinCommand) }
            i += 1
        } else if i > 0 && words.first == "sudo" {
            return .failure(.notAJoinCommand)
        }

        while i < words.count {
            let word = words[i]
            i += 1
            if word.hasPrefix("-") {
                let body = word.hasPrefix("--") ? word.dropFirst(2) : word.dropFirst()
                let name = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                guard let flag = Flag(rawValue: name) else {
                    guard isOptionName(name) else { return .failure(.notAJoinCommand) }
                    return .failure(.unsupportedOption("--" + name))
                }
                var value: String?
                if let eq = body.firstIndex(of: "=") {
                    value = String(body[body.index(after: eq)...])
                } else if flag != .agent, i < words.count, !words[i].hasPrefix("-") {
                    value = words[i]
                    i += 1
                }
                switch flag {
                case .agent:
                    guard value == nil || value == "true" else { return .failure(.notAJoinCommand) }
                case .server:
                    guard let value, !value.isEmpty else { return .failure(.missingServer) }
                    if let error = setServer(value) { return .failure(error) }
                case .token:
                    guard let value, !value.isEmpty else { return .failure(.missingToken) }
                    if let error = setToken(value) { return .failure(error) }
                case .tokenFile:
                    tokenFile = true
                }
                continue
            }
            if word.hasPrefix("K10") {
                if let error = setToken(word) { return .failure(error) }
            } else if !command {
                // The bare form holds one address; a second word is not one.
                guard server == nil else { return .failure(.notAJoinCommand) }
                if let error = setServer(word) { return .failure(error) }
            } else {
                return .failure(.notAJoinCommand)
            }
        }
        guard let server else { return .failure(token == nil && !command ? .notAJoinCommand : .missingServer) }
        guard let token else { return .failure(tokenFile ? .tokenInFile : .missingToken) }
        return .success(JoinPaste(server: server, token: token))
    }

    /// Whether `word` names the k3sm command: `k3sm`, or a path ending in `/k3sm`.
    static func isProgram(_ word: String) -> Bool {
        guard word == "k3sm" || word.hasSuffix("/k3sm") else { return false }
        return word.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// Whether `name` looks like an option name, so the refusal may show it.
    static func isOptionName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...40).contains(bytes.count), (0x61...0x7A).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }

    /// The address text from a server word: a `https://` or `http://` scheme
    /// and one trailing slash removed; nil for a path, user info or any
    /// character outside the address alphabet.
    static func serverText(_ raw: String) -> String? {
        var text = Substring(raw)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = text.dropFirst(scheme.count)
            break
        }
        if text.hasSuffix("/") { text = text.dropLast() }
        guard !text.isEmpty, text.utf8.count <= 260, !text.hasPrefix("-"), text.utf8.allSatisfy(isAddressByte) else { return nil }
        return String(text)
    }

    /// Whether `raw` has a join token's shape: `K10<hash>::<user>:<secret>`,
    /// each part non-empty, in the token alphabet.
    static func isToken(_ raw: String) -> Bool {
        guard raw.hasPrefix("K10"), raw.utf8.count <= maxTokenLength, raw.utf8.allSatisfy(isTokenByte) else { return false }
        let rest = raw.dropFirst(3)
        guard let sep = rest.range(of: "::") else { return false }
        let hash = rest[..<sep.lowerBound]
        let credential = rest[sep.upperBound...]
        guard !hash.isEmpty, !hash.contains(":"), let colon = credential.firstIndex(of: ":") else { return false }
        return !credential[..<colon].isEmpty && !credential[credential.index(after: colon)...].isEmpty
    }
}
