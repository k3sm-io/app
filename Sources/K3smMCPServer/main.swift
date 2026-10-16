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
import K3smHost
import K3smInstall
import K3smMCP
import K3smStatus

// k3sm-mcp: the read-only k3sm MCP server, on the stdio transport. An MCP
// client (Claude Code, after `claude mcp add`) starts it and talks
// newline-delimited JSON-RPC on standard input and output. Every read runs
// the installed CLI by absolute path, after a fresh trust check, with an
// environment built from this user's passwd entry; nothing in the
// environment the client passed reaches the CLI. Standard output carries
// replies only; this line on standard error is the only other output.

signal(SIGPIPE, SIG_IGN)

let team = TeamIDPin.teamID
let environment = InstalledCLI.environment()
let reader: ClusterReader = { request in
    // A cancelled call runs nothing more; CLIProcess kills a run in flight.
    guard !Task.isCancelled else { return .killed }
    let trusted = TrustedCLI<CLIOutcome>(
        check: { InstalledCLI.trust(team: team) },
        execute: { arguments in
            await CLIProcess.run(
                path: K3smCLI.path, arguments: arguments, environment: environment,
                deadline: request.deadline, limit: request.limit, keepErrors: request.keepErrors)
        })
    guard FileManager.default.fileExists(atPath: K3smCLI.path) else { return .missing }
    switch await trusted.run(request.arguments) {
    case .refused(let why): return .refused(why)
    case .ran(.missing): return .missing
    case .ran(.refused(let why)): return .refused(why)
    case .ran(.failedToLaunch): return .failedToLaunch
    case .ran(.killed): return .killed
    case .ran(.truncated): return .truncated
    case .ran(.exited(let status, let stdout)): return .exited(status: status, stdout: stdout)
    }
}

let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
let server = MCPServer(
    info: ServerInfo(version: version),
    tools: ClusterTools(read: reader, appVersion: Bundle.main.bundleIdentifier == nil ? nil : version),
    log: InstalledCLI.home().flatMap(CallLog.forHome))
FileHandle.standardError.write(Data("k3sm-mcp \(version): read-only tools on stdio\n".utf8))
await StdioTransport.serve(server, input: .standardInput, output: .standardOutput)
