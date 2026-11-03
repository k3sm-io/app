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
/// divider between each that the user drags. The panel never leaves the
/// split: its divider runs from `PanelLayout.railWidth` to the natural width
/// fixed at the window's layout (`range`, `PanelWidth`). While a drag runs
/// the divider rests only at the rail or from the panel's minimum up,
/// never where the column would be cut (`PanelLayout.dragWidth`, applied
/// through the split's position constraint): from the column it drops to
/// the rail once the pointer is inside the minimum, from the rail it jumps
/// to the minimum once pulled past `PanelLayout.openWidth` and follows the
/// pointer from there, the turn fixed by where the drag began. The panel
/// turns live with it (`AppModel.panelDragged`,
/// `PanelLayout.shouldSnapToRail`), and the drop decides where it rests
/// (`AppModel.panelDropped`, `PanelLayout.droppedWidth`): the rail, or the
/// column at the drop, recorded (`PanelWidth.drag`). The model's
/// `collapsed` flag holds the rail (also View > Hide/Show Panel, its
/// shortcut, or the seam disc). The seam disc (`SeamDiscView`, carried by
/// `DividerSplitView`) sits on the panel's divider at its vertical middle
/// and shows only while the divider is hovered: a click toggles the flag,
/// a press that moves drags the divider under the same constraint. A
/// double-click on the divider does nothing either way. The inspector opens at `inspectorWidth` and moves
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
        controller.onDrop = { [weak app] width in
            app?.panelDropped(at: width)
        }
        controller.onInspectorDrag = { [weak app] width in
            app?.inspectorDragged(width)
        }
        controller.onInspectorCollapse = { [weak app] collapsed in
            if app?.inspectorShown == collapsed { app?.inspectorShown = !collapsed }
        }
        controller.onToggle = { [weak app] in app?.consolePanelCollapsed.toggle() }
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
    private let dividers = DividerSplitView(seam: false)

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
        splitView = dividers
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
        // Only the user's drag records a height (`DividerSplitView`); the
        // window's layout and resizes leave the stored height alone.
        guard dividers.tracking, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
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
    /// A user's drag of the panel's divider in progress, as the panel's
    /// width now; the model turns the panel's content on it, nothing more.
    var onDrag: (Double) -> Void = { _ in }
    /// The user let go of the panel's divider after moving it, with the
    /// panel this wide: the drop decides where it rests.
    var onDrop: (Double) -> Void = { _ in }
    /// A user's drag of the inspector's divider, as its new width.
    var onInspectorDrag: (Double) -> Void = { _ in }
    /// The inspector collapsed or shown by the split itself (a drag past
    /// its minimum).
    var onInspectorCollapse: (Bool) -> Void = { _ in }
    /// A click on the seam disc: toggle the rail and the panel.
    var onToggle: () -> Void = {}
    /// The width last asked of the split view, so an update that changes
    /// neither the stored width nor the range does not move the divider.
    private var placed: Double?
    /// The width waiting for a layout: the split had no size yet, or too
    /// little room to show it (`placeLater`).
    private var pending: Double?
    /// The inspector's placed width, and the one waiting for a layout.
    private var inspectorKeeper = PaneKeeper()
    private var inspectorPending: Double?
    /// The tab column's minimum, last applied.
    private var contentMinimum: Double = 0
    /// Set while this controller moves a divider itself.
    private var moving = false
    /// Set once the current drag has moved the panel's divider, so its end
    /// reports a drop.
    private var draggingPanel = false
    /// Whether the current drag began with the panel at the rail, which
    /// fixes where the drag turns the panel (`PanelLayout.turnWidth`).
    private var dragFromRail = false
    /// The panel's state last applied, for a drop that changes none of it.
    private var applied: (range: ClosedRange<Double>, width: Double, collapsed: Bool)?
    private let dividers = DividerSplitView(seam: true)

    init(panel: NSViewController, content: NSViewController, inspector: NSViewController) {
        panelItem = NSSplitViewItem(viewController: panel)
        // The panel never leaves the split (no AppKit collapse): its
        // thickness alone moves between the rail and its usual range
        // (`apply`), so `canCollapse` stays false and `isCollapsed` unused.
        // The rail is the floor of every drag; the model decides at the
        // drop whether the panel rests there (`onDrop`).
        panelItem.canCollapse = false
        panelItem.minimumThickness = PanelLayout.railWidth
        panelItem.holdingPriority = NSLayoutConstraint.Priority(260)
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.holdingPriority = .defaultLow
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = InspectorWidth.minimum
        inspectorItem.maximumThickness = InspectorWidth.ceiling
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        super.init(nibName: nil, bundle: nil)
        splitView = dividers
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(panelItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        dividers.seam?.onToggle = { [weak self] in self?.onToggle() }
        dividers.onTrackingBegan = { [weak self] in
            guard let self else { return }
            dragFromRail = applied?.collapsed ?? false
        }
        dividers.onTrackingEnded = { [weak self] in self?.dropped() }
    }

    /// The divider's position while the user drags it, on the divider or
    /// through the seam disc: the panel's divider rests only at the rail or
    /// from the panel's minimum up, turning where the drag's start says
    /// (`PanelLayout.dragWidth`). The inspector's divider goes no further
    /// left than the panel's held width (`PanelLayout.heldWidth`: the rail
    /// while pinned there, else the panel's minimum) and the column's
    /// minimum allow, so a squeeze from the right stops where the column
    /// is at its minimum and never pins the panel at the rail, whose floor
    /// the item's own minimum thickness no longer holds. Any position the
    /// controller sets itself passes through unchanged. (An override in
    /// Swift's eyes, of the delegate protocol's optional requirement; the
    /// controller itself does not implement it, so there is no super.)
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividers.tracking else { return proposedPosition }
        switch dividerIndex {
        case 0:
            return CGFloat(PanelLayout.dragWidth(Double(proposedPosition), fromRail: dragFromRail))
        case 1:
            let held = PanelLayout.heldWidth(collapsed: applied?.collapsed ?? false)
            return max(proposedPosition, CGFloat(held + Double(splitView.dividerThickness) + contentMinimum))
        default:
            return proposedPosition
        }
    }

    /// The user let go: a drag that moved the panel's divider reports the
    /// panel's width as its drop. A drop that leaves the model as it was
    /// (the rail already shown, or the column at the width already stored)
    /// brings no update from the view, whose inputs are what they were; the
    /// panel is then placed again from the state last applied. Any other
    /// drop changes the model, and its update places the panel.
    private func dropped() {
        guard draggingPanel else { return }
        draggingPanel = false
        let width = Double(panelItem.viewController.view.frame.width)
        onDrop(width)
        guard let applied else { return }
        let unchanged: Bool
        if let rests = PanelLayout.droppedWidth(width) {
            unchanged = !applied.collapsed && rests == PanelLayout.clamp(applied.width, to: applied.range)
        } else {
            unchanged = applied.collapsed
        }
        guard unchanged else { return }
        placed = nil
        apply(range: applied.range, width: applied.width, collapsed: applied.collapsed, contentMinimum: contentMinimum)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the split to the model: the panel at the rail width while
    /// collapsed, else at the stored width within `range`, the divider free
    /// from the rail to the range's top either way, so a drag out from the
    /// rail runs; the content's minimum; the seam disc's wing turned by the
    /// state. While the user drags, the flag turns live with the divider
    /// and nothing is placed: the divider stays where the drag's constraint
    /// put it, and the drop places it (`dropped`).
    func apply(range: ClosedRange<Double>, width: Double, collapsed: Bool, contentMinimum: Double) {
        self.contentMinimum = contentMinimum
        contentItem.minimumThickness = contentMinimum
        dividers.seam?.collapsed = collapsed
        applied = (range, width, collapsed)
        panelItem.maximumThickness = range.upperBound
        guard !dividers.tracking else { return }
        let target = collapsed ? PanelLayout.railWidth : PanelLayout.clamp(width, to: range)
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
        moving = true
        splitView.setPosition(width, ofDividerAt: 0)
        moving = false
        pending = Self.placeLater(width, shown: panelItem.viewController.view.frame.width)
    }

    /// Moves the inspector's divider so the inspector is `width` wide, or
    /// as near as the tab column's minimum allows.
    private func placeInspector(_ width: Double) {
        let total = Double(splitView.bounds.width)
        guard total > 0 else {
            inspectorPending = width
            return
        }
        let divider = Double(splitView.dividerThickness)
        let panel = Double(panelItem.viewController.view.frame.width) + divider
        let shown = InspectorWidth.clamp(width, to: InspectorWidth.range(shared: total - panel, columnMinimum: contentMinimum))
        moving = true
        splitView.setPosition(CGFloat(total - shown - divider), ofDividerAt: 1)
        moving = false
        inspectorPending = Self.placeLater(width, shown: inspectorItem.viewController.view.frame.width)
    }

    /// The width to place again at the next layout, or nil when the pane
    /// shows `width`. The window lays out first at its minimum size, where
    /// a stored width may not fit; the pane takes it once the window has
    /// grown, rather than leaving the growth to the tab column.
    private static func placeLater(_ width: Double, shown: CGFloat) -> Double? {
        Double(shown) < width - 1 ? width : nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.bounds.width > 0 else { return }
        if let pending { place(pending) }
        if let inspectorPending { placeInspector(inspectorPending) }
    }

    override func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                            forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        false
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !moving else { return }
        let inspectorCollapsed = inspectorItem.isCollapsed
        onInspectorCollapse(inspectorCollapsed)
        // Only the user's drag records a width (`DividerSplitView`); the
        // window's layout and resizes leave the stored widths alone.
        guard dividers.tracking,
              let index = notification.userInfo?["NSSplitViewDividerIndex"] as? Int else { return }
        if index == 0 {
            // The panel's drag turns its content live and is recorded at
            // its drop (`dropped`).
            let width = Double(panelItem.viewController.view.frame.width)
            placed = width
            pending = nil
            draggingPanel = true
            onDrag(width)
        } else if index == 1, !inspectorCollapsed {
            let width = Double(inspectorItem.viewController.view.frame.width)
            inspectorPending = nil
            inspectorKeeper.dragged(to: InspectorWidth.dragged(width))
            onInspectorDrag(width)
        }
    }
}

/// DividerSplitView is a split view that knows when the user is dragging a
/// divider. AppKit posts its did-resize notification, with the divider
/// index in it, for every resize: the window's first layout (the panes at
/// their minimums, before a size is placed), a window resize and a
/// `setPosition` call, as well as a drag. A drag runs inside the split
/// view's own `mouseDown` (AppKit tracks the mouse there until the button
/// is released), so `tracking` is set only for that span, and for a drag
/// through the seam disc, which moves the first divider by `setPosition`
/// at the position the delegate's constraint allows, as the divider's own
/// drag is constrained. Either span's start calls `onTrackingBegan` and its
/// end `onTrackingEnded`, the drop.
///
/// The console's split carries the seam disc (`SeamDiscView`) on its first
/// divider, the panel's: placed at the divider's vertical middle at every
/// layout, shown only while the pointer is within `PanelLayout.seamReach`
/// of the divider's hairline or on the disc itself (`hover`), when the
/// hairline also lights in the meters' periwinkle (`Palette.fill`). Nothing
/// is drawn otherwise. The log split has no seam.
@MainActor
final class DividerSplitView: NSSplitView {
    /// Whether the split is tracking the user's mouse on a divider.
    private(set) var tracking = false {
        didSet {
            if !oldValue && tracking { onTrackingBegan() }
            if oldValue && !tracking { onTrackingEnded() }
        }
    }
    /// The user took hold of a divider, on the divider itself or through
    /// the seam disc, before it has moved.
    var onTrackingBegan: () -> Void = {}
    /// The user let go of a divider: a drag ended, whether on the divider
    /// itself or through the seam disc.
    var onTrackingEnded: () -> Void = {}
    /// The seam disc on the first divider; nil on a split without one.
    let seam: SeamDiscView?
    /// Whether the pointer is on the first divider or its disc.
    private(set) var seamHovered = false
    /// The first divider's position when a drag through the disc began.
    private var dragStart: CGFloat = 0

    init(seam: Bool) {
        self.seam = seam ? SeamDiscView() : nil
        super.init(frame: .zero)
        guard let seam = self.seam else { return }
        // The disc is a subview the split does not arrange.
        arrangesAllSubviews = false
        addSubview(seam)
        seam.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStart = arrangedSubviews[0].frame.maxX
            tracking = true
        }
        seam.onDragMoved = { [weak self] dx in
            guard let self else { return }
            let proposed = dragStart + dx
            setPosition(delegate?.splitView?(self, constrainSplitPosition: proposed, ofSubviewAt: 0) ?? proposed,
                        ofDividerAt: 0)
        }
        seam.onDragEnded = { [weak self] in self?.tracking = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        defer { tracking = false }
        super.mouseDown(with: event)
    }

    /// The first divider's rect, nil before the split has two panes.
    private var seamDivider: NSRect? {
        guard arrangedSubviews.count > 1 else { return nil }
        return NSRect(x: arrangedSubviews[0].frame.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
    }

    /// The divider's hairline widened by `PanelLayout.seamReach` each side.
    private var seamStrip: NSRect? {
        seamDivider?.insetBy(dx: -CGFloat(PanelLayout.seamReach), dy: 0)
    }

    /// Whether `point` (in the split's coordinates) counts as on the seam:
    /// within the widened hairline, or on the disc.
    func onSeam(_ point: NSPoint) -> Bool {
        guard let seam, let strip = seamStrip else { return false }
        return strip.contains(point) || seam.frame.contains(point)
    }

    /// The one rect the tracking area watches: the strip and the disc.
    private var seamZone: NSRect {
        guard let seam, let strip = seamStrip else { return .zero }
        return strip.union(seam.frame)
    }

    override func layout() {
        super.layout()
        guard let seam, let divider = seamDivider else { return }
        let size = CGFloat(PanelLayout.seamDisc)
        seam.frame = NSRect(x: divider.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        // The controller adds the panes after the disc; keep the disc above
        // them, or they draw over it and only the divider's gap shows it.
        if subviews.last !== seam {
            addSubview(seam, positioned: .above, relativeTo: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["seam"] != nil { removeTrackingArea(area) }
        guard seam != nil, seamDivider != nil else { return }
        addTrackingArea(NSTrackingArea(rect: seamZone, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                       owner: self, userInfo: ["seam": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["seam"] != nil else { return super.mouseEntered(with: event) }
        hover(onSeam(convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard seam != nil else { return }
        hover(onSeam(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["seam"] != nil else { return super.mouseExited(with: event) }
        hover(false)
    }

    /// The pointer came onto the seam (`inside`) or left it: the disc fades
    /// in or out and the hairline lights or goes back to its colour.
    func hover(_ inside: Bool) {
        guard let seam, inside != seamHovered else { return }
        seamHovered = inside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            seam.animator().alphaValue = inside ? 1 : 0
        }
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let seam, seamHovered, seam.frame.contains(convert(point, from: superview)) { return seam }
        return super.hitTest(point)
    }

    override func drawDivider(in rect: NSRect) {
        if seamHovered, let divider = seamDivider, abs(rect.midX - divider.midX) < 1 {
            NSColor(Palette.fill).setFill()
            rect.fill()
        } else {
            super.drawDivider(in: rect)
        }
    }
}
