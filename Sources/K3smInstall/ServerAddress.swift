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

/// ServerAddress is a validated control-plane address for a join: a DNS name,
/// a dotted IPv4 address, or a bracketed IPv6 address, optionally followed by
/// `:<port>`. The grammar is strict and ASCII-only, so no shell, AppleScript
/// or option syntax survives validation; the script builder still quotes it.
///
/// The k3sm CLI's `--server` takes a host and joins on the fixed bootstrap
/// port, so a port, when given, must be that port, and `argument` is the host
/// alone (an IPv6 address without its brackets).
public struct ServerAddress: Hashable, Sendable, CustomStringConvertible {
    /// The control plane's bootstrap port, which every join dials.
    public static let joinPort = 9345
    /// The longest DNS name accepted (RFC 1035).
    static let maxNameLength = 253

    public enum Host: Hashable, Sendable {
        case name(String)
        case ipv4(String)
        case ipv6(String)
    }

    public let host: Host
    public let port: Int

    /// The value passed to `k3sm install --agent --server`.
    public var argument: String {
        switch host {
        case .name(let s), .ipv4(let s), .ipv6(let s): return s
        }
    }

    /// The address as `host:port`, with an IPv6 host in brackets.
    public var description: String {
        switch host {
        case .ipv6(let s): return "[\(s)]:\(port)"
        case .name(let s), .ipv4(let s): return "\(s):\(port)"
        }
    }

    /// ParseError says why a typed address was refused, in words the join
    /// form can show.
    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case invalidCharacter
        case invalidHost
        case invalidIPv4
        case invalidIPv6
        case invalidPort
        case unsupportedPort(Int)

        public var message: String {
            switch self {
            case .empty: return "Enter the server's address."
            case .invalidCharacter: return "The address may contain only letters, digits, dots, hyphens, colons and brackets."
            case .invalidHost: return "That is not a valid host name."
            case .invalidIPv4: return "That is not a valid IPv4 address."
            case .invalidIPv6: return "That is not a valid IPv6 address. Write it in brackets, for example [fd00::1]."
            case .invalidPort: return "The port must be a number from 1 to 65535."
            case .unsupportedPort(let p): return "k3sm joins on port \(ServerAddress.joinPort), not \(p). Leave the port off."
            }
        }
    }

    /// Parses `text` exactly as typed; the caller trims surrounding
    /// whitespace before calling, and nothing else is forgiven.
    public init(parsing text: String) throws(ParseError) {
        guard !text.isEmpty else { throw .empty }
        let allowed: (UInt8) -> Bool = { b in
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
                || b == UInt8(ascii: ".") || b == UInt8(ascii: "-") || b == UInt8(ascii: ":")
                || b == UInt8(ascii: "[") || b == UInt8(ascii: "]")
        }
        guard text.utf8.allSatisfy(allowed) else { throw .invalidCharacter }

        let hostPart: Substring
        let portPart: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw .invalidIPv6 }
            hostPart = text[text.index(after: text.startIndex)..<close]
            let after = text[text.index(after: close)...]
            if after.isEmpty {
                portPart = nil
            } else if after.first == ":" {
                portPart = after.dropFirst()
            } else {
                throw .invalidIPv6
            }
            guard Self.isIPv6(hostPart) else { throw .invalidIPv6 }
            host = .ipv6(String(hostPart).lowercased())
        } else {
            guard !text.contains("["), !text.contains("]") else { throw .invalidHost }
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            switch pieces.count {
            case 1: hostPart = pieces[0]; portPart = nil
            case 2: hostPart = pieces[0]; portPart = pieces[1]
            default: throw .invalidIPv6
            }
            host = try Self.parseHost(hostPart)
        }

        if let portPart {
            guard let p = Self.parsePort(portPart) else { throw .invalidPort }
            guard p == Self.joinPort else { throw .unsupportedPort(p) }
            port = p
        } else {
            port = Self.joinPort
        }
    }

    private static func parseHost(_ s: Substring) throws(ParseError) -> Host {
        guard !s.isEmpty, s.utf8.count <= maxNameLength else { throw .invalidHost }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = labels.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
        if numeric {
            guard labels.count == 4, labels.allSatisfy(isOctet) else { throw .invalidIPv4 }
            return .ipv4(String(s))
        }
        for label in labels {
            guard isLabel(label) else { throw .invalidHost }
        }
        // An all-numeric top-level label is never a DNS name (RFC 3696 §2), so
        // `10.0.0.300.1`-shaped strings are refused rather than resolved.
        if let last = labels.last, last.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            throw .invalidHost
        }
        return .name(String(s).lowercased())
    }

    private static func isLabel(_ s: Substring) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...63).contains(bytes.count) else { return false }
        let alnum: (UInt8) -> Bool = { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
        guard alnum(bytes.first!), alnum(bytes.last!) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isOctet(_ s: Substring) -> Bool {
        guard (1...3).contains(s.count), !(s.count > 1 && s.first == "0"), let n = Int(s) else { return false }
        return n <= 255
    }

    private static func parsePort(_ s: Substring) -> Int? {
        guard (1...5).contains(s.count), s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s.first != "0",
              let n = Int(s), n <= 65535
        else { return nil }
        return n
    }

    /// Reports whether `s` is an IPv6 address in RFC 4291 text form: up to
    /// eight groups of one to four hex digits, at most one `::`, and an
    /// optional dotted IPv4 tail. Zone identifiers are refused.
    static func isIPv6(_ s: Substring) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 45 else { return false }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let compressed = halves.count == 2

        func groups(_ part: String) -> [Substring]? {
            if part.isEmpty { return [] }
            let g = part.split(separator: ":", omittingEmptySubsequences: false)
            return g.contains(where: \.isEmpty) ? nil : g
        }
        guard let head = groups(halves[0]), let tail = compressed ? groups(halves[1]) : [] else { return false }
        var all = head + tail
        var width = 0
        if let last = all.last, last.contains(".") {
            let octets = last.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy(isOctet) else { return false }
            all.removeLast()
            width += 2
        }
        let hex: (UInt8) -> Bool = { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
        guard all.allSatisfy({ (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy(hex) }) else { return false }
        width += all.count
        return compressed ? width < 8 : width == 8
    }
}
