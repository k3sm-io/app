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

/// The console window's minimum reads its inputs from the model in one
/// place (`AppModel.consoleMinimumInputs`); these check that they carry the
/// model's state as it is set.
@MainActor
@Suite("the console minimum's inputs", .serialized)
struct ConsoleMinimumInputsTests {
    @Test("the console minimum's inputs carry the model's inspector, pane, panel and buttons edge")
    func consoleMinimumInputsReadsModelState() {
        // The inspector and panel setters write the user defaults; put back
        // what was there, so the run leaves them as it found them.
        let defaults = UserDefaults.standard
        let keys = [AppModel.inspectorShownKey, PanelLayout.collapsedKey]
        let kept = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in kept {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        _ = NSApplication.shared
        let app = AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
        // The pane is the model's own (set by its health check); before the
        // first check it is the checking pane, which shows no strip.
        #expect(app.pane == .checking)
        for (shown, collapsed, edge) in [(true, true, 69.0), (false, false, nil), (true, false, 120.0)] as [(Bool, Bool, Double?)] {
            app.inspectorShown = shown
            app.consolePanelCollapsed = collapsed
            app.windowButtonsEdge = edge
            let inputs = app.consoleMinimumInputs
            #expect(inputs.inspectorShown == shown)
            #expect(inputs.stripShown == app.pane.stripShown)
            #expect(!inputs.stripShown)
            #expect(inputs.panelCollapsed == collapsed)
            #expect(inputs.windowButtonsEdge == edge)
            #expect(inputs.developerBadge == ConsoleView.developerBadge(app))
            #expect(inputs.labels == AppModel.consoleTabLabels)
        }
    }
}
