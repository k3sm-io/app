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

@Suite("the console's selection, one per tab")
struct ConsoleSelectionTests {
    @Test("a tab change shows the new tab's selection, empty when none, and a row still listed comes back")
    func inspectorClearsOnTabChange() {
        var s = ConsoleSelection(active: .images)
        #expect(s.current == nil)
        let r1 = s.select(.image("sha256:a"), in: .images)
        #expect(r1)
        #expect(s.current == .image("sha256:a"))

        // Services has no selection: the inspector is empty there.
        let r2 = s.switchTo(.services)
        #expect(r2 == nil)
        #expect(s.active == .services)
        #expect(s.current == nil)

        // A selection made on Services is that tab's alone.
        let r3 = s.select(.service("shop/web"), in: .services)
        #expect(r3)
        #expect(s.current == .service("shop/web"))
        #expect(s.selection(in: .images) == .image("sha256:a"))

        // Back on Images, its row is still listed: it is restored.
        let r4 = s.switchTo(.images, present: ["sha256:a", "sha256:b"])
        #expect(r4 == .image("sha256:a"))
        #expect(s.current == .image("sha256:a"))

        // Back on Services, its row is gone from the last read: nothing shows,
        // and it does not come back later.
        let r5 = s.switchTo(.services, present: ["shop/db"])
        #expect(r5 == nil)
        #expect(s.current == nil)
        let r6 = s.switchTo(.images)
        #expect(r6 == .image("sha256:a"))
        let r7 = s.switchTo(.services, present: ["shop/web"])
        #expect(r7 == nil)

        // A tab never read yet (no rows to check) keeps what was stored.
        let r9 = s.switchTo(.models)
        #expect(r9 == nil)
        let r10 = s.select(.model("ml/llama"), in: .models)
        #expect(r10)
        let r11 = s.switchTo(.builds)
        #expect(r11 == nil)
        let r12 = s.switchTo(.models, present: nil)
        #expect(r12 == .model("ml/llama"))
    }

    @Test("a row of another kind is refused, so one tab never shows another's row")
    func kindMustMatchTab() {
        var s = ConsoleSelection(active: .storage)
        let r13 = s.select(.service("shop/web"), in: .storage)
        #expect(r13 == false)
        #expect(s.current == nil)
        let r14 = s.select(.claim("pvc/shop/data"), in: .services)
        #expect(r14 == false)
        #expect(s.selection(in: .services) == nil)
        let r15 = s.select(.claim("pvc/shop/data"), in: .storage)
        #expect(r15)
        #expect(s.current == .claim("pvc/shop/data"))
    }

    @Test("a refresh that no longer lists the selected row clears it, on the active tab or another")
    func disappearingRowClears() {
        var s = ConsoleSelection(active: .models, rows: [.model("ml/a"), .claim("pvc/x/y")])
        s.retain(.models, present: ["ml/a", "ml/b"])
        #expect(s.current == .model("ml/a"))
        s.retain(.models, present: ["ml/b"])
        #expect(s.current == nil)
        s.retain(.storage, present: [])
        #expect(s.selection(in: .storage) == nil)
        // A refresh never selects for the user.
        s.retain(.models, present: ["ml/a"])
        #expect(s.current == nil)
        s.select(.model("ml/b"), in: .models)
        s.clear(.models)
        #expect(s.current == nil)
    }

    @Test("selecting again replaces the tab's row; the restored rows are one per tab")
    func replaceAndRestore() {
        var s = ConsoleSelection(active: .workloads, rows: [.pod("a/p"), .image("i"), .pod("a/q")])
        #expect(s.current == .pod("a/q"))
        #expect(s.selection(in: .images) == .image("i"))
        s.select(.pod("a/r"), in: .workloads)
        #expect(s.current == .pod("a/r"))
        let restored = ConsoleSelection.restore(active: .images) { tab in
            tab == .images ? "sha256:\u{202E}x" : (tab == .services ? "" : nil)
        }
        #expect(restored.current == .image("sha256:x"))
        #expect(restored.selection(in: .services) == nil)
        #expect(ConsoleRow(section: .storage, key: "pv/v") == .claim("pv/v"))
        for tab in ConsoleSection.allCases {
            #expect(ConsoleRow(section: tab, key: "k").section == tab)
        }
    }
}
