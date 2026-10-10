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

/// AppDelegate wires the parts together: the poller feeds the status item,
/// the status item and a reopen open the window, the login item is
/// registered once, and an activity assertion keeps App Nap from stretching
/// the poll timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windowController: MainWindowController?
    private var statusItem: StatusItemController?
    private var poller: StatusPoller?
    private var activity: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = Self.launchedAsLoginItem()
        let environment = SelfCheck.cliEnvironment()
        let model = AppModel(runner: AppleScriptPrivilegedRunner(), environment: environment)
        let windowController = MainWindowController(model: model)
        let statusItem = StatusItemController { [weak windowController] in windowController?.show() }
        let poller = StatusPoller(environment: environment) { [weak statusItem, weak self] reading, report in
            statusItem?.observe(reading, report: report)
            self?.poller?.itemVisible = statusItem?.wantsVisible ?? false
        }
        self.model = model
        self.windowController = windowController
        self.statusItem = statusItem
        self.poller = poller

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Polls k3sm status for the menu bar item"
        )
        model.loginItemNeedsApproval = LoginItem.registerOnFirstLaunch() == .requiresApproval
        observeSession()
        poller.start()
        log.notice("k3sm app started")
        // A login-item launch shows only the status item; any launch the user
        // made (Finder, Spotlight, the Dock) shows the window.
        if !loginLaunch {
            windowController.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Pauses polling while this user's session is not the active console
    /// session (fast user switching), and resumes when it returns.
    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        sessionObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poller?.stop() }
        })
        sessionObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poller?.start() }
        })
    }

    /// Reports whether launchd started the app as a login item, from the
    /// launch Apple event's property data.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
