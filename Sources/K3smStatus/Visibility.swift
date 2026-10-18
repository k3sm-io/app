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

/// Reading is what one poll of `k3sm status` concluded about the node daemon.
public enum Reading: Equatable, Sendable {
    /// The report decoded and the node daemon reads running.
    case running
    /// The report decoded and the node daemon does not read running.
    case notRunning
    /// The k3sm binary is not installed at the expected path.
    case binaryMissing
    /// The CLI ran but its output could not be read as a report.
    case cliError

    /// Classifies one CLI run. `k3sm status` exits with its verdict (0 running,
    /// 3 stopped, 4 degraded, 5 not installed, 6 unknown) and still prints the
    /// report; 1 and 2 mean an internal error or bad usage, never a verdict.
    public static func classify(exitCode: Int32, stdout: Data) -> Reading {
        if exitCode == 1 || exitCode == 2 {
            return .cliError
        }
        guard let report = try? StatusReport.decode(stdout) else {
            return .cliError
        }
        return of(report)
    }

    /// The reading a decoded report stands for: a status stream's report
    /// frame feeds the status item through it, as a probe run does.
    public static func of(_ report: StatusReport) -> Reading {
        report.nodeDaemonRunning ? .running : .notRunning
    }
}

/// VisibilityTracker applies the status item's visibility rule across polls:
/// show after one running reading, hide after two consecutive readings that
/// are not running, and stay hidden while the binary is missing or the CLI
/// fails. A single missed poll never hides a visible item.
public struct VisibilityTracker: Equatable, Sendable {
    /// Consecutive non-running readings that hide a visible item.
    public static let hideAfter = 2

    /// Whether the status item should be inserted.
    public private(set) var visible = false
    private var misses = 0
    private var reportedUnavailable = false

    public init() {}

    /// Change is what one reading did to the tracker.
    public struct Change: Equatable, Sendable {
        /// The item was shown or hidden by this reading.
        public let visibilityChanged: Bool
        /// The CLI could not be read and this is the first such reading since
        /// the last good one, so the app logs it once.
        public let logUnavailable: Bool
    }

    /// Feeds one reading and returns what changed.
    @discardableResult
    public mutating func observe(_ reading: Reading) -> Change {
        let before = visible
        var logUnavailable = false
        switch reading {
        case .running:
            visible = true
            misses = 0
            reportedUnavailable = false
        case .notRunning, .binaryMissing, .cliError:
            if reading == .notRunning {
                reportedUnavailable = false
            } else if !reportedUnavailable {
                reportedUnavailable = true
                logUnavailable = true
            }
            misses = min(misses + 1, Self.hideAfter)
            if misses >= Self.hideAfter {
                visible = false
            }
        }
        return Change(visibilityChanged: before != visible, logUnavailable: logUnavailable)
    }
}
