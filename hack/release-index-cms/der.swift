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

// der.swift -- the few CMS edits the fixture generator needs that openssl has
// no command for. Run by make-fixtures.sh as `swift der.swift <command> ...`;
// it is a hack tool, not part of the package, and reads only files the
// generator itself wrote.
//
//   signature <in.p7m> <out>              write signer 0's signature value
//   add-token <in.p7m> <token> <out.p7m>  add an RFC 3161 timestamp token to
//                                         signer 0 as the unsigned attribute
//                                         id-aa-timeStampToken
//   drop-signers <in.p7m> <out.p7m>       empty the signerInfos set
//
// It parses definite-length DER only and refuses anything else.

import Foundation

/// One DER element: its tag byte and either its children (constructed) or its
/// value bytes (primitive).
indirect enum Node {
    case primitive(UInt8, [UInt8])
    case constructed(UInt8, [Node])

    var tag: UInt8 {
        switch self {
        case .primitive(let t, _), .constructed(let t, _): t
        }
    }

    var children: [Node] {
        if case .constructed(_, let c) = self { return c }
        fail("element 0x\(String(tag, radix: 16)) is not constructed")
    }

    func encoded() -> [UInt8] {
        let body: [UInt8]
        switch self {
        case .primitive(_, let v): body = v
        case .constructed(_, let c): body = c.flatMap { $0.encoded() }
        }
        return [tag] + Self.length(body.count) + body
    }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("der.swift: \(message)\n".utf8))
    exit(1)
}

func parse(_ b: [UInt8], _ i: inout Int) -> Node {
    guard i + 2 <= b.count else { fail("truncated element at \(i)") }
    let tag = b[i]
    guard tag & 0x1F != 0x1F else { fail("multi-byte tag at \(i)") }
    var n = Int(b[i + 1])
    i += 2
    if n & 0x80 != 0 {
        let k = n & 0x7F
        guard k >= 1, k <= 4, i + k <= b.count else { fail("bad or indefinite length at \(i)") }
        n = 0
        for _ in 0..<k {
            n = n << 8 | Int(b[i])
            i += 1
        }
    }
    guard i + n <= b.count else { fail("length past the end at \(i)") }
    let end = i + n
    if tag & 0x20 == 0 {
        defer { i = end }
        return .primitive(tag, Array(b[i..<end]))
    }
    var children: [Node] = []
    while i < end {
        children.append(parse(b, &i))
    }
    guard i == end else { fail("child overran its parent") }
    return .constructed(tag, children)
}

func read(_ path: String) -> [UInt8] {
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return Array(d)
}

func write(_ bytes: [UInt8], _ path: String) {
    guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else { fail("cannot write \(path)") }
}

/// ContentInfo -> [0] -> SignedData; the signerInfos set is its last child.
func signedData(_ root: Node) -> [Node] {
    let explicit = root.children
    guard explicit.count == 2, explicit[1].tag == 0xA0 else { fail("not a ContentInfo") }
    let sd = explicit[1].children
    guard sd.count == 1, sd[0].tag == 0x30 else { fail("no SignedData") }
    return sd[0].children
}

func rebuild(_ root: Node, signedData sd: [Node]) -> Node {
    let explicit = root.children
    return .constructed(root.tag, [explicit[0], .constructed(0xA0, [.constructed(0x30, sd)])])
}

func load(_ path: String) -> Node {
    let b = read(path)
    var i = 0
    let root = parse(b, &i)
    guard i == b.count else { fail("trailing bytes in \(path)") }
    return root
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "signature" where args.count == 3:
    let sd = signedData(load(args[1]))
    guard let set = sd.last, set.tag == 0x31, let signer = set.children.first else { fail("no signer") }
    guard let sig = signer.children.last(where: { $0.tag == 0x04 }), case .primitive(_, let v) = sig else {
        fail("no signature value")
    }
    write(v, args[2])
case "add-token" where args.count == 4:
    let root = load(args[1])
    var sd = signedData(root)
    var tokenIndex = 0
    let token = parse(read(args[2]), &tokenIndex)
    guard let set = sd.last, set.tag == 0x31, !set.children.isEmpty else { fail("no signer") }
    var signers = set.children
    var fields = signers[0].children
    guard fields.last?.tag != 0xA1 else { fail("signer 0 already has unsigned attributes") }
    // id-aa-timeStampToken, 1.2.840.113549.1.9.16.2.14 (RFC 3161 appendix A).
    let oid = Node.primitive(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x0E])
    let attribute = Node.constructed(0x30, [oid, .constructed(0x31, [token])])
    fields.append(.constructed(0xA1, [attribute]))
    signers[0] = .constructed(signers[0].tag, fields)
    sd[sd.count - 1] = .constructed(0x31, signers)
    write(rebuild(root, signedData: sd).encoded(), args[3])
case "drop-signers" where args.count == 3:
    let root = load(args[1])
    var sd = signedData(root)
    guard sd.last?.tag == 0x31 else { fail("no signerInfos") }
    sd[sd.count - 1] = .constructed(0x31, [])
    write(rebuild(root, signedData: sd).encoded(), args[2])
default:
    fail("usage: der.swift signature|add-token|drop-signers ...")
}
