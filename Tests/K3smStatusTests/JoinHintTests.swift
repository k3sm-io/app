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

@testable import K3smStatus

struct JoinHintTests {
    /// The flags `k3sm install` declares, scraped from the CLI source.
    static func installFlags() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "cmd/k3sm/install.go")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "flag.NewFlagSet(\"install\""))
        var names = Set<String>()
        for line in source[start.upperBound...].split(separator: "\n") {
            if line.contains("fs.Parse(") { break }
            guard ["fs.StringVar(", "fs.BoolVar(", "fs.IntVar(", "fs.String(", "fs.Bool(", "fs.Int("].contains(where: { line.contains($0) }) else { continue }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 2, !parts[1].isEmpty { names.insert(String(parts[1])) }
        }
        try #require(names.contains("token-file") && !names.contains("token"), "the install flag scrape is stale")
        return names
    }

    /// Whether `command` is a runnable `k3sm install` line: only flags the CLI declares.
    static func runsAsInstall(_ command: String, flags: Set<String>) -> Bool {
        var words = command.split(separator: " ").map(String.init)
        if words.first == "sudo" { words.removeFirst() }
        if let first = words.first, first == "k3sm" || first.hasSuffix("/k3sm") { words.removeFirst() } else { return false }
        guard words.first == "install" else { return false }
        return words.dropFirst().filter { $0.hasPrefix("-") }.allSatisfy {
            flags.contains(String($0.drop(while: { $0 == "-" }).split(separator: "=").first ?? ""))
        }
    }

    /// Backquoted spans in `text`.
    static func spans(_ text: String) -> [String] {
        text.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    @Test("every join command the app can show runs as written or is labelled as text to paste")
    func joinCommandHintIsRunnable() throws {
        let flags = try Self.installFlags()
        let errors: [JoinPasteError] = [.empty, .tooLong, .unsafeCharacter, .unbalancedQuote, .notAJoinCommand, .missingServer,
                                        .missingToken, .tokenInFile, .invalidToken, .invalidServer,
                                        .unsupportedOption("--node-ip"), .conflicting]
        var texts = errors.map(\.message)
        texts += FirstRunPath.allCases.map(\.detail)
        texts.append(JoinHints.prompt)
        texts.append(FirstRunFlow.finish(path: .join, outcome: .failed("x"), log: "").lines.joined(separator: "\n"))
        if let command = FirstRunFlow.terminalCommand(path: .join, serverArgument: "studio.local", payload: nil) {
            texts += command.split(separator: "\n").map { "`\($0)`" }
        }
        for text in texts {
            for span in Self.spans(text) where span.contains("k3sm install") || span.contains("--token") {
                #expect(Self.runsAsInstall(span, flags: flags) && !span.contains("--token "), "\(span)")
            }
            #expect(!text.contains("--token <"), "\(text)")
        }
        for s in JoinHints.suggestions {
            switch s.use {
            case .terminal:
                if s.text.contains("k3sm install") {
                    #expect(Self.runsAsInstall(s.text, flags: flags), "\(s.text)")
                    #expect(s.text.contains("--token-file"))
                }
            case .pasteIntoApp:
                #expect(s.label.contains(JoinHints.pasteLabel), "\(s.text)")
                #expect(JoinCommandParser.parse(s.text.replacingOccurrences(of: "K10…", with: "K10aa::u:s")).isSuccess, "\(s.text)")
            }
        }
        #expect(JoinHints.pasteLabel == "to paste into this window, not Terminal")
        #expect(JoinHints.pasteExample.contains(JoinHints.pasteLabel))
        #expect(JoinPasteError.notAJoinCommand.message.contains(JoinHints.pasteLabel))
        #expect(JoinHints.terminalJoin.contains("--token-file") && !JoinHints.terminalJoin.contains("--token "))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
