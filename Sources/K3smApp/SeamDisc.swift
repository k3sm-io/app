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
import SwiftUI

/// SeamDiscView is the one control on the panel's divider: a disc
/// `PanelLayout.seamDisc` wide in the selected-row tint, with one wing of the
/// mark in the strip's icon navy inside it, folded toward the panel while the
/// panel is open and turned away while the panel is a rail. The split places
/// it on the divider at its vertical middle and shows it only while the
/// divider is under the pointer (`DividerSplitView`). A click toggles the rail
/// and the panel (`onToggle`); a press that moves drags the divider as the
/// divider itself would (`onDragBegan`, `onDragMoved`, `onDragEnded`), so the
/// disc takes nothing from the seam it sits on. Its help tag and
/// accessibility label say Hide Panel or Show Panel, so the wing carries no
/// meaning a screen reader needs.
@MainActor
final class SeamDiscView: NSView {
    /// A click: toggle the rail and the panel.
    var onToggle: () -> Void = {}
    /// A press moved: the divider's drag begins at its current position.
    var onDragBegan: () -> Void = {}
    /// The press moved `dx` points from where it began.
    var onDragMoved: (CGFloat) -> Void = { _ in }
    /// The press ended after moving.
    var onDragEnded: () -> Void = {}
    /// The panel's state, which turns the wing and names the tag.
    var collapsed = false {
        didSet { if collapsed != oldValue { refresh() } }
    }
    /// How far a press moves before it is a drag rather than a click.
    static let dragSlop: CGFloat = 3

    private let wing: PassiveHostingView<SeamWing>

    init() {
        let size = CGFloat(PanelLayout.seamDisc)
        wing = PassiveHostingView(rootView: SeamWing(collapsed: false))
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        alphaValue = 0
        wing.frame = bounds
        wing.autoresizingMask = [.width, .height]
        addSubview(wing)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        wing.rootView = SeamWing(collapsed: collapsed)
        toolTip = Help.Panel.seam(collapsed: collapsed).text
        setAccessibilityLabel(collapsed ? "Show Panel" : "Hide Panel")
        setAccessibilityHelp(toolTip)
    }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor(Palette.tint).setFill()
        disc.fill()
        NSColor(Palette.navy).withAlphaComponent(0.3).setStroke()
        disc.lineWidth = 1
        disc.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow.x
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let dx = next.locationInWindow.x - start
            if !dragging {
                guard abs(dx) >= Self.dragSlop else { continue }
                dragging = true
                onDragBegan()
            }
            onDragMoved(dx)
        }
        if dragging {
            onDragEnded()
        } else {
            onToggle()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onToggle()
        return true
    }
}

/// SeamWing is the disc's wing: the half of the mark on the panel's side
/// while the panel is open (folded toward it), the other half while the
/// panel is a rail (turned away), centred in the disc.
struct SeamWing: View {
    let collapsed: Bool

    var body: some View {
        FlappingButterfly.half(left: !collapsed, color: Palette.navy)
            .frame(width: 16, height: 16)
            .offset(x: collapsed ? -4 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// PassiveHostingView hosts a SwiftUI view that takes no mouse events, so
/// the view under it gets every press.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
