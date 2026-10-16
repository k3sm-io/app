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

/// ClusterEvent is one Event as the Events view lists it. Every string is clipped.
public struct ClusterEvent: Equatable, Sendable {
    /// The event's uid, else "namespace/name"; unique per row.
    public let key: String
    public let namespace: String
    /// "Normal" or "Warning" today; any other word is kept as printed.
    public let type: String
    public let reason: String
    public let message: String
    /// The object it is about, as "Kind name".
    public let object: String
    /// How many times it happened; 1 when the API leaves it out.
    public let count: Int
    /// When it last happened; nil when no timestamp parses.
    public let time: Date?

    /// The severity word the row colours its dot by, as `PodHealth`.
    public var severity: String { type == "Warning" ? "warn" : "off" }
}

/// EventsList decodes `K3smCLI.eventsArguments`, every Event in the cluster,
/// newest first, and decides what the Events view shows: the events of the
/// chosen namespace (or all), at most `cap` of them.
public enum EventsList {
    /// The most events the view shows at once.
    public static let cap = 200
    /// The tab's line when the cluster has no event.
    public static let emptyText = "No events recorded."

    /// The events, newest first; events with no time last, by key. It throws
    /// `KubeListError` when the bytes are not a list of Events.
    public static func decode(_ data: Data) throws -> [ClusterEvent] {
        let events = try KubeList.objects(data, kinds: ["Event"]).map { object -> ClusterEvent in
            let metadata = KubeList.dict(object, "metadata")
            let namespace = KubeList.namespace(object)
            let involved = KubeList.dict(object, "involvedObject")
            let series = KubeList.dict(object, "series")
            let about = [KubeList.string(involved, "kind"), KubeList.string(involved, "name")].compactMap { $0 }.joined(separator: " ")
            let time = KubeList.time(KubeList.string(object, "lastTimestamp"))
                ?? KubeList.time(KubeList.string(series, "lastObservedTime"))
                ?? KubeList.time(KubeList.string(object, "eventTime"))
                ?? KubeList.time(KubeList.string(object, "firstTimestamp"))
                ?? KubeList.time(KubeList.string(metadata, "creationTimestamp"))
            return ClusterEvent(
                key: StatusDisplay.clip(KubeList.string(metadata, "uid") ?? "\(namespace)/\(KubeList.name(object))"),
                namespace: StatusDisplay.clip(namespace),
                type: StatusDisplay.clip(KubeList.string(object, "type") ?? ""),
                reason: StatusDisplay.clip(KubeList.string(object, "reason") ?? ""),
                message: StatusDisplay.clip(KubeList.string(object, "message") ?? ""),
                object: StatusDisplay.clip(about),
                count: max(1, KubeList.int(object, "count") ?? KubeList.int(series, "count") ?? 1),
                time: time)
        }
        return events.sorted(by: newerFirst)
    }

    /// One list run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<[ClusterEvent]> {
        KubeList.tabResult(exitCode: exitCode, stdout: stdout, what: "event list", decode: decode)
    }

    /// The order the view shows: newer before older, a timeless event after
    /// every timed one, and the key between equals, so a read never reshuffles.
    public static func newerFirst(_ a: ClusterEvent, _ b: ClusterEvent) -> Bool {
        switch (a.time, b.time) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.key < b.key
        }
    }

    /// The events the view shows: the namespace's (all for nil), newest
    /// first, at most `cap`. The filter applies before the cap, so a quiet
    /// namespace is not crowded out by a busy one.
    public static func visible(_ events: [ClusterEvent], namespace: String?) -> [ClusterEvent] {
        let shown = namespace.map { ns in events.filter { $0.namespace == ns } } ?? events
        return Array(shown.sorted(by: newerFirst).prefix(cap))
    }

    /// The namespaces the filter offers, sorted: every namespace with an
    /// event, and the chosen one even when it has none now, so a choice is
    /// never silently dropped.
    public static func namespaces(_ events: [ClusterEvent], selected: String?) -> [String] {
        var all = Set(events.map(\.namespace).filter { !$0.isEmpty })
        if let selected { all.insert(selected) }
        return all.sorted()
    }

    /// The line the view shows when the chosen namespace has no event.
    public static func emptyText(namespace: String?) -> String {
        namespace.map { "No events in \($0)." } ?? emptyText
    }
}
