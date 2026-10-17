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

/// RunControl is the one place a run's child is killed: at the deadline,
/// past the output limit, or on cancellation, whichever comes first.
///
/// Foundation reaps the child and then runs the termination handler, so a
/// kill sent while `exited` is false can in principle meet a pid released a
/// moment earlier; macOS allocates pids sequentially, so that window is
/// negligible. A stop that arrives before the launch is held and applied the
/// moment the pid is known.
///
/// The signal reaches the direct child only. The `k3sm kubectl` wrapper
/// execs `kubectl` in place (`syscall.Exec`), so the wrapper's pid becomes
/// kubectl's and a SIGKILL to it ends kubectl itself, including a
/// `logs -f` stream; no grandchild outlives the kill.
final class RunControl: Sendable {
    private struct State {
        var pid: pid_t = 0
        var exited = false
        var stopped = false
    }
    private let state = Mutex(State())

    func launched(_ pid: pid_t) {
        state.withLock { s in
            s.pid = pid
            if s.stopped && !s.exited { kill(pid, SIGKILL) }
        }
    }

    func exited() {
        state.withLock { $0.exited = true }
    }

    func stop() {
        state.withLock { s in
            guard !s.stopped else { return }
            s.stopped = true
            if s.pid > 0 && !s.exited { kill(s.pid, SIGKILL) }
        }
    }

    var wasStopped: Bool {
        state.withLock { $0.stopped }
    }
}
