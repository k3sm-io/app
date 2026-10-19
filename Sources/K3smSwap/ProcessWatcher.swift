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

import Darwin
import Foundation

/// ProcessWatcher waits for a process to exit.
public protocol ProcessWatcher: Sendable {
    /// Waits up to `timeout` for `process` to exit. Returns true when it has
    /// exited (or never ran, or its pid now names another process), false
    /// when it is still running at the deadline.
    func waitForExit(_ process: ProcessIdentity, timeout: Duration) -> Bool
}

/// KqueueProcessWatcher is the real `ProcessWatcher`: `EVFILT_PROC` with
/// `NOTE_EXIT`. The start time is checked before the registration and again
/// after it, so a reused pid counts as exited; an `EV_ADD` that fails with
/// `ESRCH` means the process is already gone.
public struct KqueueProcessWatcher: ProcessWatcher {
    public init() {}

    public func waitForExit(_ process: ProcessIdentity, timeout: Duration) -> Bool {
        guard process.isRunning else { return true }
        let kq = kqueue()
        guard kq >= 0 else { return !process.isRunning }
        defer { close(kq) }
        var change = kevent(ident: UInt(process.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        var event = kevent()
        let registered = kevent(kq, &change, 1, &event, 1, &zero)
        if registered < 0 { return errno == ESRCH || !process.isRunning }
        if registered > 0 {
            if event.flags & UInt16(EV_ERROR) != 0 { return event.data == Int(ESRCH) || !process.isRunning }
            if event.fflags & UInt32(NOTE_EXIT) != 0 { return true }
        }
        // Registered on the pid: make sure it still names the same process.
        guard process.isRunning else { return true }
        let parts = timeout.components
        var wait = timespec(tv_sec: Int(parts.seconds), tv_nsec: Int(parts.attoseconds / 1_000_000_000))
        while true {
            let n = kevent(kq, nil, 0, &event, 1, &wait)
            if n < 0 && errno == EINTR { continue }
            if n > 0 { return true }
            return !process.isRunning
        }
    }
}
