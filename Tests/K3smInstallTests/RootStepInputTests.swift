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

@testable import K3smInstall

@Suite("console user")
struct ConsoleUserTests {
    @Test("accepted", arguments: ["alice", "a", "_svc", "first.last", "me-2", "A1"])
    func valid(_ s: String) {
        #expect(ConsoleUser(s)?.name == s)
    }

    @Test("refused", arguments: ["", "root", "-n", ".hidden", "two words", "a'b", "$(id)", "ünï", "a\nb",
                                 String(repeating: "a", count: 256)])
    func invalid(_ s: String) {
        #expect(ConsoleUser(s) == nil)
    }
}

@Suite("worker join target")
struct AgentJoinTargetTests {
    static func plist(_ args: [String]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "io.k3sm.agent", "ProgramArguments": args], format: .xml, options: 0)
    }

    @Test("the plist path is the agent daemon's")
    func path() {
        #expect(AgentJoinTarget.plistPath == "/Library/LaunchDaemons/io.k3sm.agent.plist")
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let args: [String]
        let want: String?
        let error: AgentJoinTarget.ReadError?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "separate word", args: ["/Library/k3sm/k3sm", "agent", "--server", "studio.local", "--node-ip", "100.64.1.1"],
             want: "studio.local", error: nil),
        Case(name: "single dash", args: ["/Library/k3sm/k3sm", "agent", "-server", "192.168.0.50"], want: "192.168.0.50", error: nil),
        Case(name: "equals form", args: ["/Library/k3sm/k3sm", "agent", "--server=studio.local"], want: "studio.local", error: nil),
        Case(name: "bare IPv6", args: ["k3sm", "agent", "--server", "fd00::1"], want: "fd00::1", error: nil),
        Case(name: "first flag wins, as in the CLI", args: ["k3sm", "agent", "--server", "a.local", "--server", "b.local"],
             want: "a.local", error: nil),
        Case(name: "no server flag", args: ["k3sm", "agent"], want: nil, error: .noServerFlag),
        Case(name: "flag without a value", args: ["k3sm", "agent", "--server"], want: nil, error: .noServerFlag),
        Case(name: "hostile value", args: ["k3sm", "agent", "--server", "$(id)"], want: nil, error: .invalidServer(.invalidCharacter)),
        Case(name: "a port is refused", args: ["k3sm", "agent", "--server", "studio.local:6443"], want: nil,
             error: .invalidServer(.unsupportedPort(6443))),
    ]

    @Test("read", arguments: cases)
    func read(_ c: Case) throws {
        let data = try Self.plist(c.args)
        if let error = c.error {
            #expect(throws: error) { try AgentJoinTarget.read(plist: data) }
        } else {
            #expect(try AgentJoinTarget.read(plist: data).argument == c.want)
        }
    }

    @Test("not a plist, or no arguments")
    func malformed() throws {
        #expect(throws: AgentJoinTarget.ReadError.notAPlist) { try AgentJoinTarget.read(plist: Data("<?xml version=\"1.0\"?><plist><dict><key>".utf8)) }
        let noArgs = try PropertyListSerialization.data(fromPropertyList: ["Label": "x"], format: .xml, options: 0)
        #expect(throws: AgentJoinTarget.ReadError.noProgramArguments) { try AgentJoinTarget.read(plist: noArgs) }
    }
}

@Suite("uninstall request")
struct UninstallRequestTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("purge is unavailable today")
    func purgeUnavailable() {
        #expect(CopyOutAction.purgeUnavailableReason != nil)
    }

    @Test("no purge action while purgeUnavailableReason is set")
    func refusesPurge() {
        #expect(CopyOutAction.uninstall(requestingPurge: true) == nil)
        #expect(CopyOutAction.uninstall(requestingPurge: true, purgeUnavailableReason: "not yet") == nil)
        #expect(CopyOutAction.uninstall(requestingPurge: false) == .uninstall(purge: false))
    }

    @Test("purge becomes buildable only once the reason is cleared")
    func purgeOnceAvailable() {
        #expect(CopyOutAction.uninstall(requestingPurge: true, purgeUnavailableReason: nil) == .uninstall(purge: true))
    }

    @Test("the app never constructs an uninstall action directly")
    func appGoesThroughTheRequest() throws {
        let dir = Self.root.appending(path: "Sources/K3smApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var sawRequest = false
        for url in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains(".uninstall(purge"), "\(url.lastPathComponent) builds .uninstall(purge:) directly")
            if text.contains("CopyOutAction.uninstall(requestingPurge:") { sawRequest = true }
        }
        #expect(sawRequest)
    }
}
