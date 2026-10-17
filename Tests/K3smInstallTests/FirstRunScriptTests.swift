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

import K3smInstall
import K3smStatus
import Testing

@Suite("guided first run against the root step")
struct FirstRunScriptTests {
    static let team = TeamID("ABCDE12345")!
    static let version = SemanticVersion("0.2.0")!
    static let user = ConsoleUser("alice")!

    @Test("the progress markers are the lines the copy-out script writes, in order")
    func progressMarkersMatchTheScript() throws {
        let address = try ServerAddress(parsing: "studio.local")
        for action in [CopyOutAction.startServer, .join(address)] {
            let plan = try CopyOutPlan(bundlePath: "/Applications/k3sm.app", payloadVersion: Self.version,
                                       teamID: Self.team, user: Self.user, action: action)
            let lines = RootScriptBuilder.render(plan).text.split(separator: "\n").map(String.init)
            var last = -1
            for phase in FirstRunInstallPhase.allCases {
                guard let marker = phase.marker else { continue }
                let at = lines.firstIndex { $0.contains("echo '\(marker)") }
                #expect(at != nil, "\(phase) has no line in the script")
                if let at {
                    #expect(at > last, "\(phase) is out of order")
                    last = at
                }
            }
        }
        #expect(CopyOutOutcome(log: FirstRunFlow.exitPrefix + "0") == .succeeded)
        #expect(CopyOutOutcome(log: FirstRunFlow.exitPrefix + "77") == .failed(77))
    }

    @Test("a developer build's join command passes the flags the root step's join passes")
    func developerJoinCommandMatchesTheJoinArgv() throws {
        let address = try ServerAddress(parsing: "studio.local")
        let plan = try CopyOutPlan(bundlePath: "/Applications/k3sm.app", payloadVersion: Self.version,
                                   teamID: Self.team, user: Self.user, action: .join(address))
        let flags = RootScriptBuilder.arguments(for: plan).compactMap { arg -> String? in
            if case .literal(let s) = arg, s.hasPrefix("--agent") || s == "--server" || s == "--token-file" { return s }
            return nil
        }
        #expect(flags == ["--agent", "--server", "--token-file"])
        let command = try #require(FirstRunFlow.terminalCommand(path: .join, serverArgument: address.argument, payload: Self.version))
        // The token's root shell runs `"$1" install --agent --server "$2" --token-file <file>`
        // with the CLI and this host passed after `sh`.
        #expect(command.contains(#""$1" install --agent --server "$2" --token-file "#))
        #expect(command.contains("' sh ./k3sm \(address.argument);"))
        // A pasted command's address is the one ServerAddress takes.
        let token = "K10" + String(repeating: "0a", count: 32) + "::fixture:" + String(repeating: "e", count: 32)
        let paste = try JoinCommandParser.parse("sudo k3sm install --agent --server https://studio.local:9345/ --token \(token)").get()
        #expect(try ServerAddress(parsing: paste.server) == ServerAddress(parsing: "studio.local"))
    }
}
