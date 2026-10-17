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

/// PodDetail is one of a pod's reads: its log, its events or its manifest.
/// The log opens in the log pane along the bottom of the window; the
/// inspector shows only the others (`inspectorTabs`), with a one-line Open
/// Log in place of the log body.
public enum PodDetail: String, CaseIterable, Identifiable, Sendable {
    case logs = "Logs", events = "Events", manifest = "Manifest"

    public var id: Self { self }

    /// The detail tabs the inspector shows: never the log.
    public static let inspectorTabs: [PodDetail] = [.events, .manifest]

    /// Whether this read opens in the log pane rather than the inspector.
    public var opensLogPane: Bool { self == .logs }
}

/// LogPaneSource is the log the pane shows: a pod's (its recent lines of
/// every container, or one container followed) or a recorded build's.
public enum LogPaneSource: Equatable, Sendable {
    /// A pod's log, by its selection key ("namespace/name").
    case pod(key: String)
    /// A recorded build's log.
    case build(BuildLogTarget)

    /// The pane's title, naming the source, clipped to one line.
    public var title: String {
        switch self {
        case .pod(let key): return StatusDisplay.clip("Log of " + key)
        case .build(let target): return StatusDisplay.clip("Build log of " + target.title)
        }
    }

    /// The pod key, for a pod's log.
    public var podKey: String? {
        if case .pod(let key) = self { return key }
        return nil
    }
}

/// LogPaneState is whether the log pane is open and what it shows. Opening
/// a log replaces whatever the pane showed (`open` returns it, so the
/// caller stops its read); closing it returns the source it showed.
public struct LogPaneState: Equatable, Sendable {
    public private(set) var source: LogPaneSource?

    public init() {}

    /// Whether the pane is on screen.
    public var isOpen: Bool { source != nil }

    /// The pane's title, or nil while it is closed.
    public var title: String? { source?.title }

    /// Opens `source` in the pane, returning the source it replaced (nil
    /// when the pane was closed).
    @discardableResult
    public mutating func open(_ source: LogPaneSource) -> LogPaneSource? {
        let replaced = self.source
        self.source = source
        return replaced
    }

    /// Closes the pane, returning the source it showed.
    @discardableResult
    public mutating func close() -> LogPaneSource? {
        let shown = source
        source = nil
        return shown
    }
}
