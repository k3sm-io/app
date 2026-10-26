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

/// StartTimeBound is how long the app waits for `k3sm start`. The CLI states
/// the deadline it enforces on itself (`k3sm start --print-time-bound`, an
/// integer number of seconds on standard output, exit 0: its computed bound
/// plus its own margin); the app waits that long plus `marginSeconds` more,
/// so it never stops waiting before the start does.
/// A CLI that has no such flag, exits non-zero, or prints anything but a
/// whole number in range gets `fallbackSeconds`, and the reason is kept so
/// the caller can log it.
public enum StartTimeBound {
    /// The bound the app assumes when the CLI cannot state one: long enough
    /// for a start whose node daemon and netd both restart slowly.
    public static let fallbackSeconds = 600
    /// What the app adds to the bound before it stops waiting.
    public static let marginSeconds = 30
    /// The largest bound the app accepts from the CLI; anything above it is
    /// treated as unreadable, not as a reason to wait for hours.
    public static let maxSeconds = 3600

    /// Reading is one `--print-time-bound` run, classified.
    public enum Reading: Equatable, Sendable {
        /// The CLI printed this many seconds.
        case printed(Int)
        /// The CLI's bound could not be used; the app waits for the fallback.
        /// `reason` is the app's own sentence, never CLI text.
        case fallback(reason: String)

        /// The bound in seconds this reading stands for.
        public var seconds: Int {
            switch self {
            case .printed(let n): return n
            case .fallback: return StartTimeBound.fallbackSeconds
            }
        }

        /// How long the app waits for the start: the bound plus the margin.
        public var timeout: Duration {
            .seconds(seconds + StartTimeBound.marginSeconds)
        }
    }

    /// Classifies one run. `exitStatus` is nil when the CLI did not run to an
    /// exit of its own (missing, refused, killed or past its output limit).
    public static func parse(exitStatus: Int32?, stdout: Data) -> Reading {
        guard let exitStatus else {
            return .fallback(reason: "the installed k3sm did not answer --print-time-bound")
        }
        guard exitStatus == 0 else {
            return .fallback(reason: "the installed k3sm exited \(exitStatus) for --print-time-bound, so it has no such flag or refused it")
        }
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 9, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let n = Int(text) else {
            return .fallback(reason: "the installed k3sm printed no whole number of seconds for --print-time-bound")
        }
        guard n > 0, n <= maxSeconds else {
            return .fallback(reason: "the installed k3sm printed a start bound of \(n) s, outside 1 to \(maxSeconds) s")
        }
        return .printed(n)
    }
}
