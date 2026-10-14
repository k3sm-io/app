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

    static func resolved(_ status: String?, plist: [String]? = nil) throws -> Result<String, AgentJoinTarget.ReadError> {
        let data = try plist.map(Self.plist)
        return AgentJoinTarget.resolve(statusJoinTarget: status, plist: { data }).map(\.argument)
    }

    @Test("the status joinTarget wins and drops the port")
    func statusTarget() throws {
        #expect(try Self.resolved("192.0.2.10:9345") == .success("192.0.2.10"))
        #expect(try Self.resolved("studio.local:9345", plist: ["k3sm", "agent", "--server", "other.local"]) == .success("studio.local"))
    }

    @Test("the plist is read only when the field is absent")
    func plistFallback() throws {
        #expect(try Self.resolved(nil, plist: ["k3sm", "agent", "--server", "studio.local"]) == .success("studio.local"))
        #expect(try Self.resolved(nil) == .failure(.notAPlist))
        #expect(try Self.resolved(nil, plist: ["k3sm", "agent"]) == .failure(.noServerFlag))
    }

    @Test("a present but malformed joinTarget is refused, never replaced by the plist",
          arguments: ["", "studio.local", "studio.local:", ":9345", "a:b:9345", "[fd00::1]:9345", "$(id):9345", "studio.local:93x"])
    func malformedStatusTarget(_ text: String) throws {
        let plist = ["k3sm", "agent", "--server", "other.local"]
        #expect(try Self.resolved(text, plist: plist) == .failure(.invalidStatusTarget))
    }
}

@Suite("uninstall request")
struct UninstallRequestTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the purge action is the one the window builds from its checkbox")
    func purgeFollowsTheCheckbox() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.root.appending(path: "Sources/K3smApp"), includingPropertiesForKeys: nil)
        let model = try #require(files.first { $0.lastPathComponent == "AppModel.swift" })
        let text = try String(contentsOf: model, encoding: .utf8)
        #expect(text.contains(".uninstall(purge: purge)"))
    }

    @Test("no purge-unavailable gate remains anywhere in the sources")
    func noGate() throws {
        for dir in ["Sources/K3smApp", "Sources/K3smInstall"] {
            let url = Self.root.appending(path: dir)
            for file in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("purgeUnavailable"), "\(file.lastPathComponent) still gates the purge")
            }
        }
    }

    @Test("the purge prompt says the data is deleted, the plain one that it is kept")
    func prompts() {
        #expect(CopyOutAction.uninstall(purge: true).prompt.contains("delete its data"))
        #expect(CopyOutAction.uninstall(purge: false).prompt.contains("keep its data"))
    }
}
