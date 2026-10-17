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

/// ConsoleSplit is the console's split view: the navy panel on the left, the
/// tabs and the inspector on the right, a thin divider between them that the
/// user drags. The panel's width stays within `range` (its minimum to its
/// natural width, `PanelLayout.naturalWidth`) and is drawn at `width` (the
/// natural width while auto-sized); a drag records the width on the model
/// (`PanelLayout.dragged`: back to auto once it reaches the natural width), a
/// double-click on the divider collapses or expands the panel, and the
/// model's collapsed flag (View > Hide Panel) drives the same item. Built on
/// `NSSplitViewController`, since `HSplitView` offers no collapse and no way
/// to restore a width.
struct ConsoleSplit<Panel: View, Content: View>: NSViewControllerRepresentable {
    let app: AppModel
    let range: ClosedRange<Double>
    let width: Double
    let collapsed: Bool
    let contentMinimum: Double
    let panel: Panel
    let content: Content

    func makeNSViewController(context: Context) -> ConsoleSplitController {
        // The split items carry the sizes, so the hosted views add no
        // constraints of their own.
        let panelHost = NSHostingController(rootView: panel)
        panelHost.sizingOptions = []
        let contentHost = NSHostingController(rootView: content)
        contentHost.sizingOptions = []
        let controller = ConsoleSplitController(panel: panelHost, content: contentHost)
        controller.onDrag = { [weak app] width, natural in
            app?.panelDragged(width, natural: natural)
        }
        controller.onCollapse = { [weak app] collapsed in
            if app?.consolePanelCollapsed != collapsed { app?.consolePanelCollapsed = collapsed }
        }
        controller.apply(range: range, width: width, collapsed: collapsed, contentMinimum: contentMinimum)
        return controller
    }

    func updateNSViewController(_ controller: ConsoleSplitController, context: Context) {
        controller.apply(range: range, width: width, collapsed: collapsed, contentMinimum: contentMinimum)
    }
}

/// ConsoleSplitController holds the two panes. The panel keeps its width
/// while the window resizes (a higher holding priority), so the content
/// takes the change.
@MainActor
final class ConsoleSplitController: NSSplitViewController {
    private let panelItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    /// A user's drag of the divider, as the panel's new width and the
    /// range's upper bound (the natural width) it was dragged within.
    var onDrag: (Double, Double) -> Void = { _, _ in }
    /// The range last applied.
    private var range: ClosedRange<Double> = PanelLayout.minimum...PanelLayout.minimum
    /// A user's collapse or expand by double-clicking the divider.
    var onCollapse: (Bool) -> Void = { _ in }
    /// The width last asked of the split view, so an update that changes
    /// neither the stored width nor the range does not move the divider.
    private var placed: Double?
    /// The width waiting for the first layout, when the split has no size yet.
    private var pending: Double?
    /// Set while this controller moves the divider itself.
    private var moving = false

    init(panel: NSViewController, content: NSViewController) {
        panelItem = NSSplitViewItem(viewController: panel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = PanelLayout.minimum
        panelItem.holdingPriority = NSLayoutConstraint.Priority(260)
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.holdingPriority = .defaultLow
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(panelItem)
        addSplitViewItem(contentItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the split to the model: the panel's range, its collapsed
    /// state, the content's minimum, and the stored width within the range.
    func apply(range: ClosedRange<Double>, width: Double, collapsed: Bool, contentMinimum: Double) {
        self.range = range
        panelItem.maximumThickness = range.upperBound
        contentItem.minimumThickness = contentMinimum
        if panelItem.isCollapsed != collapsed {
            moving = true
            panelItem.isCollapsed = collapsed
            moving = false
            placed = nil
        }
        guard !collapsed else { return }
        let target = PanelLayout.clamp(width, to: range)
        guard target != placed else { return }
        placed = target
        place(target)
    }

    private func place(_ width: Double) {
        guard splitView.bounds.width > 0 else {
            pending = width
            return
        }
        pending = nil
        moving = true
        splitView.setPosition(width, ofDividerAt: 0)
        moving = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let pending, splitView.bounds.width > 0 { place(pending) }
    }

    override func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                            forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        subview == panelItem.viewController.view
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !moving else { return }
        let collapsed = panelItem.isCollapsed
        onCollapse(collapsed)
        // The divider index is in the notification only when the user moved
        // the divider; a window resize leaves the stored width alone.
        if !collapsed, notification.userInfo?["NSSplitViewDividerIndex"] != nil {
            let width = Double(panelItem.viewController.view.frame.width)
            placed = width
            onDrag(width, range.upperBound)
        }
    }
}
