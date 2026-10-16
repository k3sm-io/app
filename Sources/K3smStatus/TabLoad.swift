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

/// TabResult is what one list read for a console tab came to: a decoded
/// value, a failure with the text to show, or a reason the read cannot be
/// made at all (the CLI is not installed).
public enum TabResult<Value> {
    case value(Value)
    case failed(String)
    case unavailable(String)
}

extension TabResult: Equatable where Value: Equatable {}
extension TabResult: Sendable where Value: Sendable {}

/// TabLoad is what a console tab is doing with its read. The loader moves
/// through it with `begin`, `finished` and `stopped`; the view renders it.
public enum TabLoad: Equatable, Sendable {
    /// Not read yet, and no read running.
    case idle
    /// No value yet, and a read is running.
    case firstRead
    /// A value is shown, and a read is running.
    case refreshing
    /// The last read decoded, at this time.
    case loaded(Date)
    /// The last read failed; the text is clean for display (`errorText`).
    case failed(String)
    /// The read cannot be made; the text is clean for display (`clip`).
    case unavailable(String)

    /// Whether the last read failed or could not be made.
    public var failedOrUnavailable: Bool {
        switch self {
        case .failed, .unavailable: return true
        default: return false
        }
    }

    /// Whether a read is running.
    public var inFlight: Bool {
        self == .firstRead || self == .refreshing
    }

    /// The state when a read begins: a first read when the tab holds no
    /// value, a refresh behind the value it shows otherwise.
    public static func begin(hasValue: Bool) -> TabLoad {
        hasValue ? .refreshing : .firstRead
    }

    /// The state a finished read leaves. CLI text is cleaned here, so the
    /// state never carries a raw cluster string.
    public static func finished<Value>(_ result: TabResult<Value>, at time: Date) -> TabLoad {
        switch result {
        case .value: return .loaded(time)
        case .failed(let text): return .failed(StatusDisplay.errorText(text))
        case .unavailable(let reason): return .unavailable(StatusDisplay.clip(reason))
        }
    }

    /// The state a stop leaves: a cancelled read returns the tab to what it
    /// showed before (its last value as of `readAt`, or nothing); any other
    /// state is kept, so a re-selected tab shows its last result and its age.
    public static func stopped(_ current: TabLoad, readAt: Date?) -> TabLoad {
        guard current.inFlight else { return current }
        if current == .refreshing, let readAt { return .loaded(readAt) }
        return .idle
    }

    /// How old a read is, as the tab's footer says it: "read just now",
    /// "read 40 s ago", "read 3 min ago", "read 2 h ago".
    public static func age(since time: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(time))
        switch seconds {
        case ..<5: return "read just now"
        case ..<60: return "read \(Int(seconds)) s ago"
        case ..<3600: return "read \(Int(seconds / 60)) min ago"
        default: return "read \(Int(seconds / 3600)) h ago"
        }
    }
}

extension Workloads {
    /// One pod-list run as a tab result, by `WorkloadsReading.classify`.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<Workloads> {
        switch WorkloadsReading.classify(exitCode: exitCode, stdout: stdout) {
        case .listed(let w): return .value(w)
        case .cliError(let text): return .failed(text)
        case .binaryMissing: return .unavailable(TabLoad.notInstalled)
        }
    }
}

extension TabLoad {
    /// The line a tab shows when the CLI is not at its absolute path.
    public static let notInstalled = "k3sm is not installed on this Mac."
}
