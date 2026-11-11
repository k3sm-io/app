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

/// Reads the swap tests' own sources, signs nothing and runs nothing: the
/// fixtures are signed in one place per target, once per content, and no
/// fixture tree is removed while a test process runs.
@Suite struct SwapFixtureGuardTests {
    /// The sources this guard reads, relative to `Tests/`.
    static let sources: [String] = {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let swap = (try? FileManager.default.contentsOfDirectory(atPath: tests.path + "/K3smSwapTests")) ?? []
        return swap.filter { $0.hasSuffix(".swift") && $0 != "SwapFixtureGuardTests.swift" }.map { "K3smSwapTests/" + $0 }
            + ["K3smInstallTests/AppSwapRootTests.swift", "K3smInstallTests/AdminFixtureStore.swift"]
    }()

    /// A codesign invocation: the program name closing a string literal.
    static let signing = "codesign" + "\""
    /// A removal of a tree or a file in it.
    static let removals = [".remove" + "Item(", "\"/bin/" + "rm\"", "remove" + "file(", "rm" + "dir("]

    /// Every site allowed, as (file, a substring of its line); each must
    /// appear exactly once.
    static let allowedSigning = [
        ("K3smSwapTests/FixtureStore.swift", "let status = run("),
        ("K3smInstallTests/AdminFixtureStore.swift", "let status = run("),
    ]
    static let allowedRemoval = [
        // The later run's sweep of old trees, never across a mount.
        ("K3smSwapTests/FixtureStore.swift", "-rfx"),
        ("K3smInstallTests/AdminFixtureStore.swift", "-rfx"),
        // A scratch disk image's directory, after it is detached.
        ("K3smInstallTests/AppSwapRootTests.swift", "(image as NSString).deletingLastPathComponent"),
    ]

    static func code(_ file: String) throws -> [String] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: tests.appendingPathComponent(file), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test func SwapFixturesAreSignedOnceAndKeptUntilExit() throws {
        #expect(Self.sources.contains("K3smSwapTests/FixtureStore.swift"))
        #expect(Self.sources.contains("K3smSwapTests/Support.swift"))
        var signs: [(String, String)] = []
        var removes: [(String, String)] = []
        for file in Self.sources {
            for line in try Self.code(file) {
                if line.contains(Self.signing) { signs.append((file, line)) }
                if Self.removals.contains(where: line.contains) { removes.append((file, line)) }
            }
        }
        for (label, found, allowed) in [("codesign", signs, Self.allowedSigning), ("removal", removes, Self.allowedRemoval)] {
            for (file, line) in found where !allowed.contains(where: { $0.0 == file && line.contains($0.1) }) {
                Issue.record("\(label) outside the fixture store's allow-list, \(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
            for (file, marker) in allowed {
                let n = found.filter { $0.0 == file && $0.1.contains(marker) }.count
                #expect(n == 1, "\(label) site \(file) [\(marker)] appears \(n) times")
            }
        }
    }
}
