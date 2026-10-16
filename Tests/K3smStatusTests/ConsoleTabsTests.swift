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

@Suite("console tabs and what they keep")
struct ConsoleTabsTests {
    @Test("a stored tab id this build does not know falls back to Workloads")
    func unknownPersistedTabFallsBackToWorkloads() {
        #expect(ConsoleTabs.restore(from: nil) == .workloads)
        #expect(ConsoleTabs.restore(from: "") == .workloads)
        #expect(ConsoleTabs.restore(from: "network") == .workloads)
        #expect(ConsoleTabs.restore(from: "services") == .services)
        #expect(ConsoleTabs.restore(from: "Images") == .workloads)
        #expect(ConsoleTabs.restore(from: 3) == .workloads)
        #expect(ConsoleTabs.restore(from: "images") == .images)
        #expect(ConsoleTabs.restore(from: "builds") == .builds)
        #expect(ConsoleTabs.restore(from: "workloads") == .workloads)
    }

    @Test("every tab round-trips through its stored id")
    func roundTrip() {
        for section in ConsoleSection.allCases {
            #expect(ConsoleTabs.restore(from: section.rawValue) == section)
        }
    }

    @Test("each tab keeps its search and selection under its own key")
    func keys() {
        #expect(ConsoleTabs.sectionKey == "consoleSection")
        #expect(ConsoleTabs.queryKey(.workloads) == "consoleQuery.workloads")
        #expect(ConsoleTabs.queryKey(.images) == "consoleQuery.images")
        #expect(ConsoleTabs.selectedKey(.images) == "consoleSelected.images")
        #expect(Set(ConsoleSection.allCases.map(ConsoleTabs.queryKey)).count == ConsoleSection.allCases.count)
    }

    @Test("a stored search or row key is clipped when read back")
    func persistedTextIsClipped() {
        #expect(ConsoleTabs.restoreQuery(from: nil) == "")
        #expect(ConsoleTabs.restoreQuery(from: 7) == "")
        #expect(ConsoleTabs.restoreQuery(from: "ngi\u{202E}nx\n") == "nginx ")
        #expect(ConsoleTabs.restoreQuery(from: String(repeating: "q", count: 400)).count == StatusDisplay.maxLength)
        #expect(ConsoleTabs.restoreSelected(from: nil) == nil)
        #expect(ConsoleTabs.restoreSelected(from: "") == nil)
        #expect(ConsoleTabs.restoreSelected(from: "default/web\u{200B}") == "default/web")
    }
}
