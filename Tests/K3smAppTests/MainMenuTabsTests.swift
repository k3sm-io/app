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

import AppKit
import K3smStatus
import Testing

@testable import K3smApp

/// View's tab items: Control-Tab and Control-Shift-Tab step through the tabs,
/// Command-1 to Command-9 pick them in strip order, each item carries its
/// catalog help tag, and none is offered before the console shows its tabs.
@MainActor
@Suite struct MainMenuTabsTests {
    @Test func tabItemsCarrySafarisShortcuts() {
        _ = NSApplication.shared
        let app = AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
        let menu = MainMenu(model: app, show: {}, settings: {})
        let items = menu.tabItems()
        #expect(items.count == 3 + ConsoleSection.allCases.count)

        let next = items[0], previous = items[1]
        #expect(next.title == "Show Next Tab" && next.keyEquivalent == "\t")
        #expect(next.keyEquivalentModifierMask == [.control])
        #expect(previous.title == "Show Previous Tab" && previous.keyEquivalent == "\t")
        #expect(previous.keyEquivalentModifierMask == [.control, .shift])
        #expect(next.toolTip == Help.Menus.nextTab.text)
        #expect(previous.toolTip == Help.Menus.previousTab.text)
        #expect(items[2].isSeparatorItem)

        for (i, section) in ConsoleSection.allCases.enumerated() {
            let item = items[3 + i]
            #expect(item.title == section.title)
            #expect(item.keyEquivalent == String(i + 1))
            #expect(item.keyEquivalentModifierMask == [.command])
            #expect(item.representedObject as? String == section.rawValue)
            #expect(item.toolTip == Help.Menus.tab(section).text)
            #expect(item.toolTip?.hasSuffix("(Command-\(i + 1))") == true)
        }

        // Before the first health check the console shows no tabs, so no tab item is offered.
        #expect(!app.pane.stripShown)
        for item in items where !item.isSeparatorItem {
            #expect(!menu.validateMenuItem(item), "\(item.title)")
        }
    }
}
