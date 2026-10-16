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
import K3smInstall
import K3smStatus

/// StatusItemController owns the NSStatusItem and applies the visibility rule:
/// the item exists only while this Mac's node daemon runs. It logs
/// `status item: visible` only once the item's button window is on screen,
/// and respects a user who removes the item (Command-drag or Menu Bar
/// settings) until the next launch.
///
/// The menu opens with two status lines, Cluster and This Mac, each with a
/// coloured circle and the word, then the actions: Update to <tag>… while
/// the `update` row offers one (`UpdateOffer`; "Updating…", disabled, while a
/// roll runs; shown disabled with the reason on a developer build), Stop
/// (with the multi-node warning) and Restart, Live Status (and Live Top when the CLI has it), Open Logs, Write a Bug Report, Settings, Dashboard and Quit.
/// Stop and Restart go through `AppModel.perform` and are shown only when
/// the installed CLI has them; otherwise they are hidden and the window says
/// why. The full status and the LAN setting are in the window. While LAN access
/// is on, the status item's icon carries a small dot. While the menu is open
/// and its full status read runs past `Waiting.debounce`, the icon's wings
/// beat (`Waiting.menuFrame`), badges and all, on a timer that also fires
/// while the menu tracks.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "io.k3sm.app.status"

    private var tracker = VisibilityTracker()
    private var item: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var removedByUser = false
    private var removingItem = false
    private let menu = NSMenu()
    private let clusterItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let thisMacItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var updateItem = NSMenuItem()
    /// The separator after the update item, shown only when Stop and
    /// Restart are hidden, so the update item never runs into Live Status.
    private let updateEnd = NSMenuItem.separator()
    private var stopItem = NSMenuItem()
    private var restartItem = NSMenuItem()
    /// Live Top, shown only while the installed CLI offers the view.
    private var liveTopItem = NSMenuItem()
    /// The separator after Stop and Restart, hidden with them so the menu
    /// never starts with a rule.
    private let lifecycleEnd = NSMenuItem.separator()
    /// Keeps the icon's LAN dot current when the model changes.
    private var iconObservation: AnyCancellable?
    private var degraded = false
    private let model: AppModel
    private let openWindow: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private var supportObservation: AnyCancellable?
    /// The last report the poller read.
    private var report: StatusReport?
    /// The waiting animation's state: whether the menu is open, when its full
    /// read began (nil once it ended), when the frames began (nil while
    /// still), the frame timer, and the wing angle the icon shows.
    private var menuOpen = false
    private var menuReadBegan: TimeInterval?
    private var framesBegan: TimeInterval?
    private var frameTimer: Timer?
    private var wingAngle = 0.0

    /// Whether the rule currently wants the item shown.
    var wantsVisible: Bool { tracker.visible }

    init(model: AppModel, openWindow: @escaping @MainActor () -> Void, openSettings: @escaping @MainActor () -> Void) {
        self.model = model
        self.openWindow = openWindow
        self.openSettings = openSettings
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for line in [clusterItem, thisMacItem] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        showStatusLine(clusterItem, MenuStatus.clusterLabel, .unknown)
        showStatusLine(thisMacItem, MenuStatus.thisMacLabel, .unknown)
        updateItem = add("", #selector(updateAction))
        menu.addItem(updateEnd)
        stopItem = add(LifecycleVerb.stop.title + "…", #selector(stopAction), help: Help.Menus.stop)
        restartItem = add(LifecycleVerb.restart.title + "…", #selector(restartAction), help: Help.Menus.restart)
        menu.addItem(lifecycleEnd)
        _ = add(LiveView.status.menuTitle, #selector(openStatusAction), help: Help.Menus.liveStatus)
        liveTopItem = add(LiveView.top.menuTitle, #selector(openTopAction), help: Help.Menus.liveTop)
        liveTopItem.isHidden = true
        _ = add("Open Logs", #selector(openLogsAction), help: Help.Menus.openLogs)
        _ = add("Write a Bug Report…", #selector(bugReportAction), help: Help.Menus.bugReport)
        menu.addItem(.separator())
        _ = add("Settings…", #selector(openSettingsAction), key: ",", help: Help.Menus.settings)
        _ = add(MenuStatus.windowItemTitle, #selector(openWindowAction), key: "o", help: Help.Menus.dashboard)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit k3sm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        supportObservation = model.$lifecycleSupport.sink { [weak self] support in
            MainActor.assumeIsolated { self?.updateLifecycleItems(support) }
        }
        updateLifecycleItems(nil)
        updateUpdateItem()
        iconObservation = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value changes: read it after.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateIcon()
                    self?.updateUpdateItem()
                }
            }
        }
    }

    /// Shows one status line: the label and word as the title, a circle in
    /// the health's colour as the image, and both in the accessibility text.
    private func showStatusLine(_ line: NSMenuItem, _ label: String, _ health: MenuHealth) {
        line.title = MenuStatus.title(label, health)
        line.image = Self.dot(health, description: MenuStatus.accessibilityText(label, health))
        line.setAccessibilityLabel(MenuStatus.accessibilityText(label, health))
    }

    /// A 10-point filled circle, not a template, so it keeps its colour.
    private static func dot(_ health: MenuHealth, description: String) -> NSImage {
        let color: NSColor
        switch health {
        case .ok: color = NSColor(Palette.ok)
        case .degraded: color = NSColor(Palette.warn)
        case .down: color = NSColor(Palette.down)
        case .unknown: color = NSColor(Palette.unknown)
        }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }

    /// Shows the degraded mark and the LAN dot on the icon.
    private func updateIcon() {
        item?.button?.image = Self.icon(degraded: degraded, lan: model.lanToggle().showsIndicator, wingAngle: wingAngle)
    }

    /// Adds an item with its catalog help tag as its tooltip; the update
    /// item's tag is set as the offer changes.
    private func add(_ title: String, _ action: Selector, key: String = "", help: HelpTag? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.toolTip = help?.text
        menu.addItem(item)
        return item
    }

    /// Feeds one poll result through the visibility rule.
    func observe(_ reading: Reading, report: StatusReport?) {
        model.noteProbe(report)
        let change = tracker.observe(reading)
        // The probe carries the verdict but not the node row, so it updates
        // This Mac only; Cluster waits for the full read on the next open.
        showStatusLine(thisMacItem, MenuStatus.thisMacLabel, MenuStatus.thisMac(of: report, readFailed: report == nil))
        if change.logUnavailable {
            log.notice("k3sm status unavailable")
        }
        if let report {
            self.report = report
            degraded = report.verdict == .degraded
            updateIcon()
        }
        if change.visibilityChanged {
            if tracker.visible {
                insert()
                Task { await model.refreshLifecycleSupport() }
            } else {
                remove()
            }
        }
    }

    /// Shows Stop and Restart only when the installed CLI supports them,
    /// enabled unless a step is running; otherwise hides them and their
    /// separator, never showing them disabled.
    private func updateLifecycleItems(_ support: LifecycleSupport?) {
        let shown = support == .available
        for item in [stopItem, restartItem, lifecycleEnd] {
            item.isHidden = !shown
        }
        stopItem.isEnabled = shown && !model.running
        restartItem.isEnabled = shown && !model.running
        updateUpdateItem()
    }

    /// Shows the update item as `UpdateOffer` decides: hidden, offered with
    /// its tag, disabled with the reason as its tooltip, or "Updating…";
    /// an offered update's tooltip says what it does (`Help.Strip.update`).
    private func updateUpdateItem() {
        let offer = model.updateOffer
        let title = offer.menuTitle
        updateItem.isHidden = title == nil
        updateItem.title = title ?? ""
        updateItem.isEnabled = offer.isEnabled
        updateItem.toolTip = title == nil ? nil : Help.Strip.update(offer)
        updateEnd.isHidden = title == nil || !stopItem.isHidden
    }

    // MARK: NSMenuDelegate

    /// On open: re-check lifecycle support, and read the full report once
    /// for the two status lines (the probe has no node row). Between opens
    /// they show the last read.
    func menuWillOpen(_ menu: NSMenu) {
        updateLifecycleItems(model.lifecycleSupport)
        menuOpen = true
        menuReadBegan = ProcessInfo.processInfo.systemUptime
        startFrames()
        Task { liveTopItem.isHidden = !(await MenuActions.liveTopOffered()) }
        Task {
            await model.refreshLifecycleSupport()
            let full = await model.readFullReport()
            menuReadBegan = nil
            stepFrames()
            showStatusLine(clusterItem, MenuStatus.clusterLabel, MenuStatus.cluster(of: full))
            showStatusLine(thisMacItem, MenuStatus.thisMacLabel, MenuStatus.thisMac(of: full, readFailed: full == nil))
            await model.refreshUpdateStatus()
            updateUpdateItem()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        stepFrames()
    }

    // MARK: waiting animation

    /// Starts the frame timer in the common modes, so it fires while the
    /// menu tracks. A second start is a no-op.
    private func startFrames() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: Waiting.menuFrameInterval / 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Shows the frame `Waiting` decides now, or the still icon and no timer
    /// once the read has ended (and the minimum shown time passed) or the
    /// menu closed.
    private func stepFrames() {
        let now = ProcessInfo.processInfo.systemUptime
        let animates = Waiting.menuAnimates(
            menuOpen: menuOpen, readInFlight: menuReadBegan != nil,
            elapsed: menuReadBegan.map { now - $0 } ?? 0, shownFor: framesBegan.map { now - $0 })
        var angle = 0.0
        if animates {
            let began = framesBegan ?? now
            framesBegan = began
            angle = Waiting.menuFrame(at: now - began, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            framesBegan = nil
            if !menuOpen || menuReadBegan == nil {
                frameTimer?.invalidate()
                frameTimer = nil
            }
        }
        if angle != wingAngle {
            wingAngle = angle
            updateIcon()
        }
    }

    // MARK: actions

    /// The state the menu showed: the user acts on that, and the driver
    /// refuses if the live state no longer matches.
    private var shownState: LifecycleState { LifecycleState(report: report) }

    @objc private func updateAction() {
        model.performUpdate()
    }

    @objc private func stopAction() {
        model.perform(.stop, expected: shownState)
    }

    @objc private func restartAction() {
        model.perform(.restart, expected: shownState)
    }

    @objc private func openStatusAction() {
        MenuActions.openLive(.status)
    }

    @objc private func openTopAction() {
        MenuActions.openLive(.top)
    }

    @objc private func openLogsAction() {
        MenuActions.openLogs(role: report.flatMap(NodeRole.detect(in:)))
    }

    @objc private func bugReportAction() {
        MenuActions.writeBugReport()
    }

    @objc private func openWindowAction() {
        openWindow()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    // MARK: visibility

    private func insert() {
        guard item == nil, !removedByUser else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed
        // A removal the user made in an earlier session lasts until the next
        // launch only, so the first insertion of a session shows the item.
        item.isVisible = true
        item.menu = menu
        self.item = item
        updateIcon()
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            let visible = item.isVisible
            MainActor.assumeIsolated { self?.userChangedVisibility(visible) }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.logPresence() }
        }
    }

    private func remove() {
        guard let item else { return }
        removingItem = true
        visibilityObservation = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        removingItem = false
        log.notice("status item: hidden")
    }

    private func userChangedVisibility(_ visible: Bool) {
        guard !removingItem, !visible, item != nil else { return }
        removedByUser = true
        log.notice("status item: removed by the user")
        remove()
    }

    private func logPresence() {
        guard let item, item.isVisible, item.button?.window?.isVisible == true else {
            log.notice("status item: not on screen")
            return
        }
        log.notice("status item: visible")
    }

    /// The status item's icon: the butterfly mark, with a triangle at its
    /// top right when degraded and a dot at its lower right with `lan`
    /// (other devices can connect to this Mac's workloads).
    private static func icon(degraded: Bool, lan: Bool, wingAngle: Double) -> NSImage? {
        let label = (degraded ? "k3sm degraded" : "k3sm") + (lan ? ", connections from other devices allowed" : "")
        return ButterflyImage.statusIcon(degraded: degraded, lan: lan, label: label, wingAngle: wingAngle)
    }
}
