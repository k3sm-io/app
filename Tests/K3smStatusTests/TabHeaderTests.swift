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

import Testing

@testable import K3smStatus

@Suite("where a tab's bulk actions go")
struct TabHeaderTests {
    @Test("Workloads puts them on its switch row; Storage, Builds and Images on their own; the rest nowhere")
    func placement() {
        #expect(TabHeader.placement(.workloads) == .switchRow)
        #expect(TabHeader.placement(.storage) == .ownRow)
        #expect(TabHeader.placement(.builds) == .ownRow)
        #expect(TabHeader.placement(.images) == .ownRow)
        for section in [ConsoleSection.nodes, .services, .models] {
            #expect(TabHeader.placement(section) == .none)
        }
    }

    @Test("an own row shows only while it holds actions or a line; the switch row always; no other tab gets one")
    func showsRow() {
        for section in ConsoleSection.allCases {
            for (actions, line) in [(false, false), (true, false), (false, true), (true, true)] {
                let shown = TabHeader.showsRow(section, hasActions: actions, hasLine: line)
                switch TabHeader.placement(section) {
                case .switchRow: #expect(shown)
                case .ownRow: #expect(shown == (actions || line))
                case .none: #expect(!shown)
                }
            }
        }
        #expect(!TabHeader.showsRow(.storage, hasActions: false, hasLine: false))
        #expect(TabHeader.showsRow(.builds, hasActions: true, hasLine: false))
        #expect(TabHeader.showsRow(.workloads, hasActions: false, hasLine: false))
    }
}
