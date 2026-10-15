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
import K3smInstall

/// WallClockClearScheduler runs a clear on the main queue at a wall-clock
/// deadline (`asyncAfter(wallDeadline:)`), which keeps counting while the
/// Mac sleeps: a deadline passed during sleep fires on wake.
@MainActor
final class WallClockClearScheduler: ClearScheduler {
    func schedule(at deadline: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any ClearTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
        return WorkItemTimer(item)
    }
}

/// WorkItemTimer cancels one scheduled clear.
@MainActor
final class WorkItemTimer: ClearTimer {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}
