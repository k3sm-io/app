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
/// The menu carries the verdict and summary, the status rows, Stop (with the
/// multi-node warning) and Restart, Open Status, Open Logs, Write a Bug
/// Report, Open k3sm and Quit. Stop and Restart go through `AppModel.perform`
/// and are enabled only when the installed CLI has them; otherwise a note
/// item opens the window, which says why.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let autosaveName = "io.k3sm.app.status"

    private var tracker = VisibilityTracker()
    private var item: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var removedByUser = false
    private var removingItem = false
    private let menu = NSMenu()
    private let headerItem = NSMenuItem(title: "k3sm", action: nil, keyEquivalent: "")
    private var rowItems: [NSMenuItem] = []
    private let rowsEnd = NSMenuItem.separator()
    private var stopItem = NSMenuItem()
    private var restartItem = NSMenuItem()
    private var noteItem = NSMenuItem()
    private let model: AppModel
    private let openWindow: @MainActor () -> Void
    private var supportObservation: AnyCancellable?
    /// The last report the poller or a menu open read.
    private var report: StatusReport?

    /// Whether the rule currently wants the item shown.
    var wantsVisible: Bool { tracker.visible }

    init(model: AppModel, openWindow: @escaping @MainActor () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(rowsEnd)
        stopItem = add(LifecycleVerb.stop.title + "…", #selector(stopAction))
        restartItem = add(LifecycleVerb.restart.title + "…", #selector(restartAction))
        noteItem = add("Stop and Restart are not available: open k3sm for why", #selector(openWindowAction))
        menu.addItem(.separator())
        _ = add("Open Status in Terminal", #selector(openStatusAction))
        _ = add("Open Logs", #selector(openLogsAction))
        _ = add("Write a Bug Report…", #selector(bugReportAction))
        menu.addItem(.separator())
        _ = add("Open k3sm", #selector(openWindowAction), key: "o")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit k3sm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        supportObservation = model.$lifecycleSupport.sink { [weak self] support in
            MainActor.assumeIsolated { self?.updateLifecycleItems(support) }
        }
        updateLifecycleItems(nil)
    }

    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    /// Feeds one poll result through the visibility rule.
    func observe(_ reading: Reading, report: StatusReport?) {
        let change = tracker.observe(reading)
        if change.logUnavailable {
            log.notice("k3sm status unavailable")
        }
        if let report {
            show(report)
            item?.button?.image = Self.icon(degraded: report.verdict == .degraded)
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

    /// Shows the verdict and summary, and the status rows, of a report.
    private func show(_ report: StatusReport) {
        self.report = report
        let summary = report.summary.isEmpty ? report.verdict.word : "\(report.verdict.word) · \(report.summary)"
        headerItem.title = StatusDisplay.clip("k3sm " + summary)
        for row in rowItems {
            menu.removeItem(row)
        }
        rowItems = StatusDisplay.rows(of: report).map { row in
            let item = NSMenuItem(title: StatusDisplay.clip("\(row.name): \(row.state) · \(row.detail)"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            return item
        }
        let at = menu.index(of: rowsEnd)
        for (offset, row) in rowItems.enumerated() {
            menu.insertItem(row, at: at + offset)
        }
    }

    private func updateLifecycleItems(_ support: LifecycleSupport?) {
        let available = support == .available && !model.running
        stopItem.isEnabled = available
        restartItem.isEnabled = available
        if case .unavailable = support {
            noteItem.isHidden = false
        } else {
            noteItem.isHidden = true
        }
    }

    // MARK: NSMenuDelegate

    /// On open: re-check lifecycle support and read the full report, so the
    /// rows are the whole status, not only the launchd probe.
    func menuWillOpen(_ menu: NSMenu) {
        updateLifecycleItems(model.lifecycleSupport)
        Task {
            await model.refreshLifecycleSupport()
            if let full = await model.readFullReport() {
                show(full)
            }
        }
    }

    // MARK: actions

    /// The state the menu showed: the user acts on that, and the driver
    /// refuses if the live state no longer matches.
    private var shownState: LifecycleState { LifecycleState(report: report) }

    @objc private func stopAction() {
        model.perform(.stop, expected: shownState)
    }

    @objc private func restartAction() {
        model.perform(.restart, expected: shownState)
    }

    @objc private func openStatusAction() {
        MenuActions.openStatus()
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

    // MARK: visibility

    private func insert() {
        guard item == nil, !removedByUser else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = .removalAllowed
        // A removal the user made in an earlier session lasts until the next
        // launch only, so the first insertion of a session shows the item.
        item.isVisible = true
        item.button?.image = Self.icon(degraded: false)
        item.menu = menu
        self.item = item
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

    private static func icon(degraded: Bool) -> NSImage? {
        let name = degraded ? "exclamationmark.triangle" : "shippingbox"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: degraded ? "k3sm degraded" : "k3sm")
        image?.isTemplate = true
        return image
    }
}
