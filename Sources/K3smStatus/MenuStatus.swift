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

/// MenuHealth is one status line of the status item's menu: ok, degraded,
/// down, or unknown when there is nothing to judge.
public enum MenuHealth: Equatable, Sendable {
    case ok
    case degraded
    case down
    case unknown

    /// The word shown after the label and read by accessibility, so the
    /// circle's colour is never the only signal.
    public var word: String {
        switch self {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .down: return "down"
        case .unknown: return "unknown"
        }
    }
}

/// MenuStatus decides the two status lines at the top of the status item's
/// menu, "Cluster" and "This Mac", and their text.
public enum MenuStatus {
    public static let clusterLabel = "Cluster"
    public static let thisMacLabel = "This Mac"

    /// The line's title: the label, a middle dot, then the health word.
    public static func title(_ label: String, _ health: MenuHealth) -> String {
        label + " · " + health.word
    }

    /// The line's accessibility description: "Cluster: ok".
    public static func accessibilityText(_ label: String, _ health: MenuHealth) -> String {
        label + ": " + health.word
    }

    /// This Mac from the report's verdict: running is ok, degraded is
    /// degraded, stopped or not installed is down. A failed read is down;
    /// no report yet, or a verdict word k3sm did not commit to, is unknown.
    public static func thisMac(of report: StatusReport?, readFailed: Bool = false) -> MenuHealth {
        guard let report else { return readFailed ? .down : .unknown }
        switch report.verdict {
        case .running: return .ok
        case .degraded: return .degraded
        case .stopped, .notInstalled: return .down
        case .unknown, .unrecognized: return .unknown
        }
    }

    /// The cluster from the `node` row, on a server or a worker alike: its
    /// leading "a/b nodes ready" is ok when every node is ready, degraded
    /// when some are, and down when none is; a row saying the apiserver is
    /// unreachable is down. No report, no row, or a detail in another shape
    /// is unknown.
    public static func cluster(of report: StatusReport?) -> MenuHealth {
        guard let row = report?.row(named: "node") else { return .unknown }
        if row.detail.contains("apiserver unreachable") {
            return .down
        }
        guard let (ready, total) = nodesReady(row.detail) else { return .unknown }
        if ready == 0 { return .down }
        return ready == total ? .ok : .degraded
    }

    /// Parses "a/b nodes ready" from the start of a `node` row's detail;
    /// nil unless both are plain decimal counts with 0 <= a <= b and b > 0.
    static func nodesReady(_ detail: String) -> (Int, Int)? {
        let head = (detail.components(separatedBy: " · ").first ?? "").trimmingCharacters(in: .whitespaces)
        let suffix = " nodes ready"
        guard head.hasSuffix(suffix) else { return nil }
        let parts = head.dropLast(suffix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              let ready = Int(parts[0]), let total = Int(parts[1]), total > 0, ready <= total else { return nil }
        return (ready, total)
    }
}
