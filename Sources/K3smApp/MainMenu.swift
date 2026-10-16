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

/// MainMenu is the menu bar while a window is open: the app menu with
/// Settings (the Settings window), Edit for the search field, View for
/// refresh, the status panel (Show Status), hiding or showing the
/// console's left panel and Reset Column Widths, Window, and Help with the tour. The status item keeps its own menu. The delegate owns one and
/// the items target it.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    private let model: AppModel
    private let show: () -> Void
    private let settings: () -> Void

    init(model: AppModel, show: @escaping () -> Void, settings: @escaping () -> Void) {
        self.model = model
        self.show = show
        self.settings = settings
    }

    func install() {
        let main = NSMenu()
        main.addItem(submenu: appMenu())
        main.addItem(submenu: editMenu())
        main.addItem(submenu: viewMenu())
        let window = windowMenu()
        main.addItem(submenu: window)
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu: help)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "k3sm")
        let about = NSMenuItem(title: "About k3sm", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings(_:)), ",", help: Help.Menus.settings))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide k3sm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit k3sm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Refresh", #selector(refresh(_:)), "r", help: Help.Menus.refresh))
        menu.addItem(item("Show Status", #selector(showStatus(_:)), "", help: Help.Menus.showStatus))
        menu.addItem(.separator())
        let panel = item("Hide Panel", #selector(togglePanel(_:)), "l", help: Help.Menus.panel)
        panel.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(panel)
        menu.addItem(item("Reset Column Widths", #selector(resetColumns(_:)), "", help: Help.Menus.resetColumns))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Take the Tour", #selector(startTour(_:)), "", help: Help.Menus.tour))
        return menu
    }

    /// An item that targets this object, its catalog help tag as its tooltip.
    /// The system's own items (About, Hide, Quit, Edit, Window) carry none.
    private func item(_ title: String, _ action: Selector, _ key: String, help: HelpTag) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.toolTip = help.text
        return item
    }

    /// The standard About panel; a development build shows its
    /// pseudo-version there (`AppVersion.aboutPanel`) in place of 0.0.0.
    @objc private func showAbout(_ sender: Any?) {
        guard let panel = AppVersion(info: Bundle.main.infoDictionary).aboutPanel else {
            NSApp.orderFrontStandardAboutPanel(sender)
            return
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: panel.applicationVersion,
            .version: panel.version,
        ])
    }

    @objc private func startTour(_ sender: Any?) {
        show()
        model.statusPanelShown = false
        model.tour.start()
    }

    @objc private func openSettings(_ sender: Any?) {
        settings()
    }

    /// Opens the status panel (start, stop, connections, uninstall), the
    /// popover under the console's info button.
    @objc private func showStatus(_ sender: Any?) {
        show()
        model.statusPanelShown = true
    }

    /// Collapses or expands the console's left panel; the split view follows
    /// the model, and the state is kept across launches.
    @objc private func togglePanel(_ sender: Any?) {
        model.consolePanelCollapsed.toggle()
    }

    /// Puts every tab's table columns back to their default widths.
    @objc private func resetColumns(_ sender: Any?) {
        model.columns.resetAll()
    }

    /// The panel item reads Hide Panel or Show Panel, and is offered only
    /// while the console is on screen.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // The tour walks the console, so it is offered only while it is up.
        if menuItem.action == #selector(startTour(_:)) { return model.screen == .status }
        guard menuItem.action == #selector(togglePanel(_:)) else { return true }
        menuItem.title = model.consolePanelCollapsed ? "Show Panel" : "Hide Panel"
        return model.screen == .status
    }

    @objc private func refresh(_ sender: Any?) {
        Task {
            await model.refresh()
            await model.refreshTabs()
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
