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

/// ReportHold decides which full status report the window shows after a
/// read. A read that decoded is shown and becomes the last good report. A
/// read that failed (the CLI killed at its deadline on a loaded Mac, output
/// that did not decode) keeps showing the last good report, marked stale
/// with its age, for up to `maxHeldFailures` failed reads in a row; only
/// then, or with no good report to fall back on, does the window show no
/// report (the health check's `statusUnreadable`). One slow read therefore
/// never replaces a working console with "could not be read".
public struct ReportHold: Equatable, Sendable {
    /// How many failed reads in a row keep the last good report on screen.
    public static let maxHeldFailures = 3

    /// The last report that decoded, and when it was read.
    public private(set) var lastGood: StatusReport?
    public private(set) var lastGoodAt: Date?
    /// Failed reads since the last one that decoded.
    public private(set) var failures = 0

    public init() {}

    /// Takes one read's result and returns the report to show: `read` when
    /// it decoded, else the held last good report while the hold lasts, else
    /// nil.
    public mutating func take(_ read: StatusReport?, now: Date = Date()) -> StatusReport? {
        if let read {
            lastGood = read
            lastGoodAt = now
            failures = 0
            return read
        }
        failures += 1
        return holding ? lastGood : nil
    }

    /// Whether a failed read is being covered by the last good report.
    public var holding: Bool { failures > 0 && failures <= Self.maxHeldFailures && lastGood != nil }

    /// Forgets everything: nothing is installed, or the window left the
    /// console, so an old report must never come back.
    public mutating func reset() { self = ReportHold() }

    /// The line the console shows while a held report is on screen: "The
    /// last status read failed; showing the report from 40 s ago." Nil
    /// when the report on screen is fresh.
    public func staleLine(now: Date = Date()) -> String? {
        guard holding, let lastGoodAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(lastGoodAt))
        let age: String
        switch seconds {
        case ..<5: age = "just now"
        case ..<60: age = "\(Int(seconds)) s ago"
        case ..<3600: age = "\(Int(seconds / 60)) min ago"
        default: age = "\(Int(seconds / 3600)) h ago"
        }
        return "The last status read failed; showing the report from \(age). It is read again shortly."
    }
}

/// ReportRecovery keeps the full report read retrying on its own after a
/// failure. While the status stream is live the console has no timed read
/// (the stream writes a frame only when the cluster changes), so without
/// this a failed read stayed on screen until something changed or Refresh
/// was pressed. Every result goes through `take`: a good read cancels the
/// retry, a failed one schedules the next read on `WatchClock`, after
/// `PollSchedule.reportRetryInterval` while the hold covers it and
/// `consoleReportInterval` after, spread by `PollJitter`, for as long as
/// the reads keep failing. Each retry's own result comes back through
/// `take` and schedules the one after, so there is one pending retry at most.
@MainActor
public final class ReportRecovery {
    public private(set) var hold = ReportHold()

    private let clock: any WatchClock
    private let retryInterval: @MainActor () -> Duration
    private let slowInterval: @MainActor () -> Duration
    private let jitter: @MainActor () -> Double
    private let retry: @MainActor () async -> Void
    private var timer: (any WatchTimer)?

    public init(clock: any WatchClock,
                retryInterval: @escaping @MainActor () -> Duration = { PollSchedule.reportRetryInterval },
                slowInterval: @escaping @MainActor () -> Duration = { PollSchedule.consoleReportInterval },
                jitter: @escaping @MainActor () -> Double = { PollJitter.draw() },
                retry: @escaping @MainActor () async -> Void) {
        self.clock = clock
        self.retryInterval = retryInterval
        self.slowInterval = slowInterval
        self.jitter = jitter
        self.retry = retry
    }

    /// Whether a retry is scheduled.
    public var retryPending: Bool { timer != nil }

    /// Takes one full read's result (`ReportHold.take`) and schedules or
    /// cancels the retry; returns the report to show.
    public func take(_ read: StatusReport?, now: Date = Date()) -> StatusReport? {
        let shown = hold.take(read, now: now)
        timer?.cancel()
        timer = nil
        if read == nil {
            let base = hold.holding ? retryInterval() : slowInterval()
            timer = clock.schedule(at: clock.now + PollJitter.spread(base, unit: jitter())) { [weak self] in
                guard let self else { return }
                self.timer = nil
                Task { @MainActor in await self.retry() }
            }
        }
        return shown
    }

    /// Cancels the retry and forgets the held report.
    public func reset() {
        timer?.cancel()
        timer = nil
        hold.reset()
    }

    /// Cancels the retry and keeps the held report: the console left the
    /// screen, and showing it again reads at once.
    public func pause() {
        timer?.cancel()
        timer = nil
    }
}
