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
import SwiftUI

/// MainWindowController owns the console window. While it (or Settings) is
/// open the app is a regular app (Dock icon, app menu, Command-Tab); when
/// both are closed the app returns to an accessory with only the status
/// item (`AppActivation`). The window's frame and its screen are saved on
/// every move, resize and close, and the next open (in this launch or a
/// later one) puts it back through `WindowFrame.restore`.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var dockFlap: AnyCancellable?
    /// The Delete key monitor, for the selected row's delete action.
    private var deleteKeys: Any?

    init(model: AppModel) {
        self.model = model
    }

    /// The console window, nil until it is first shown.
    var consoleWindow: NSWindow? { window }

    /// Shows the window, creating it on first use, and refreshes the model.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        AppActivation.opened(.console)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // While the console is on screen, the Dock icon is drawn here: its
        // own tile, still, with the mark flapping on it at the wordmark's
        // angle. While nothing is installed (`Screen.firstRun`, the set-up flow
        // in the content pane) the Dock keeps the bundle icon. A
        // frame that fails to render leaves the last good one in place.
        // With the Dock animation turned off in Settings the mark stays flat.
        let dockAngle = model.flap.$angle.combineLatest(PreferencesStore.shared.$dockAnimation).map { $1 ? $0 : 0 }
        dockFlap = model.$screen.combineLatest(dockAngle.removeDuplicates()).sink { screen, angle in
            MainActor.assumeIsolated {
                let consoleShown = screen == .status
                let image = consoleShown ? DockIcon.image(angle: angle) : nil
                switch DockFrame.decide(consoleShown: consoleShown, rendered: image != nil) {
                case .bundleIcon: NSApp.applicationIconImage = nil
                case .newFrame: NSApp.applicationIconImage = image
                case .keepLast: break
                }
            }
        }
        if model.screen == .status {
            model.startTabs()
            model.startReportPolling()
            model.flap.start()
        }
        model.setWindowVisible(true)
        Task { await model.refresh() }
    }

    /// The console polls (its tabs' lists and the full report) only while the
    /// window is on screen: stop both here, not only from the view's
    /// onDisappear, which an ordered-out window may never deliver.
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        // The Dock subscription goes first, so stopping the flap does not
        // render one last frame that is thrown away a line later.
        dockFlap = nil
        // A tour still running ends with the window, so the layout it changed
        // is put back and its key monitor goes.
        model.tour.end()
        model.stopTabs()
        model.stopReportPolling()
        model.setWindowVisible(false)
        model.flap.stop()
        NSApp.applicationIconImage = nil
        AppActivation.closed(.console)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    /// Records the window's frame and its screen in the user defaults. A
    /// window on no screen (fully off every display) records nothing.
    private func saveFrame() {
        guard let window, let screen = window.screen else { return }
        let f = window.frame
        let saved = WindowFrame.Saved(
            frame: WindowFrame.Rect(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height),
            screen: screen.k3smIdentity)
        UserDefaults.standard.set(saved.defaultsValue, forKey: WindowFrame.key)
    }

    /// Puts the saved frame back, clamped onto a connected screen and never
    /// below the console's minimum, or centres the window when nothing is
    /// saved.
    private func placeWindow(_ window: NSWindow, saved: WindowFrame.Saved?) {
        guard let frame = WindowFrame.restore(saved: saved, screens: NSScreen.k3smScreens(), minimum: minimum()) else {
            window.center()
            return
        }
        window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    }

    /// The console's minimum size as `ConsoleView` lays it out
    /// (`TabStripLayout`), the same while the set-up flow fills its pane.
    private func minimum() -> WindowFrame.Size {
        let size = ConsoleView.minSize(inspectorShown: model.inspectorShown, panelCollapsed: model.consolePanelCollapsed,
                                       windowButtonsEdge: model.windowButtonsEdge)
        return WindowFrame.Size(width: Double(size.width), height: Double(size.height))
    }

    private func makeWindow() -> NSWindow {
        // Read before the window exists: the hosting controller's first
        // sizing resizes the window, and that resize must not overwrite it.
        let saved = WindowFrame.Saved(defaultsValue: UserDefaults.standard.object(forKey: WindowFrame.key))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "k3sm"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        // The flap asks this when a beat comes due: miniaturized, ordered
        // out or with the app hidden, the window is not visible and the
        // beat is skipped. occlusionState is not used: on macOS 26 it does
        // not report .visible for this window even while it is on screen.
        model.flap.windowVisible = { [weak self] in
            guard let window = self?.window else { return false }
            return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
        }
        window.setConsoleChrome(model.pane.titleBar)
        // Delete or Forward Delete on this window asks for the selected row's
        // delete action behind the console's confirmation, unless text
        // is being edited, a sheet is up or the tour runs (`DeleteKey`); a
        // row with no such action leaves the key alone.
        deleteKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            let code = event.keyCode
            let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window, event.window === window,
                      DeleteKey.matches(code: code, commandOptionOrControl: modified,
                                        editingText: window.firstResponder is NSText,
                                        sheetShown: window.attachedSheet != nil,
                                        tourShown: self.model.tour.step != nil) else { return false }
                return self.model.deleteKey()
            }
            return consumed ? nil : event
        }
        // The frame is placed after the content and its chrome, so neither
        // resizes it afterwards; the delegate is set last, so only the
        // user's moves and resizes from here on are saved.
        placeWindow(window, saved: saved)
        // The window buttons sit where the transparent title bar put them;
        // the strip clears them while the panel is hidden.
        window.layoutIfNeeded()
        model.windowButtonsEdge = window.standardButtonsEdge()
        window.delegate = self
        return window
    }
}

extension NSScreen {
    /// The connected screens as `WindowFrame.restore` takes them, the main
    /// screen first, each with its identity and visible frame.
    @MainActor
    static func k3smScreens() -> [WindowFrame.Screen] {
        let main = NSScreen.main ?? NSScreen.screens.first
        let ordered = (main.map { [$0] } ?? []) + NSScreen.screens.filter { $0 !== main }
        return ordered.map { screen in
            let v = screen.visibleFrame
            return WindowFrame.Screen(id: screen.k3smIdentity,
                                      visible: WindowFrame.Rect(x: v.origin.x, y: v.origin.y, width: v.width, height: v.height))
        }
    }

    /// A stable identity for the display: its CoreGraphics UUID, which
    /// survives a reconnect and a relaunch, or the display number when the
    /// UUID is unavailable.
    @MainActor
    var k3smIdentity: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { return "unknown" }
        let id = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            return text
        }
        return "display-\(id)"
    }
}

extension NSWindow {
    /// The console draws its own top edge: the title bar is transparent and
    /// the content runs under it, so the traffic lights sit on the panel. It
    /// is set once, when the window is made: the set-up flow runs inside the
    /// console's content pane (`ConsolePane.titleBar`), so no pane restyles it.
    @MainActor
    /// Where the close, minimize and zoom buttons end, in points from the
    /// window's leading edge, or nil when the window has none laid out.
    func standardButtonsEdge() -> Double? {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let edges = buttons.compactMap { standardWindowButton($0) }
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: nil).maxX }
        guard let edge = edges.max(), edge > 0 else { return nil }
        return Double(edge)
    }

    func setConsoleChrome(_ titleBar: ConsoleTitleBar) {
        switch titleBar {
        case .transparent:
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isMovableByWindowBackground = true
            styleMask.insert(.fullSizeContentView)
        }
    }
}
