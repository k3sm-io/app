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

/// NetworkPaneFacts is the text the Settings window's Network pane shows
/// beside the LAN switch, from the status JSON's `network` object and, when
/// the console has read it, this Mac's node in the node list. Every value
/// from the CLI or the cluster is clipped.
public enum NetworkPaneFacts {
    /// The pane's line on a Mac whose role has no switch, or no install.
    public static let noSwitchText = "This Mac runs no k3sm node, so it has no network settings."

    /// The current state: what k3sm serves when the report carries it (an
    /// administrator's read), else the recorded setting; "unknown" for a
    /// value the app does not know.
    public static func stateLine(_ network: LANAccess) -> String {
        if network.setting == .unknown || network.recordState == .unknown {
            return "Now: unknown"
        }
        if let applied = network.applied, applied.setting != .unknown {
            return "Now: \(applied.setting.word), as k3sm serves it"
        }
        if !network.recorded {
            return "Now: on, since no setting is recorded"
        }
        return "Now: \(network.setting.word), as recorded"
    }

    /// The lines under the switch: the state, the listeners it controls,
    /// those it never closes, and the address this node answers on when the
    /// node list names one. Empty with no report; `noSwitchText` alone on a
    /// Mac with no switch.
    public static func lines(report: StatusReport?, nodes: [ClusterNode]?) -> [String] {
        guard let report else { return [] }
        guard report.hasLANSwitch else { return [noSwitchText] }
        let network = report.network
        var out = [stateLine(network)]
        if !network.covers.isEmpty {
            out.append("The switch controls: " + list(network.covers))
        }
        if let always = network.alwaysOn, !always.isEmpty {
            out.append("Always open to the network: " + list(always))
        }
        if let address = address(report: report, nodes: nodes) {
            switch network.applied?.setting ?? network.setting {
            case .on: out.append("Other devices reach this node at " + address)
            case .off: out.append("This node's address is \(address); workloads there answer only this Mac and the cluster mesh")
            case .unknown: out.append("This node's address is " + address)
            }
        }
        return out
    }

    /// This Mac's node's InternalIP from the node list, clipped; nil when
    /// the report names no node of this Mac or the list has no address for it.
    public static func address(report: StatusReport, nodes: [ClusterNode]?) -> String? {
        guard let own = ClusterDisplay.ownNodeName(report),
              let ip = nodes?.first(where: { $0.name == own })?.internalIP else { return nil }
        let clipped = StatusDisplay.clip(ip)
        return clipped.isEmpty ? nil : clipped
    }

    private static func list(_ words: [String]) -> String {
        StatusDisplay.clip(words.map(StatusDisplay.clip).joined(separator: ", "))
    }
}
