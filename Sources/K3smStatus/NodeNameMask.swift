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
import Synchronization

/// NodeNameMask hides the cluster's node names from a demo recording. The
/// `--demo-mask` launch option, honoured only beside `--demo-tour`, turns it
/// on: every place the console shows a node's name then shows a masked name
/// instead. The control-plane node is `server` (a second and later one, in
/// name order, `server-2`, `server-3`); every other node, sorted by its real
/// name, is `worker-1`, `worker-2`, and so on. A name the last node list did
/// not carry shows as `node`, so a name read before the list never leaks.
/// Addresses, labels and every other field stay as they are. The mask
/// changes only what is drawn: selection, actions and a tour's row matches
/// keep the real names.
public enum NodeNameMask {
    /// The launch option that turns the mask on.
    public static let argument = "--demo-mask"
    /// The masked name of the control-plane node.
    public static let server = "server"
    /// The prefix of every other node's masked name.
    public static let worker = "worker"
    /// What a name the node list did not carry shows as.
    public static let unknown = "node"

    /// LaunchError is why the launch option was refused.
    public enum LaunchError: Error, Equatable {
        /// `--demo-mask` without `--demo-tour`.
        case withoutTour

        public var message: String {
            switch self {
            case .withoutTour: return "\(NodeNameMask.argument) needs \(DemoTour.argument)"
            }
        }
    }

    /// Whether the launch arguments ask for the mask. It throws when they
    /// name `--demo-mask` without `--demo-tour`: the mask is for the
    /// recording only.
    public static func requested(in arguments: [String]) throws -> Bool {
        let args = arguments.dropFirst()
        guard args.contains(argument) else { return false }
        guard args.contains(DemoTour.argument) else { throw LaunchError.withoutTour }
        return true
    }

    /// The masked name of every node, keyed by its real name.
    public static func make(nodes: [ClusterNode]) -> [String: String] {
        var mask: [String: String] = [:]
        let names = Set(nodes.map(\.name))
        let servers = Set(nodes.filter(\.controlPlane).map(\.name)).sorted()
        for (n, name) in servers.enumerated() {
            mask[name] = n == 0 ? server : "\(server)-\(n + 1)"
        }
        for (n, name) in names.subtracting(servers).sorted().enumerated() {
            mask[name] = "\(worker)-\(n + 1)"
        }
        return mask
    }

    /// The masked name of one node: its entry, else `unknown`.
    public static func apply(_ mask: [String: String], to name: String) -> String {
        mask[name] ?? unknown
    }

    /// A node address as the inspector shows it: an address that equals a
    /// node's real name (a `Hostname` address) is that node's masked name;
    /// any other address, an IP among them, stays as it is.
    public static func apply(_ mask: [String: String], toAddress address: String) -> String {
        mask[address] ?? address
    }

    /// Free text (an event's message, a pod's logs or manifest) with every
    /// real node name in it replaced by its masked name. A name is replaced
    /// only where it stands as a whole word: the characters on either side
    /// are not letters, digits, `-` or `_`. Longer names go first, so one
    /// name that is a part of another is never replaced inside it.
    public static func apply(_ mask: [String: String], toText text: String) -> String {
        var out = text
        for name in mask.keys.sorted(by: { ($0.count, $0) > ($1.count, $1) }) where !name.isEmpty {
            out = replaceWord(name, with: mask[name] ?? unknown, in: out)
        }
        return out
    }

    private static func replaceWord(_ word: String, with replacement: String, in text: String) -> String {
        var out = ""
        var rest = text[...]
        while let range = rest.range(of: word) {
            let before = range.lowerBound == rest.startIndex ? (out.last ?? " ") : rest[rest.index(before: range.lowerBound)]
            let after = range.upperBound == rest.endIndex ? " " : rest[range.upperBound]
            out += rest[..<range.lowerBound]
            out += isWord(before) || isWord(after) ? word : replacement
            rest = rest[range.upperBound...]
        }
        return out + rest
    }

    private static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_"
    }

    /// The process's mask: off, or on with the mapping of the last node list.
    private struct State: Sendable {
        var on = false
        var names: [String: String] = [:]
    }

    private static let state = Mutex(State())

    /// Turns the mask on for the rest of the process. The app calls it once
    /// at launch when `requested(in:)` says so.
    public static func enable() {
        state.withLock { $0.on = true }
    }

    /// Whether the mask is on.
    public static var isOn: Bool {
        state.withLock { $0.on }
    }

    /// Remembers a node list read, so the names in it mask by `make(nodes:)`.
    public static func observe(nodes: [ClusterNode]) {
        state.withLock { s in
            guard s.on else { return }
            s.names = make(nodes: nodes)
        }
    }

    /// The mapping in force: nil with the mask off, else the last node
    /// list's (empty before the first list, so every name is `unknown`).
    public static var current: [String: String]? {
        state.withLock { $0.on ? $0.names : nil }
    }

    /// A node name as the console shows it, through `StatusDisplay.clip`:
    /// the real name with `mask` nil, else its masked name.
    public static func shown(_ name: String, mask: [String: String]? = current) -> String {
        StatusDisplay.clip(mask.map { apply($0, to: name) } ?? name)
    }

    /// An address as the console shows it: unchanged with `mask` nil.
    public static func shownAddress(_ address: String, mask: [String: String]? = current) -> String {
        mask.map { apply($0, toAddress: address) } ?? address
    }

    /// Free text as the console shows it: unchanged with `mask` nil, else
    /// with every node name masked.
    public static func shownText(_ text: String, mask: [String: String]? = current) -> String {
        mask.map { apply($0, toText: text) } ?? text
    }
}
