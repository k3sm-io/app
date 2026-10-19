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
/// tab column in the middle and the inspector on the right, with a thin
/// divider between each that the user drags. The panel's width stays within
/// `range` (its minimum to the natural width fixed at the window's layout,
/// `PanelWidth`) and is drawn at `width`; a drag records the width on the
/// model (`PanelWidth.drag`), a double-click on the divider collapses or
/// expands the panel, and the model's collapsed flag (View > Hide Panel)
/// drives the same item. The inspector opens at `inspectorWidth` and moves
/// only when the user drags its divider (`InspectorWidth`, `PaneKeeper`),
/// between its minimum and the widest that leaves the tab column at
/// `contentMinimum`; the details button collapses and shows it. Under all
/// three, the log pane (`logPane`) runs the window's full width while a log
/// is open, its top edge dragged between `LogPaneHeight.minimum` and what
/// leaves the console above it room (`LogPaneHeight`, `PaneKeeper`). Built
/// on `NSSplitViewController`, since `HSplitView` offers no collapse and no
/// way to restore a width.
struct ConsoleSplit<Panel: View, Content: View, Details: View, Logs: View>: NSViewControllerRepresentable {
    let app: AppModel
    let range: ClosedRange<Double>
    let width: Double
    let collapsed: Bool
    let contentMinimum: Double
    let inspectorWidth: Double
    let inspectorShown: Bool
    let panel: Panel
    let content: Content
    let inspector: Details
    let logHeight: Double?
    let logOpen: Bool
    let logPane: Logs

    func makeNSViewController(context: Context) -> ConsoleLogSplitController {
        // The split items carry the sizes, so the hosted views add no
        // constraints of their own.
        let panelHost = NSHostingController(rootView: panel)
        panelHost.sizingOptions = []
        let contentHost = NSHostingController(rootView: content)
        contentHost.sizingOptions = []
        let inspectorHost = NSHostingController(rootView: inspector)
        inspectorHost.sizingOptions = []
        let controller = ConsoleSplitController(panel: panelHost, content: contentHost, inspector: inspectorHost)
        controller.onDrag = { [weak app] width in
            app?.panelDragged(width)
        }
        controller.onCollapse = { [weak app] collapsed in
            if app?.consolePanelCollapsed != collapsed { app?.consolePanelCollapsed = collapsed }
        }
        controller.onInspectorDrag = { [weak app] width in
            app?.inspectorDragged(width)
        }
        controller.onInspectorCollapse = { [weak app] collapsed in
            if app?.inspectorShown == collapsed { app?.inspectorShown = !collapsed }
        }
        let logHost = NSHostingController(rootView: logPane)
        logHost.sizingOptions = []
        let outer = ConsoleLogSplitController(console: controller, logs: logHost)
        outer.onDrag = { [weak app] height in app?.logPaneDragged(height) }
        outer.onCollapse = { [weak app] in
            if app?.logPane.isOpen == true { app?.closeLogPane() }
        }
        apply(outer)
        return outer
    }

    func updateNSViewController(_ controller: ConsoleLogSplitController, context: Context) {
        apply(controller)
    }

    /// The split takes whatever size it is offered. Left to the default,
    /// SwiftUI sizes it to the split view's fitting size, which a divider
    /// drag changes (AppKit holds the dragged divider at a priority that
    /// may resize the window), and the window's hosting controller follows
    /// that size: the drag moved the window's edge, not the divider. The
    /// window's own minimum is `ConsoleView`'s frame, and a window resize
    /// still goes to the tab column, by the items' holding priorities.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ConsoleLogSplitController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    private func apply(_ outer: ConsoleLogSplitController) {
        let controller = outer.console
        controller.apply(range: range, width: width, collapsed: collapsed, contentMinimum: contentMinimum)
        controller.applyInspector(width: inspectorWidth, shown: inspectorShown)
        outer.apply(height: logHeight, open: logOpen)
    }
}

/// ConsoleLogSplitController stacks the console's three panes over the log
/// pane. The log pane keeps its height while the window resizes (a higher
/// holding priority), so the console above takes the change; it is
/// collapsed while no log is open.
@MainActor
final class ConsoleLogSplitController: NSSplitViewController {
    let console: ConsoleSplitController
    private let consoleItem: NSSplitViewItem
    private let logItem: NSSplitViewItem
    /// A user's drag of the pane's top edge, as the pane's new height.
    var onDrag: (Double) -> Void = { _ in }
    /// The pane collapsed by the split itself (a drag past its minimum).
    var onCollapse: () -> Void = {}
    private var keeper = PaneKeeper()
    /// The stored height waiting for a layout (nil for none waiting; the
    /// inner nil, a third of the window).
    private var pending: Double??
    private var moving = false

    init(console: ConsoleSplitController, logs: NSViewController) {
        self.console = console
        consoleItem = NSSplitViewItem(viewController: console)
        consoleItem.minimumThickness = LogPaneHeight.aboveMinimum
        consoleItem.holdingPriority = .defaultLow
        logItem = NSSplitViewItem(viewController: logs)
        logItem.canCollapse = true
        logItem.minimumThickness = LogPaneHeight.minimum
        logItem.holdingPriority = NSLayoutConstraint.Priority(260)
        logItem.isCollapsed = true
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(consoleItem)
        addSplitViewItem(logItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the pane to the model: open or collapsed, and its stored
    /// height (nil for a third of the window) placed once per change.
    func apply(height: Double?, open: Bool) {
        if logItem.isCollapsed == open {
            moving = true
            logItem.isCollapsed = !open
            moving = false
            keeper.reset()
        }
        guard open, keeper.place(LogPaneHeight.keeperValue(stored: height)) != nil else { return }
        place(height)
    }

    private func place(_ stored: Double?) {
        let total = Double(splitView.bounds.height)
        guard total > 0 else {
            pending = .some(stored)
            return
        }
        pending = nil
        let divider = Double(splitView.dividerThickness)
        let height = LogPaneHeight.shown(stored: stored, total: total)
        moving = true
        splitView.setPosition(CGFloat(total - height - divider), ofDividerAt: 0)
        moving = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let pending, splitView.bounds.height > 0 { place(pending) }
    }

    override func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                            forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        false
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !moving else { return }
        if logItem.isCollapsed {
            onCollapse()
            return
        }
        // The divider index is in the notification only when the user moved
        // the divider; a window resize leaves the stored height alone.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let height = Double(logItem.viewController.view.frame.height)
        keeper.dragged(to: LogPaneHeight.keeperValue(stored: LogPaneHeight.dragged(height)))
        onDrag(height)
    }
}

/// ConsoleSplitController holds the three panes. The panel and the
/// inspector keep their widths while the window resizes (a higher holding
/// priority), so the tab column takes the change.
@MainActor
final class ConsoleSplitController: NSSplitViewController {
    private let panelItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    /// A user's drag of the panel's divider, as the panel's new width.
    var onDrag: (Double) -> Void = { _ in }
    /// A user's collapse or expand by double-clicking the divider.
    var onCollapse: (Bool) -> Void = { _ in }
    /// A user's drag of the inspector's divider, as its new width.
    var onInspectorDrag: (Double) -> Void = { _ in }
    /// The inspector collapsed or shown by the split itself (a drag past
    /// its minimum).
    var onInspectorCollapse: (Bool) -> Void = { _ in }
    /// The width last asked of the split view, so an update that changes
    /// neither the stored width nor the range does not move the divider.
    private var placed: Double?
    /// The width waiting for the first layout, when the split has no size yet.
    private var pending: Double?
    /// The inspector's placed width, and the one waiting for a layout.
    private var inspectorKeeper = PaneKeeper()
    private var inspectorPending: Double?
    /// The tab column's minimum, last applied.
    private var contentMinimum: Double = 0
    /// Set while this controller moves a divider itself.
    private var moving = false

    init(panel: NSViewController, content: NSViewController, inspector: NSViewController) {
        panelItem = NSSplitViewItem(viewController: panel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = PanelLayout.minimum
        panelItem.holdingPriority = NSLayoutConstraint.Priority(260)
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.holdingPriority = .defaultLow
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = InspectorWidth.minimum
        inspectorItem.maximumThickness = InspectorWidth.ceiling
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(panelItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the split to the model: the panel's range, its collapsed
    /// state, the content's minimum, and the stored width within the range.
    func apply(range: ClosedRange<Double>, width: Double, collapsed: Bool, contentMinimum: Double) {
        self.contentMinimum = contentMinimum
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

    /// Brings the inspector to the model: shown or collapsed, and its
    /// stored width placed once per change of that width.
    func applyInspector(width: Double, shown: Bool) {
        if inspectorItem.isCollapsed == shown {
            moving = true
            inspectorItem.isCollapsed = !shown
            moving = false
            inspectorKeeper.reset()
        }
        guard shown, let target = inspectorKeeper.place(width) else { return }
        placeInspector(target)
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

    /// Moves the inspector's divider so the inspector is `width` wide, or
    /// as near as the tab column's minimum allows.
    private func placeInspector(_ width: Double) {
        let total = Double(splitView.bounds.width)
        guard total > 0 else {
            inspectorPending = width
            return
        }
        inspectorPending = nil
        let divider = Double(splitView.dividerThickness)
        let panel = panelItem.isCollapsed ? 0 : Double(panelItem.viewController.view.frame.width) + divider
        let shown = InspectorWidth.clamp(width, to: InspectorWidth.range(shared: total - panel, columnMinimum: contentMinimum))
        moving = true
        splitView.setPosition(CGFloat(total - shown - divider), ofDividerAt: 1)
        moving = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.bounds.width > 0 else { return }
        if let pending { place(pending) }
        if let inspectorPending { placeInspector(inspectorPending) }
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
        let inspectorCollapsed = inspectorItem.isCollapsed
        onInspectorCollapse(inspectorCollapsed)
        // The divider index is in the notification only when the user moved
        // a divider; a window resize leaves the stored widths alone.
        guard let index = notification.userInfo?["NSSplitViewDividerIndex"] as? Int else { return }
        if index == 0, !collapsed {
            let width = Double(panelItem.viewController.view.frame.width)
            placed = width
            onDrag(width)
        } else if index == 1, !inspectorCollapsed {
            let width = Double(inspectorItem.viewController.view.frame.width)
            inspectorKeeper.dragged(to: InspectorWidth.dragged(width))
            onInspectorDrag(width)
        }
    }
}
