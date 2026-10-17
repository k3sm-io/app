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

@Suite("the log pane along the bottom of the window")
struct LogPaneTests {
    private static func build(_ title: String) throws -> BuildLogTarget {
        BuildLogTarget(id: try #require(BuildRecordID("aaaaaaaaaaaa")), title: title, follow: true)
    }

    @Test("a log opens the pane, another replaces it, and close empties it")
    func openReplaceClose() throws {
        var pane = LogPaneState()
        #expect(!pane.isOpen)
        #expect(pane.title == nil)

        #expect(pane.open(.pod(key: "default/web-1")) == nil)
        #expect(pane.isOpen)
        #expect(pane.title == "Log of default/web-1")
        #expect(pane.source?.podKey == "default/web-1")

        // Another log replaces the pane's content; the caller learns which, to stop its read.
        let build = try Self.build("web:dev")
        #expect(pane.open(.build(build)) == .pod(key: "default/web-1"))
        #expect(pane.title == "Build log of web:dev")
        #expect(pane.source?.podKey == nil)
        #expect(pane.open(.pod(key: "kube-system/dns")) == .build(build))

        #expect(pane.close() == .pod(key: "kube-system/dns"))
        #expect(!pane.isOpen)
        #expect(pane.close() == nil)
    }

    @Test("the title names the source on one clipped line")
    func titleIsClipped() throws {
        let long = String(repeating: "x", count: 400)
        let title = try #require(LogPaneSource.build(try Self.build(long + "\nline two")).title as String?)
        #expect(!title.contains("\n"))
        #expect(title.count < 400)
        #expect(title == StatusDisplay.clip("Build log of " + long + "\nline two"))
    }

    @Test("the pane opens at a third of the window, keeps a drag, and clamps its height")
    func heightClampAndPersistence() {
        // Nothing stored: a third of the window.
        #expect(LogPaneHeight.restore(from: nil) == nil)
        #expect(LogPaneHeight.shown(stored: nil, total: 900) == 300)
        // A short window still leaves the console its room above, never below the minimum.
        #expect(LogPaneHeight.shown(stored: nil, total: 300) == LogPaneHeight.minimum)
        #expect(LogPaneHeight.range(total: 900)
            == LogPaneHeight.minimum...(900 - LogPaneHeight.aboveMinimum - TabStripLayout.dividerWidth))
        #expect(LogPaneHeight.shown(stored: 5000, total: 900) == LogPaneHeight.range(total: 900).upperBound)
        #expect(LogPaneHeight.shown(stored: 10, total: 900) == LogPaneHeight.minimum)

        // A drag is stored at least the minimum and read back across a relaunch.
        #expect(LogPaneHeight.dragged(40) == LogPaneHeight.minimum)
        #expect(LogPaneHeight.dragged(.nan) == nil)
        let defaults = UserDefaults(suiteName: "LogPaneTests.\(UUID().uuidString)")!
        defaults.set(LogPaneHeight.dragged(260), forKey: LogPaneHeight.key)
        #expect(LogPaneHeight.restore(from: defaults.object(forKey: LogPaneHeight.key)) == 260)
        #expect(LogPaneHeight.restore(from: 50) == LogPaneHeight.minimum)
        #expect(LogPaneHeight.restore(from: "tall") == nil)
        #expect(LogPaneHeight.restore(from: -3.0) == nil)
        #expect(AppPreferences.layoutKeys.contains(LogPaneHeight.key))
    }

    @Test("after the pane opens only a drag or a reset moves its edge")
    func heightFixedAfterFirstLayout() {
        var keeper = PaneKeeper()
        // Opened with nothing stored: the default third is placed once ...
        #expect(keeper.place(LogPaneHeight.keeperValue(stored: nil)) != nil)
        // ... and a window resize, which stores nothing, does not place it again.
        #expect(keeper.place(LogPaneHeight.keeperValue(stored: nil)) == nil)
        // A drag records its height; the model storing it moves nothing.
        keeper.dragged(to: LogPaneHeight.keeperValue(stored: LogPaneHeight.dragged(250)))
        #expect(keeper.place(LogPaneHeight.keeperValue(stored: 250)) == nil)
        // Reset Window Layout stores nothing again: the third is placed.
        #expect(keeper.place(LogPaneHeight.keeperValue(stored: nil)) != nil)
    }

    @Test("the inspector no longer carries the log body; Open Log opens the pane")
    func inspectorCarriesNoLog() {
        #expect(!PodDetail.inspectorTabs.contains(.logs))
        #expect(PodDetail.inspectorTabs == [.events, .manifest])
        #expect(PodDetail.logs.opensLogPane)
        #expect(!PodDetail.events.opensLogPane && !PodDetail.manifest.opensLogPane)
        #expect(Help.Inspector.logs.label == "Open Log")
        // Follow and Stop are the pane's controls now, not the inspector's.
        let inspector = Set(Help.Inspector.all.compactMap(\.label))
        #expect(!inspector.contains("Follow") && !inspector.contains("Stop"))
        #expect(Help.LogPane.all.contains(Help.LogPane.follow))
        #expect(Help.LogPane.all.contains(Help.LogPane.close))
    }
}
