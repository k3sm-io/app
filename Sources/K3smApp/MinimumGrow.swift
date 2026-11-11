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

import Combine
import Foundation
import K3smStatus

/// MinimumGrow decides when the console window grows to its minimum, apart
/// from the window, so a test can drive it with its own changes, minimum
/// and scheduler.
enum MinimumGrow {
    /// Emits once for each change after which the window's minimum rose
    /// (`WindowFrame.growsOnMinimumChange`). Each change reads `minimum` on
    /// `scheduler`: `@Published` sends before the value is stored, so the
    /// main window passes the main queue, whose next turn sees the new value.
    /// A minimum equal to the last one is dropped, and the first value pairs
    /// with `start` (the minimum the window was placed at), so subscribing
    /// does not grow the window.
    static func grows<S: Scheduler>(on changes: AnyPublisher<Void, Never>,
                                    minimum: @escaping () -> WindowFrame.Size,
                                    start: WindowFrame.Size,
                                    scheduler: S) -> AnyPublisher<Void, Never> {
        changes
            .receive(on: scheduler)
            .map { _ in minimum() }
            .removeDuplicates()
            .scan((start, start)) { pair, current in (pair.1, current) }
            .filter { WindowFrame.growsOnMinimumChange(from: $0.0, to: $0.1) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
