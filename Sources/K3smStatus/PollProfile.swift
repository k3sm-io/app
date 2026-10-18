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

/// PollIntervals is every cadence the app reads k3sm at, one profile's worth.
/// Deadlines are not here: how long a run may take does not change with how
/// often the app starts one.
public struct PollIntervals: Equatable, Sendable {
    /// The status item's `status daemons` probe while the item is shown,
    /// and while it is not. A launchd state change touches no file, so this
    /// probe stays the only detector of a daemon that crashed or stopped.
    public let visible: Duration
    public let hidden: Duration
    /// The Workloads and Nodes tabs, and Builds until the engine is ready.
    public let fast: Duration
    /// The full status read while the console window is open and no record
    /// watch is held (`ReportTrigger`'s fallback).
    public let consoleReport: Duration
    /// The full status read while the console window is open and the record
    /// watches are held: a heartbeat, since a change in a status record or a
    /// LaunchDaemons plist triggers the read on its own.
    public let consoleHeartbeat: Duration
    /// The Images tab.
    public let images: Duration
    /// The Services, Storage, Models and Stats tabs.
    public let objects: Duration
    /// The Events view.
    public let events: Duration
    /// The Builds tab once the engine is ready.
    public let buildsReady: Duration
    /// The managed update's progress while it is read.
    public let updateStatus: Duration
    /// The pod list while another tab is selected.
    public let background: Duration
    /// The metrics read while the Stats tab or an inspector's load rows are
    /// shown, while any other view is, and its retry while metrics-server is
    /// absent (`MetricsDemand`).
    public let metrics: Duration
    public let metricsSlow: Duration
    public let metricsAbsent: Duration
    /// The full status read that looks for a new release while the console
    /// is closed, only with the update notification on.
    public let updateCheck: Duration

    public init(visible: Duration, hidden: Duration, fast: Duration, consoleReport: Duration, consoleHeartbeat: Duration,
                images: Duration, objects: Duration, events: Duration, buildsReady: Duration, updateStatus: Duration,
                background: Duration, metrics: Duration, metricsSlow: Duration, metricsAbsent: Duration,
                updateCheck: Duration) {
        self.visible = visible
        self.hidden = hidden
        self.fast = fast
        self.consoleReport = consoleReport
        self.consoleHeartbeat = consoleHeartbeat
        self.images = images
        self.objects = objects
        self.events = events
        self.buildsReady = buildsReady
        self.updateStatus = updateStatus
        self.background = background
        self.metrics = metrics
        self.metricsSlow = metricsSlow
        self.metricsAbsent = metricsAbsent
        self.updateCheck = updateCheck
    }

    /// Every interval by name, in a fixed order, so two profiles compare
    /// field by field.
    public var all: [(name: String, value: Duration)] {
        [("visible", visible), ("hidden", hidden), ("fast", fast), ("consoleReport", consoleReport),
         ("consoleHeartbeat", consoleHeartbeat), ("images", images),
         ("objects", objects), ("events", events), ("buildsReady", buildsReady), ("updateStatus", updateStatus),
         ("background", background), ("metrics", metrics), ("metricsSlow", metricsSlow),
         ("metricsAbsent", metricsAbsent), ("updateCheck", updateCheck)]
    }
}

/// PollProfile is how often the app reads k3sm, a General preference:
/// Normal, the cadences the app has always used, or Low power, every one of
/// them at least twice as long, for a Mac on battery. A change applies from
/// each poll's next wait.
public enum PollProfile: String, CaseIterable, Sendable {
    case normal
    case lowPower = "low-power"

    /// The profile when nothing usable is stored.
    public static let defaultProfile: PollProfile = .normal

    /// The popup's item.
    public var title: String {
        switch self {
        case .normal: "Normal"
        case .lowPower: "Low power"
        }
    }

    /// The line under the popup.
    public static let paneNote = "Low power reads k3sm half as often, so the menu bar item and the window show changes later."

    public var intervals: PollIntervals {
        switch self {
        case .normal:
            PollIntervals(visible: .seconds(15), hidden: .seconds(60), fast: .seconds(5), consoleReport: .seconds(30),
                          consoleHeartbeat: .seconds(5 * 60), images: .seconds(15),
                          objects: .seconds(15), events: .seconds(5), buildsReady: .seconds(15), updateStatus: .seconds(5),
                          background: .seconds(30), metrics: .seconds(15), metricsSlow: .seconds(60), metricsAbsent: .seconds(60),
                          updateCheck: .seconds(30 * 60))
        case .lowPower:
            PollIntervals(visible: .seconds(30), hidden: .seconds(120), fast: .seconds(10), consoleReport: .seconds(60),
                          consoleHeartbeat: .seconds(10 * 60), images: .seconds(30),
                          objects: .seconds(30), events: .seconds(10), buildsReady: .seconds(30), updateStatus: .seconds(10),
                          background: .seconds(60), metrics: .seconds(30), metricsSlow: .seconds(120), metricsAbsent: .seconds(120),
                          updateCheck: .seconds(60 * 60))
        }
    }

    /// A stored profile word, or the default for anything else (absent,
    /// another type, a word this build does not know).
    public static func restore(from stored: Any?) -> PollProfile {
        (stored as? String).flatMap(PollProfile.init(rawValue:)) ?? defaultProfile
    }
}

extension PollSchedule {
    /// The profile every cadence reads, set by the app from its preference;
    /// Normal until it is. Tests read it and never set it.
    private static let current = Mutex(PollProfile.defaultProfile)

    public static var profile: PollProfile {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// The current profile's intervals.
    public static var intervals: PollIntervals { profile.intervals }
}
