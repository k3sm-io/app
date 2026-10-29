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
import Testing
@testable import K3smStatus

@Suite("SidePanelButtonGlyph")
struct SidePanelButtonGlyphTests {
    @Test("each state names a panel glyph that resolves, never a bare rectangle")
    func glyphPerState() {
        #expect(TabStripLayout.detailsSymbol(shown: true) == "rectangle.trailinghalf.inset.filled")
        #expect(TabStripLayout.detailsSymbol(shown: false) == "sidebar.trailing")
        for shown in [true, false] {
            let name = TabStripLayout.detailsSymbol(shown: shown)
            #expect(name != "rectangle")
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
    }
}
