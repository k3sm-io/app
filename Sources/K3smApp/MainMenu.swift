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

/// MainMenu is the menu bar while the window is open: the app menu with
/// Settings (the status panel), Edit for the search field, View for refresh
/// and for hiding or showing the console's left panel, and Window. The status item keeps its own menu. The delegate owns one and
/// the items target it.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    private let model: AppModel
    private let show: () -> Void

    init(model: AppModel, show: @escaping () -> Void) {
        self.model = model
        self.show = show
    }

    func install() {
        let main = NSMenu()
        main.addItem(submenu: appMenu())
        main.addItem(submenu: editMenu())
        main.addItem(submenu: viewMenu())
        let window = windowMenu()
        main.addItem(submenu: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "k3sm")
        menu.addItem(withTitle: "About k3sm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings(_:)), ","))
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
        menu.addItem(item("Refresh", #selector(refresh(_:)), "r"))
        menu.addItem(.separator())
        let panel = item("Hide Panel", #selector(togglePanel(_:)), "l")
        panel.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(panel)
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    /// An item that targets this object.
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings(_ sender: Any?) {
        show()
        model.statusPanelShown = true
    }

    /// Collapses or expands the console's left panel; the split view follows
    /// the model, and the state is kept across launches.
    @objc private func togglePanel(_ sender: Any?) {
        model.consolePanelCollapsed.toggle()
    }

    /// The panel item reads Hide Panel or Show Panel, and is offered only
    /// while the console is on screen.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
