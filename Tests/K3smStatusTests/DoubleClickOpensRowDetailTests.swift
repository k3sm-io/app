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

@Suite("a double-click on a row opens what its open action shows")
struct DoubleClickOpensRowDetail {
    @Test("every tab's row kind resolves to its detail, its log, or nothing", arguments: [
        (ConsoleRow.pod("default/web-0"), RowActivation.detail(.pod("default/web-0"))),
        (.node("studio"), .detail(.node("studio"))),
        (.image("library/nginx:1.27"), .detail(.image("library/nginx:1.27"))),
        (.build(InspectorDetails.engineRow), .detail(.build(InspectorDetails.engineRow))),
        (.build("b-42"), .detail(.build("b-42"))),
        (.service("default/web"), .detail(.service("default/web"))),
        (.claim("default/data"), .detail(.claim("default/data"))),
        (.model("mlx/llama"), .detail(.model("mlx/llama"))),
        (.stat("cpu"), .none),
        (.issue("dns"), .none),
    ])
    func destination(row: ConsoleRow, expected: RowActivation) {
        #expect(RowActivation.destination(for: row) == expected)
    }

    @Test("every tab with rows is covered, and only Stats and Alerts open nothing")
    func everyTab() {
        for tab in ConsoleSection.allCases {
            let opens = RowActivation.destination(for: ConsoleRow(section: tab, key: "k")) != .none
            #expect(opens == !(tab == .stats || tab == .cluster), "\(tab)")
        }
    }

    @Test("detail wins over a log, a log alone opens the pane, neither opens nothing")
    func rule() {
        let log = LogPaneSource.pod(key: "default/web-0")
        #expect(RowActivation.resolve(detail: .pod("default/web-0"), log: log) == .detail(.pod("default/web-0")))
        #expect(RowActivation.resolve(detail: nil, log: log) == .logs(log))
        #expect(RowActivation.resolve(detail: nil, log: nil) == .none)
    }
}
