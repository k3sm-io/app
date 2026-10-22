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

import K3smStatus

/// LifecycleSettle is the rule for reading the status again after a
/// lifecycle verb ran. The verb's command returns once the daemons are told,
/// and the status k3sm reports can trail that by a few seconds (the node
/// row, the stop record), so a single read right after the verb can still
/// show the state the verb left, and the health banner keeps saying
/// "stopped (by you)" after a Start. The app reads again, `interval`
/// apart, until the report shows the verb's end state or `maxReads` reads
/// are spent; after that the ordinary triggers take over.
public enum LifecycleSettle {
    /// The most reads after the verb, `interval` apart: 30 s in all.
    public static let maxReads = 15
    /// The wait between two reads.
    public static let interval: Duration = .seconds(2)

    /// The state a verb ends in: stopped after Stop, running after Start
    /// and Restart; nil for the verbs that do not change whether k3sm runs.
    public static func endState(of verb: LifecycleVerb) -> LifecycleState? {
        switch verb {
        case .stop: return .stopped
        case .start, .restart: return .running
        default: return nil
        }
    }

    /// Whether a report shows the verb's end state. After Start and Restart
    /// the stop record must be gone too: a report with the daemon up and
    /// `stoppedBy` still set is what the banner reads as stopped.
    public static func settled(_ verb: LifecycleVerb, report: StatusReport?) -> Bool {
        guard let end = endState(of: verb) else { return true }
        guard let report else { return false }
        let live = LifecycleState(report: report)
        if end == .running {
            return live == .running && report.stoppedBy == nil
        }
        return live == end
    }

    /// Whether to read again: the verb ran to its end, the report does not
    /// show that yet, and the bound is not spent.
    public static func readsAgain(_ verb: LifecycleVerb, succeeded: Bool, report: StatusReport?, reads: Int) -> Bool {
        succeeded && reads < maxReads && !settled(verb, report: report)
    }
}
