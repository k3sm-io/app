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
import SwiftUI

/// MainWindowController owns the one window. While it is open the app is a
/// regular app (Dock icon, app menu, Command-Tab); when it closes the app
/// returns to an accessory with only the status item.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var chrome: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the window, creating it on first use, and refreshes the model.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if model.screen == .status {
            model.workloads.start()
            model.startReportPolling()
        }
        Task { await model.refresh() }
    }

    /// The console polls (its pod list and the full report) only while the
    /// window is on screen: stop both here, not only from the view's
    /// onDisappear, which an ordered-out window may never deliver.
    func windowWillClose(_ notification: Notification) {
        model.workloads.stop()
        model.stopReportPolling()
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "k3sm"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.delegate = self
        window.center()
        chrome = model.$screen.sink { [weak window] screen in window?.setChrome(for: screen) }
        return window
    }
}

extension NSWindow {
    /// The console draws its own top edge: the title bar is transparent and
    /// the content runs under it, so the traffic lights sit on the panel. The
    /// first-run form keeps the standard title bar.
    @MainActor
    func setChrome(for screen: AppModel.Screen) {
        let console = screen == .status
        titlebarAppearsTransparent = console
        titleVisibility = console ? .hidden : .visible
        isMovableByWindowBackground = console
        if console {
            styleMask.insert(.fullSizeContentView)
        } else {
            styleMask.remove(.fullSizeContentView)
        }
    }
}
