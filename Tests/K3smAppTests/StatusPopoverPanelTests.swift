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

import CoreGraphics
import Testing

@testable import K3smApp

/// The info popover's tallest height: the screen's visible height less the
/// margin, never under the floor, 800 pt standing in for a missing screen.
/// Before the cap, the panel was as tall as its content and an open All
/// checks list ran past the screen with nothing to scroll.
struct StatusPopoverPanelTests {
    @Test func capFollowsTheScreenLessTheMargin() {
        #expect(StatusPopoverPanel.maxHeight(screen: 900) == 900 - StatusPopoverPanel.screenMargin)
    }

    @Test func capNeverDropsUnderTheFloor() {
        #expect(StatusPopoverPanel.maxHeight(screen: 250) == StatusPopoverPanel.floor)
    }

    @Test func noScreenStandsInAt800() {
        #expect(StatusPopoverPanel.maxHeight(screen: nil) == 800 - StatusPopoverPanel.screenMargin)
    }

    @Test func shortContentTakesItsOwnHeight() {
        #expect(StatusPopoverPanel.height(content: 300, screen: 900) == 300)
    }

    @Test func tallContentIsCappedAtTheScreen() {
        #expect(StatusPopoverPanel.height(content: 2000, screen: 900) == 900 - StatusPopoverPanel.screenMargin)
    }

    @Test func unmeasuredContentLeavesTheHeightToThePopover() {
        #expect(StatusPopoverPanel.height(content: nil, screen: 900) == nil)
    }
}
