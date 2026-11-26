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
import Testing

@testable import K3smStatus

@Suite("Console column ordering")
struct ConsoleSortTests {
    @Test func ageAndNaturalNameOrder() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        func event(_ key: String, age: Double?) -> ClusterEvent {
            ClusterEvent(key: key, namespace: "default", type: "Normal", reason: "", message: key,
                         object: "", count: 1, time: age.map { now.addingTimeInterval(-$0) })
        }
        let rows = [event("pod10", age: 2), event("unknown", age: nil), event("pod2", age: 10)]
        #expect(ConsoleSort(column: .age).rows(rows, now: now).map(\.key) == ["pod10", "pod2", "unknown"])
        #expect(ConsoleSort(column: .age, ascending: false).rows(rows, now: now).map(\.key) == ["pod2", "pod10", "unknown"])
        #expect(ConsoleSort(column: nil).rows(rows).map(\.key) == ["pod2", "pod10", "unknown"])
    }
}
