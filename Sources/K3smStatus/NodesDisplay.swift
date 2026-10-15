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

/// NodeLine is one node row of the console panel: a name, a role word and a
/// version, each already clipped for the screen.
public struct NodeLine: Equatable, Sendable {
    public let name: String
    public let role: String
    public let version: String

    public init(name: String, role: String, version: String) {
        self.name = name
        self.role = role
        self.version = version
    }
}

/// NodesView is what the panel's nodes block shows: the ready count from the
/// `node` row, one line per known node with this Mac first, and a note for
/// what the report cannot say.
public struct NodesView: Equatable, Sendable {
    /// The `node` row's ready count ("2/2 nodes ready"), nil without the row.
    public let heading: String?
    public let lines: [NodeLine]
    /// "No other nodes", or why the other nodes are not listed; nil when
    /// they are listed.
    public let note: String?

    public init(heading: String?, lines: [NodeLine], note: String?) {
        self.heading = heading
        self.lines = lines
        self.note = note
    }
}

/// NodesDisplay turns a status report into the panel's nodes block. On a
/// server the other nodes come from `workers`: absent is unknown, never
/// "none", and empty is no other node. On a worker the second line is the
/// server it joined, from `joinTarget`. Every string from the CLI is clipped.
public enum NodesDisplay {
    public static let thisMac = "This Mac"
    public static let versionUnknown = "version unknown"
    public static let noOtherNodes = "No other nodes"
    public static let othersUnknown = "Other nodes unknown: the apiserver did not answer"
    public static let serverUnknown = "The server this Mac joined is not known yet"

    /// Builds the block from a report and this Mac's installed version (the
    /// `k3sm version` the window already reads).
    public static func view(report: StatusReport, installed: SemanticVersion?) -> NodesView {
        let role = NodeRole.detect(in: report)
        let mine = NodeLine(
            name: thisMac,
            role: roleWord(role?.rawValue ?? report.role),
            version: installed?.description ?? versionUnknown)
        let heading = report.row(named: "node").map { readyCount($0.detail) }

        if role == .agent {
            guard let target = report.joinTarget else {
                return NodesView(heading: heading, lines: [mine], note: serverUnknown)
            }
            let server = NodeLine(name: StatusDisplay.clip(host(of: target)), role: NodeRole.server.rawValue, version: versionUnknown)
            return NodesView(heading: heading, lines: [mine, server], note: nil)
        }

        guard let workers = report.workers else {
            return NodesView(heading: heading, lines: [mine], note: othersUnknown)
        }
        if workers.isEmpty {
            return NodesView(heading: heading, lines: [mine], note: noOtherNodes)
        }
        let others = workers.sorted { $0.name < $1.name }.map {
            NodeLine(name: StatusDisplay.clip($0.name), role: roleWord($0.role), version: version(of: $0))
        }
        return NodesView(heading: heading, lines: [mine] + others, note: nil)
    }

    /// The role word as printed, or "role unknown" when there is none.
    static func roleWord(_ word: String) -> String {
        word.isEmpty ? "role unknown" : StatusDisplay.clip(word)
    }

    /// The k3sm release when the kubelet version carries one, else the
    /// version as printed, else "version unknown".
    static func version(of worker: StatusWorker) -> String {
        if let release = worker.k3smRelease { return release.description }
        guard let raw = worker.version else { return versionUnknown }
        return StatusDisplay.clip(raw)
    }

    /// The part of the `node` row's detail before the first " · ", which is
    /// the ready count when the apiserver answered.
    static func readyCount(_ detail: String) -> String {
        let head = detail.components(separatedBy: " · ").first ?? detail
        return StatusDisplay.clip(head.trimmingCharacters(in: .whitespaces))
    }

    /// The host of a `host:port` join target, for display only: brackets
    /// around an IPv6 literal are dropped, and a trailing port is dropped
    /// when the rest holds no other colon. Anything else is shown as printed.
    static func host(of target: String) -> String {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            return String(target[target.index(after: target.startIndex)..<close])
        }
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit) {
            return String(parts[0])
        }
        return target
    }
}
