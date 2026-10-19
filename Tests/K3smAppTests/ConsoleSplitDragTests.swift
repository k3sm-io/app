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
import CoreGraphics
import K3smStatus
import SwiftUI
import Testing

@testable import K3smApp

/// These put the console's split (`ConsoleSplit`) in a real window, hosted
/// as `ConsoleView` hosts it, and drag its dividers the way a user does: a
/// mouse-down on the divider, then drags and a mouse-up from the event
/// queue, so AppKit runs its own divider tracking. A drag moves only the
/// panes on either side of the divider; the window keeps its frame.
@MainActor
@Suite("the console's dividers", .serialized, .enabled(if: SplitWindow.windowServer))
struct ConsoleSplitDragTests {
    @Test("dragging the inspector's divider widens the inspector, not the window")
    func inspectorDividerKeepsTheWindow() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            let column = harness.inner.arrangedSubviews[1].frame.width
            harness.drag(harness.inner, divider: 1, by: -100)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector + 100)
            #expect(harness.inner.arrangedSubviews[1].frame.width == column - 100)
            #expect(harness.app.inspectorWidth == Double(inspector + 100))
        }
    }

    @Test("the inspector's divider stops where the tab column reaches its minimum")
    func inspectorDividerStopsAtTheColumnMinimum() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -2000)
            #expect(harness.window.frame == before)
            #expect(abs(harness.inner.arrangedSubviews[1].frame.width - ConsoleView.contentMinWidth()) < 1)
            #expect(harness.inner.arrangedSubviews[2].frame.width <= CGFloat(InspectorWidth.ceiling))
        }
    }

    @Test("the inspector's divider stops at the inspector's ceiling in a wide window")
    func inspectorDividerStopsAtTheCeiling() throws {
        try SplitWindow.with(extraWidth: 1000) { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -2000)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(InspectorWidth.ceiling))
            #expect(harness.app.inspectorWidth == InspectorWidth.ceiling)
        }
    }

    @Test("the inspector's divider stops at the inspector's minimum")
    func inspectorDividerStopsAtTheInspectorMinimum() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -100)
            let narrower = harness.inner.arrangedSubviews[2].frame.width - CGFloat(InspectorWidth.minimum)
            #expect(narrower >= 100)
            harness.drag(harness.inner, divider: 1, by: narrower + 20)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(InspectorWidth.minimum))
            #expect(harness.app.inspectorShown)
        }
    }

    @Test("dragging the panel's divider narrows the panel, not the window")
    func panelDividerKeepsTheWindow() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            let panel = harness.inner.arrangedSubviews[0].frame.width
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            // The panel opens at its natural width, the top of its range.
            #expect(panel == CGFloat(SplitWindow.panelNatural))
            harness.drag(harness.inner, divider: 0, by: -80)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[0].frame.width == panel - 80)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector)
            #expect(harness.app.consolePanelWidth.dragged == Double(panel - 80))
        }
    }

    @Test("dragging the log pane's top edge raises the pane, not the window")
    func logPaneEdgeKeepsTheWindow() throws {
        try SplitWindow.with(logOpen: true) { harness in
            let before = harness.window.frame
            let logs = harness.outer.arrangedSubviews[1].frame.height
            harness.drag(harness.outer, divider: 0, by: -60)
            #expect(harness.window.frame == before)
            #expect(harness.outer.arrangedSubviews[1].frame.height == logs + 60)
        }
    }

    @Test("the inspector opens at its stored width and keeps it", arguments: [nil, 400.0])
    func inspectorOpensAtTheStoredWidth(stored: Double?) throws {
        let wanted = stored ?? InspectorWidth.defaultWidth
        try SplitWindow.with(stored: stored.map { [InspectorWidth.key: $0] } ?? [:]) { harness in
            #expect(harness.app.inspectorWidth == wanted)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(wanted))
        }
    }

    @Test("the panel opens at its stored width and keeps it")
    func panelOpensAtTheStoredWidth() throws {
        let wanted = PanelLayout.minimum + 60
        try SplitWindow.with(stored: [PanelLayout.widthKey: wanted]) { harness in
            #expect(harness.app.consolePanelWidth.dragged == wanted)
            #expect(harness.inner.arrangedSubviews[0].frame.width == CGFloat(wanted))
        }
    }

    @Test("the log pane opens at its stored height and keeps it")
    func logPaneOpensAtTheStoredHeight() throws {
        let wanted = LogPaneHeight.minimum + 60
        try SplitWindow.with(logOpen: true, stored: [LogPaneHeight.key: wanted]) { harness in
            #expect(harness.app.logPaneHeight == wanted)
            #expect(harness.outer.arrangedSubviews[1].frame.height == CGFloat(wanted))
        }
    }

    @Test("resizing the window gives the change to the tab column")
    func windowResizeGoesToTheColumn() throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0].frame.width
            let column = harness.inner.arrangedSubviews[1].frame.width
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            var frame = harness.window.frame
            frame.size.width -= 150
            harness.window.setFrame(frame, display: true)
            harness.settle()
            #expect(harness.window.frame == frame)
            #expect(harness.inner.arrangedSubviews[0].frame.width == panel)
            #expect(harness.inner.arrangedSubviews[1].frame.width == column - 150)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector)
            #expect(harness.app.inspectorWidth == InspectorWidth.defaultWidth)
            #expect(harness.app.consolePanelWidth.dragged == nil)
        }
    }
}

/// SplitRoot hosts the split as `ConsoleView` does, following the model, so
/// a drag that the model records renders again as it does in the app.
private struct SplitRoot: View {
    @ObservedObject var app: AppModel
    let logOpen: Bool

    var body: some View {
        let size = ConsoleView.minSize(inspectorShown: true, panelCollapsed: false)
        ConsoleSplit(
            app: app,
            range: app.consolePanelWidth.range(estimate: SplitWindow.panelNatural),
            width: app.consolePanelWidth.shown(estimate: SplitWindow.panelNatural),
            collapsed: false,
            contentMinimum: Double(ConsoleView.contentMinWidth()),
            inspectorWidth: app.inspectorWidth,
            inspectorShown: true,
            panel: Color.blue.ignoresSafeArea(),
            content: Color.white.ignoresSafeArea(),
            inspector: Color.gray.ignoresSafeArea(),
            logHeight: app.logPaneHeight,
            logOpen: logOpen,
            logPane: Color.black.ignoresSafeArea())
        .frame(minWidth: size.width, minHeight: size.height)
        .ignoresSafeArea()
    }
}

/// SplitWindow is one console split in a transparent window, as the main
/// window controller builds it, with the layout defaults put back after.
@MainActor
struct SplitWindow {
    /// The panel's natural width in these tests.
    static let panelNatural: Double = PanelLayout.minimum + 150

    /// Whether this process can open a window at all: a gate run over SSH
    /// without a login session cannot.
    nonisolated static var windowServer: Bool { CGSessionCopyCurrentDictionary() != nil }

    let app: AppModel
    let window: NSWindow
    let outer: NSSplitView
    let inner: NSSplitView

    /// Opens the split with `stored` in the user defaults (a layout key to
    /// its value), as a launch after an earlier drag finds them.
    static func with(logOpen: Bool = false, extraWidth: CGFloat = 400, stored: [String: Any] = [:],
                     _ body: (SplitWindow) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let kept = AppPreferences.layoutKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in kept {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, _) in kept { defaults.removeObject(forKey: key) }
        for (key, value) in stored { defaults.set(value, forKey: key) }

        _ = NSApplication.shared
        let app = AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentViewController = NSHostingController(rootView: SplitRoot(app: app, logOpen: logOpen))
        let minimum = ConsoleView.minSize(inspectorShown: true, panelCollapsed: false)
        window.setFrame(NSRect(x: 40, y: 40, width: minimum.width + extraWidth, height: minimum.height + 60), display: true)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let harness = try SplitWindow(app: app, window: window)
        harness.settle()
        try body(harness)
    }

    private init(app: AppModel, window: NSWindow) throws {
        self.app = app
        self.window = window
        let splits = Self.splits(in: try #require(window.contentView))
        outer = try #require(splits.first { !$0.isVertical })
        inner = try #require(splits.first { $0.isVertical })
    }

    private static func splits(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
    }

    /// Lets AppKit and SwiftUI finish the layout and any update a drag caused.
    func settle() {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.layoutIfNeeded()
    }

    /// Drags `split`'s divider `divider` by `delta` points along the split's
    /// axis (rightward or downward is positive), as a user's mouse does.
    func drag(_ split: NSSplitView, divider: Int, by delta: CGFloat) {
        let before = split.arrangedSubviews[divider].frame
        let half = split.dividerThickness / 2
        let start = split.isVertical
            ? NSPoint(x: before.maxX + half, y: split.bounds.midY)
            : NSPoint(x: split.bounds.midX, y: before.maxY + half)
        func event(_ type: NSEvent.EventType, _ offset: CGFloat) -> NSEvent {
            let point = split.isVertical ? NSPoint(x: start.x + offset, y: start.y) : NSPoint(x: start.x, y: start.y + offset)
            return NSEvent.mouseEvent(with: type, location: split.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Posting an event stops the innermost running run loop, to wake a
        // reader. Run directly, that is the test runner's own loop, which
        // then returns and ends the process; so the posts and the drag run
        // in a nested pass of the loop, and the post stops that one.
        var dragged = false
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            for step in 1...10 {
                NSApp.postEvent(event(.leftMouseDragged, delta * CGFloat(step) / 10), atStart: false)
            }
            NSApp.postEvent(event(.leftMouseUp, delta), atStart: false)
            split.mouseDown(with: event(.leftMouseDown, 0))
            dragged = true
        }
        while !dragged { _ = CFRunLoopRunInMode(.defaultMode, 1, false) }
        settle()
    }
}
