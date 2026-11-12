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
import Testing

/// Reads the tests' own sources, signs nothing and runs nothing: fixtures
/// are signed only by each target's fixture store, and no swap fixture tree
/// is removed while a test process runs except at the listed sites.
@Suite struct SwapFixtureGuardTests {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let this = "K3smSwapTests/SwapFixtureGuardTests.swift"

    /// Every Swift file under `Tests/`, relative to it.
    static let sources: [String] = {
        let all = FileManager.default.enumerator(atPath: tests.path)?.compactMap { $0 as? String } ?? []
        return all.filter { $0.hasSuffix(".swift") && $0 != this }.sorted()
    }()

    /// A codesign invocation: by absolute path, or by name through a launcher.
    static let signing = ["/usr/bin/" + "codesign\"", "\"" + "codesign\""]
    /// A removal of a tree or of a file in it, in any spelling.
    static let removals = [".remove" + "Item(", "\"/bin/" + "rm\"", "remove" + "file(", "rm" + "dir(", "un" + "link(",
                           "trash" + "Item("]

    /// Every allowed site: (file, a substring of its line, how many times).
    static let allowedSigning: [(String, String, Int)] = [
        ("K3smSwapTests/FixtureStore.swift", "run(\"/usr/bin/codesign\", [\"--force\"", 1),
        ("K3smInstallTests/AdminFixtureStore.swift", "run(\"/usr/bin/codesign\", [\"--force\"", 1),
        // A stub script named codesign, written for the root script to call.
        ("K3smInstallTests/AppSwapRootScriptRunTests.swift", "try stub(\"/usr/bin/codesign\"", 1),
        // A search of script text for the word.
        ("K3smInstallTests/DeveloperModeTrustTests.swift", "!text.contains(\"codesign\")", 1),
    ]
    static let allowedRemoval: [(String, String, Int)] = [
        // A later run's bounded sweep of a gone process's old trees.
        ("K3smSwapTests/FixtureStore.swift", "run(\"/bin/rm\", [\"-rfx\", path])", 1),
        ("K3smInstallTests/AdminFixtureStore.swift", "run(\"/bin/rm\", [\"-rfx\", path])", 1),
        // A partial copy a failed place just made, never verified in place.
        ("K3smSwapTests/FixtureStore.swift", "try? fm.removeItem(atPath: path)", 1),
        ("K3smInstallTests/AdminFixtureStore.swift", "try? fm.removeItem(atPath: path)", 1),
        // Scratch disk images and their empty mount points, after the detach.
        ("K3smInstallTests/AppSwapRootTests.swift", "(image as NSString).deletingLastPathComponent", 1),
        ("K3smSwapTests/ReviewFixTests.swift", "run(\"/bin/rm\", [\"-rfx\", work])", 1),
        // The product's helper copy, replaced one file at a time by the test.
        ("K3smSwapTests/SwapEngineTests.swift", "unlink(s.paths.helperCopyPath)", 2),
        ("K3smSwapTests/SwapEngineTests.swift", "unlink(s.root + \"/second-link\")", 1),
    ]

    /// A free `remove(` call, not a collection's method.
    static func callsRemove(_ line: String) -> Bool {
        line.ranges(of: "remove(").contains { range in
            guard range.lowerBound > line.startIndex else { return true }
            let before = line[line.index(before: range.lowerBound)]
            return !(before.isLetter || before.isNumber || before == "_" || before == ".")
        }
    }

    /// Whether a file's removals are checked: it makes swap fixtures.
    static func makesSwapFixtures(_ text: String) -> Bool {
        ["FixtureStore", "FixtureTrees", "makeBundle("].contains(where: text.contains)
    }

    /// The file's lines with every comment taken out (whole-line, trailing
    /// and block), string literals kept.
    static func code(_ text: String) -> [String] {
        var out = ""
        var chars = Array(text)[...]
        var inBlock = 0
        var string: String?  // the closing delimiter of the literal we are in
        while let c = chars.first {
            if inBlock > 0 {
                if chars.starts(with: "*/") { inBlock -= 1; chars = chars.dropFirst(2); continue }
                if chars.starts(with: "/*") { inBlock += 1; chars = chars.dropFirst(2); continue }
                if c == "\n" { out.append(c) }
                chars = chars.dropFirst()
                continue
            }
            if let close = string {
                if !close.hasSuffix("#"), c == "\\", chars.count > 1 {
                    out.append(contentsOf: chars.prefix(2))
                    chars = chars.dropFirst(2)
                    continue
                }
                if chars.starts(with: close) {
                    out.append(contentsOf: close)
                    chars = chars.dropFirst(close.count)
                    string = nil
                    continue
                }
                out.append(c)
                chars = chars.dropFirst()
                continue
            }
            if chars.starts(with: "//") {
                while let d = chars.first, d != "\n" { chars = chars.dropFirst() }
                continue
            }
            if chars.starts(with: "/*") {
                inBlock = 1
                chars = chars.dropFirst(2)
                continue
            }
            if let open = ["#\"\"\"", "#\"", "\"\"\"", "\""].first(where: { chars.starts(with: $0) }) {
                string = open.hasPrefix("#") ? String(open.dropFirst()) + "#" : open
                out.append(contentsOf: open)
                chars = chars.dropFirst(open.count)
                continue
            }
            out.append(c)
            chars = chars.dropFirst()
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func FixtureSigningAndRemovalSitesAreAllowListed() throws {
        #expect(Self.sources.contains("K3smSwapTests/FixtureStore.swift"))
        #expect(Self.sources.contains("K3smInstallTests/AdminFixtureStore.swift"))
        #expect(Self.sources.contains("K3smInstallTests/AppSwapRootTests.swift"))
        var signs: [(String, String)] = []
        var removes: [(String, String)] = []
        for file in Self.sources {
            let text = try String(contentsOf: Self.tests.appendingPathComponent(file), encoding: .utf8)
            let checkRemovals = Self.makesSwapFixtures(text)
            for line in Self.code(text) {
                if Self.signing.contains(where: line.contains) { signs.append((file, line)) }
                if checkRemovals, Self.removals.contains(where: line.contains) || Self.callsRemove(line) {
                    removes.append((file, line))
                }
            }
        }
        for (label, found, allowed) in [("codesign", signs, Self.allowedSigning), ("removal", removes, Self.allowedRemoval)] {
            for (file, line) in found where !allowed.contains(where: { $0.0 == file && line.contains($0.1) }) {
                Issue.record("\(label) outside the allow-list, \(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
            for (file, marker, count) in allowed {
                let n = found.filter { $0.0 == file && $0.1.contains(marker) }.count
                #expect(n == count, "\(label) site \(file) [\(marker)] appears \(n) times, not \(count)")
            }
        }
    }

    @Test func commentsAreIgnoredAndStringsKept() {
        let lines = Self.code("a // x\n/* b\n c */ d \"// e\" /* f */ g\n")
        #expect(lines == ["a ", "", " d \"// e\"  g", ""])
    }
}
