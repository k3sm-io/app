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

/// ConsoleSection is one tab of the console's middle column. The raw value
/// is the id the app keeps in the user defaults; adding a tab is a case here,
/// its cadence in `PollSchedule.interval(for:engineReady:)` and a view in
/// the console.
public enum ConsoleSection: String, CaseIterable, Identifiable, Sendable {
    case workloads
    case nodes
    case images
    case builds
    case services
    case storage
    case models
    case stats

    public var id: Self { self }

    /// The tab's label in the strip.
    public var title: String {
        switch self {
        case .workloads: return "Workloads"
        case .nodes: return "Nodes"
        case .images: return "Images"
        case .builds: return "Builds"
        case .services: return "Services"
        case .storage: return "Storage"
        case .models: return "Models"
        case .stats: return "Stats"
        }
    }
}

/// ConsoleTabs is how the console's tab choice, and each tab's search and
/// selection, survive a relaunch: the user-defaults keys, and how a stored
/// value is read back. A stored value is data the app wrote, but it is read
/// as untrusted: a tab id this build does not know falls back to Workloads,
/// and a stored query or row key is clipped like cluster text.
public enum ConsoleTabs {
    /// The key holding the selected tab's raw value.
    public static let sectionKey = "consoleSection"

    /// The tab a stored value names, or Workloads when it names none.
    public static func restore(from stored: Any?) -> ConsoleSection {
        guard let raw = stored as? String, let section = ConsoleSection(rawValue: raw) else { return .workloads }
        return section
    }

    /// The key holding one tab's search text.
    public static func queryKey(_ section: ConsoleSection) -> String {
        "consoleQuery.\(section.rawValue)"
    }

    /// The key holding one tab's selected row.
    public static func selectedKey(_ section: ConsoleSection) -> String {
        "consoleSelected.\(section.rawValue)"
    }

    /// A stored search text, clipped to one line; "" when none is stored.
    public static func restoreQuery(from stored: Any?) -> String {
        (stored as? String).map(StatusDisplay.clip) ?? ""
    }

    /// A stored row key, clipped to one line; nil when none is stored. A key
    /// that no longer names a listed row is cleared by the tab's first read.
    public static func restoreSelected(from stored: Any?) -> String? {
        guard let text = stored as? String, !text.isEmpty else { return nil }
        return StatusDisplay.clip(text)
    }
}

/// WorkloadsView is the Workloads tab's sub-tab: its pods, or the cluster's
/// events. The raw value is the id kept in the user defaults.
public enum WorkloadsView: String, CaseIterable, Identifiable, Sendable {
    case pods
    case events

    public var id: Self { self }

    /// The sub-tab's label.
    public var title: String {
        switch self {
        case .pods: return "Pods"
        case .events: return "Events"
        }
    }

    /// The key holding the chosen sub-tab.
    public static let key = "consoleWorkloadsView"
    /// The key holding the Events view's namespace filter ("" for all).
    public static let namespaceKey = "consoleEventsNamespace"

    /// The sub-tab a stored value names, or Pods when it names none.
    public static func restore(from stored: Any?) -> WorkloadsView {
        guard let raw = stored as? String, let view = WorkloadsView(rawValue: raw) else { return .pods }
        return view
    }

    /// A stored namespace filter, clipped; nil (every namespace) when none
    /// is stored or it is empty.
    public static func restoreNamespace(from stored: Any?) -> String? {
        ConsoleTabs.restoreSelected(from: stored)
    }
}
