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
import Combine
import K3smStatus
import Testing

@testable import K3smApp

/// The console window grows from the model's minimum-input changes
/// (`AppModel.consoleMinimumInputsChanged`) through `MinimumGrow.grows`;
/// these drive both without a window, on an immediate scheduler.
@MainActor
@Suite("the console window's grow on a minimum change", .serialized)
struct MinimumGrowTests {
    /// The inspector and panel setters write the user defaults; this keeps
    /// what was there so a test can put it back.
    private static func keepDefaults() -> [(String, Any?)] {
        let defaults = UserDefaults.standard
        return [AppModel.inspectorShownKey, PanelLayout.collapsedKey].map { ($0, defaults.object(forKey: $0)) }
    }

    private static func restore(_ kept: [(String, Any?)]) {
        let defaults = UserDefaults.standard
        for (key, value) in kept {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private static func makeModel() -> AppModel {
        _ = NSApplication.shared
        return AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
    }

    @Test("every input of the console minimum publishes a change")
    func everyMinimumInputPublishesAChange() {
        let kept = Self.keepDefaults()
        defer { Self.restore(kept) }

        let app = Self.makeModel()
        var sent = 0
        let sink = app.consoleMinimumInputsChanged.sink { sent += 1 }
        defer { sink.cancel() }
        // Each of the five inputs sends its current value on subscribe.
        #expect(sent == 5)

        sent = 0
        app.inspectorShown.toggle()
        #expect(sent == 1)
        app.consolePanelCollapsed.toggle()
        #expect(sent == 2)
        app.windowButtonsEdge = (app.windowButtonsEdge ?? 0) + 17
        #expect(sent == 3)
        // `pane` and `developerModeOn` are set only by the model's own
        // refresh (`private(set)`), so a test cannot change them here; the
        // five-per-subscribe count above shows both are merged in.
    }

    @Test("subscribing does not grow the window")
    func firstEmissionDoesNotGrow() {
        let kept = Self.keepDefaults()
        defer { Self.restore(kept) }

        let app = Self.makeModel()
        let start = WindowFrame.minimum(app.consoleMinimumInputs)
        var grows = 0
        let sink = MinimumGrow.grows(on: app.consoleMinimumInputsChanged,
                                     minimum: { WindowFrame.minimum(app.consoleMinimumInputs) },
                                     start: start, scheduler: ImmediateScheduler.shared)
            .sink { grows += 1 }
        defer { sink.cancel() }
        #expect(grows == 0)
    }

    @Test("a change that leaves the minimum equal does not grow the window, and a rise does")
    func equalMinimumDoesNotGrow() {
        let changes = PassthroughSubject<Void, Never>()
        let start = WindowFrame.Size(width: 800, height: 600)
        var current = start
        var grows = 0
        let sink = MinimumGrow.grows(on: changes.eraseToAnyPublisher(), minimum: { current },
                                     start: start, scheduler: ImmediateScheduler.shared)
            .sink { grows += 1 }
        defer { sink.cancel() }

        changes.send()
        changes.send()
        #expect(grows == 0)

        // The same pipeline grows on a rise, so the zero above is not vacuous.
        current = WindowFrame.Size(width: 900, height: 600)
        changes.send()
        #expect(grows == 1)
        changes.send()
        #expect(grows == 1)
    }

    /// One `@Published` input, read back through its stored property as the
    /// window controller reads the model's.
    private final class Width: ObservableObject {
        @Published var width: Double = 800
    }

    @Test("the minimum is read after the changed value is stored, so a rise grows the window")
    func minimumIsReadAfterTheChangeIsStored() async {
        // `@Published` sends before it stores: read on the same turn, the
        // minimum is still the old one and the rise would be missed.
        let input = Width()
        let start = WindowFrame.Size(width: input.width, height: 600)
        var grows = 0
        let sink = MinimumGrow.grows(on: input.$width.map { _ in () }.eraseToAnyPublisher(),
                                     minimum: { WindowFrame.Size(width: input.width, height: 600) },
                                     start: start, scheduler: DispatchQueue.main)
            .sink { grows += 1 }
        defer { sink.cancel() }

        input.width = 900
        // Let the main queue run the hop queued by the change.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(grows == 1)
    }
}
