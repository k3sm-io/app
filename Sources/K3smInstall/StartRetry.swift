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
import Synchronization

/// StartRetry decides what follows one `k3sm start` run. A start whose
/// daemons came up but whose Node is still cordoned exits 1 with
/// `cordonedMarker` on standard error; the app runs the start once more on
/// its own (a second start finishes the uncordon the first ran out of time
/// for), and after a second such exit it shows that state with the remedy
/// and runs nothing further. Any other exit 1 is a failed start.
public enum StartRetry {
    /// The exact token the CLI writes for a start that left the Node cordoned.
    public static let cordonedMarker = "k3sm: node is still cordoned"
    /// How many times the app re-runs a start on its own.
    public static let automaticReruns = 1

    /// What the driver does after one run.
    public enum Step: Equatable, Sendable {
        /// The run is the outcome.
        case finished
        /// Run the start again, now.
        case rerun
        /// The Node is still cordoned after the automatic re-runs.
        case notSchedulable
    }

    /// Whether a run is the CLI's still-cordoned exit: status 1 and the
    /// marker in its raw standard error.
    public static func stillCordoned(_ run: PrivilegedRun) -> Bool {
        guard run.outcome == .failed(exitStatus: LifecycleExit.failed), let error = run.errorOutput else { return false }
        return error.contains(cordonedMarker)
    }

    /// Decides the step after run number `attempt` (1 for the first).
    public static func next(after run: PrivilegedRun, attempt: Int) -> Step {
        guard stillCordoned(run) else { return .finished }
        return attempt <= automaticReruns ? .rerun : .notSchedulable
    }

    /// Shown while the automatic re-run runs.
    public static let retryingText = "k3sm started, node not schedulable yet; retrying."
    /// Shown when the re-run left the Node cordoned too.
    public static let notSchedulableText =
        "k3sm started, node not schedulable yet. The automatic retry did not uncordon it either; run `sudo k3sm start` in Terminal to finish."

    /// Shown when a start ran past the app's wait.
    public static func timedOutText(seconds: Int) -> String {
        "k3sm start did not finish within \(seconds) seconds, so the app stopped waiting. It may still be running; the logs say why."
    }
}

/// Deadline races an operation against a timer: the operation's value if it
/// finishes first, nil if `limit` passes first. The operation is not
/// cancelled (an administrator prompt cannot be), only no longer awaited; a
/// late value is dropped.
public enum Deadline {
    public static func race<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
            Task {
                let value = await operation()
                timer.cancel()
                once.resume(value)
            }
        }
    }
}

/// ResumeOnce resumes a continuation the first time only.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T?) {
        let pending = continuation.withLock { c -> CheckedContinuation<T?, Never>? in
            defer { c = nil }
            return c
        }
        pending?.resume(returning: value)
    }
}
