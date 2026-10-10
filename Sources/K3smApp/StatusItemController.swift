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

/// StatusItemController owns the NSStatusItem and applies the visibility rule:
/// the item exists only while this Mac's node daemon runs. It logs
/// `status item: visible` only once the item's button window is on screen,
/// and respects a user who removes the item (Command-drag or Menu Bar
/// settings) until the next launch.
@MainActor
final class StatusItemController: NSObject {
    private static let autosaveName = "io.k3sm.app.status"

    private var tracker = VisibilityTracker()
    private var item: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var removedByUser = false
    private var removingItem = false
    private let menu = NSMenu()
    private let headerItem = NSMenuItem(title: "k3sm", action: nil, keyEquivalent: "")
    private let openWindow: @MainActor () -> Void

    /// Whether the rule currently wants the item shown.
    var wantsVisible: Bool { tracker.visible }

    init(openWindow: @escaping @MainActor () -> Void) {
        self.openWindow = openWindow
        super.init()
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open k3sm", action: #selector(openWindowAction), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit k3sm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Feeds one poll result through the visibility rule.
    func observe(_ reading: Reading, report: StatusReport?) {
        let change = tracker.observe(reading)
        if change.logUnavailable {
            log.notice("k3sm status unavailable")
        }
        if let report {
            let summary = report.summary.isEmpty ? report.verdict.word : "\(report.verdict.word) · \(report.summary)"
            headerItem.title = StatusDisplay.clip("k3sm " + summary)
            item?.button?.image = Self.icon(degraded: report.verdict == .degraded)
        }
        if change.visibilityChanged {
            if tracker.visible {
                insert()
            } else {
                remove()
            }
        }
    }

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

    @objc private func openWindowAction() {
        openWindow()
    }

    private static func icon(degraded: Bool) -> NSImage? {
        let name = degraded ? "exclamationmark.triangle" : "shippingbox"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: degraded ? "k3sm degraded" : "k3sm")
        image?.isTemplate = true
        return image
    }
}
