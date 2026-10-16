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

/// StatusInterconnect is the full report's additive `interconnect` block:
/// the cluster's cable network beside the mesh, as k3sm reads its
/// Interconnect object. Every field decodes tolerantly: a missing or
/// mistyped one reads as empty, zero or false, and an `armed` that is not
/// `true` is never read as armed.
public struct StatusInterconnect: Decodable, Equatable, Sendable {
    /// The medium, e.g. "thunderbolt".
    public let name: String
    /// Whether an admin enabled it; nothing gets an address until one does.
    public let armed: Bool
    public let armedBy: String
    /// True whenever it is armed: opted-in pod traffic crosses the cable unencrypted.
    public let plaintext: Bool
    /// How many cabled nodes the server resolved, and how many are usable.
    public let members: Int
    public let up: Int
    /// How many islands of mutually reachable members there are.
    public let segments: Int
    /// The cabled nodes whose index is past the address range.
    public let outOfRange: [String]
    /// How many pods hold an interconnect address.
    public let pods: Int

    public init(name: String, armed: Bool, armedBy: String = "", plaintext: Bool, members: Int, up: Int,
                segments: Int, outOfRange: [String] = [], pods: Int = 0) {
        self.name = name
        self.armed = armed
        self.armedBy = armedBy
        self.plaintext = plaintext
        self.members = members
        self.up = up
        self.segments = segments
        self.outOfRange = outOfRange
        self.pods = pods
    }

    private enum CodingKeys: String, CodingKey { case name, armed, armedBy, plaintext, members, up, segments, outOfRange, pods }

    private struct Ignored: Decodable {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        armed = (try? c.decodeIfPresent(Bool.self, forKey: .armed)) == true
        armedBy = (try? c.decodeIfPresent(String.self, forKey: .armedBy)) ?? ""
        plaintext = (try? c.decodeIfPresent(Bool.self, forKey: .plaintext)) == true
        members = max(0, (try? c.decodeIfPresent(Int.self, forKey: .members)) ?? 0)
        up = max(0, (try? c.decodeIfPresent(Int.self, forKey: .up)) ?? 0)
        segments = max(0, (try? c.decodeIfPresent(Int.self, forKey: .segments)) ?? 0)
        outOfRange = ((try? c.decodeIfPresent([String].self, forKey: .outOfRange)) ?? nil) ?? []
        pods = ((try? c.decodeIfPresent([Ignored].self, forKey: .pods)) ?? nil)?.count ?? 0
    }
}

/// InterconnectCard is the navy panel's Interconnect block, shown only
/// while the full report carries an armed interconnect. Every string is
/// clipped.
public struct InterconnectCard: Equatable, Sendable {
    /// The block's value on the right: the medium.
    public let medium: String
    /// "2 of 3 nodes up".
    public let nodes: String
    /// "1 segment", "2 segments".
    public let segments: String
    /// "2 pods attached", "no pods attached".
    public let pods: String
    /// The plaintext warning, nil when k3sm does not say the traffic is plaintext.
    public let warning: String?
    /// "Out of range: far, other", nil when every cabled node has an address.
    public let outOfRange: String?

    public static let plaintextWarning = "Pod traffic on the cable is not encrypted."

    /// The card for the report, or nil when there is no block or it is not armed.
    public static func card(for report: StatusReport?) -> InterconnectCard? {
        guard let ic = report?.interconnect, ic.armed else { return nil }
        let names = ic.outOfRange.map(StatusDisplay.clip)
        return InterconnectCard(
            medium: StatusDisplay.clip(ic.name.isEmpty ? "armed" : ic.name),
            nodes: "\(ic.up) of \(ic.members) \(ic.members == 1 ? "node" : "nodes") up",
            segments: "\(ic.segments) \(ic.segments == 1 ? "segment" : "segments")",
            pods: ic.pods == 0 ? "no pods attached" : "\(ic.pods) \(ic.pods == 1 ? "pod" : "pods") attached",
            warning: ic.plaintext ? plaintextWarning : nil,
            outOfRange: names.isEmpty ? nil : StatusDisplay.clip("Out of range: " + names.joined(separator: ", ")))
    }
}
