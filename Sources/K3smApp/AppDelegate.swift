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
import K3smHost
import K3smInstall
import K3smStatus
import K3smSwap

/// AppDelegate wires the parts together: the poller feeds the status item,
/// the status item and a reopen open the window, the login item is
/// registered once, and an activity assertion keeps App Nap from stretching
/// the poll timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windowController: MainWindowController?
    private var mainMenu: MainMenu?
    private var statusItem: StatusItemController?
    private var poller: StatusPoller?
    private var notifier: StoppedNotifier?
    /// Whether the first poll of a login-item launch is still to be checked
    /// for the stopped notice.
    private var noticePending = false
    private var activity: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    /// Applies the appearance preference to the app, now and on every change.
    private var appearanceObserver: AnyCancellable?
    /// The scripted demo tour, when `--demo-tour` named one.
    private var demo: DemoTourRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A self-update a killed helper, a logout or a reboot interrupted is
        // finished or undone first, before any UI; a swap back quits now.
        if Self.reconcileSwap() == .quitForSwapBack {
            NSApplication.shared.terminate(nil)
            return
        }
        // A refused --demo-tour argument or file ends the process here,
        // before anything is built.
        let demoTour = DemoTourRunner.load()
        let loginLaunch = Self.launchedAsLoginItem()
        // The k3sm CLI's launch after install, join and start: the window
        // policy of a login launch, nothing else of one.
        let background = LaunchPolicy.isBackground(arguments: CommandLine.arguments)
        // A join command a crashed or force-quit run left on the pasteboard
        // goes now; only this app's own concealed line is ever cleared.
        if ConcealedClipboard.sweepLeftover(GeneralPasteboard()) {
            log.notice("join command: cleared a leftover from an earlier run")
        }
        let environment = SelfCheck.cliEnvironment()
        let model = AppModel(runner: AppleScriptPrivilegedRunner(), environment: environment)
        let windowController = MainWindowController(model: model)
        let preferences = PreferencesStore.shared
        // The publisher gives the stored value at once, then every change,
        // so the app follows the preference from launch with no relaunch.
        appearanceObserver = preferences.$appearance.sink { Self.apply($0) }
        let settings = SettingsWindowController(model: SettingsModel(
            app: model, preferences: preferences, showConsole: { [weak windowController] in windowController?.show() }))
        SettingsWindowController.shared = settings
        let mainMenu = MainMenu(model: model, show: { [weak windowController] in windowController?.show() },
                                settings: { [weak settings] in settings?.show() })
        mainMenu.install()
        let statusItem = StatusItemController(model: model, openWindow: { [weak windowController] in windowController?.show() },
                                              openSettings: { [weak settings] in settings?.show() })
        let notifier = StoppedNotifier(
            onStart: { [weak model] in model?.perform(.start, expected: .stopped) },
            onOpen: { [weak windowController] in windowController?.show() },
            onUpdate: { [weak settings] in settings?.show(pane: .updates) })
        notifier.install()
        // A demo tour is a recording: it posts no update notice.
        if demoTour == nil {
            model.onUpdateRead = { [weak model, weak notifier] in
                guard let model, let notifier else { return }
                Self.noteUpdate(model.updatePlan, preferences: preferences.preferences, notifier: notifier)
            }
        }
        noticePending = preferences.preferences.checksStoppedNotice(loginLaunch: loginLaunch)
        let poller = StatusPoller(environment: environment) { [weak statusItem, weak self] reading, report in
            statusItem?.observe(reading, report: report)
            self?.poller?.itemVisible = statusItem?.wantsVisible ?? false
            self?.checkStoppedNotice(report)
        }
        self.notifier = notifier
        self.model = model
        self.windowController = windowController
        self.mainMenu = mainMenu
        self.statusItem = statusItem
        self.poller = poller

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Polls k3sm status for the menu bar item"
        )
        // A demo tour run registers no login item: it is a recording, not
        // the user's first launch.
        if demoTour == nil {
            model.loginItemNeedsApproval = LoginItem.registerOnFirstLaunch() == .requiresApproval
        }
        // Each streamed report reaches the status item as a probe run does.
        model.onStreamReport = { [weak statusItem] report in
            statusItem?.observe(Reading.of(report), report: report)
        }
        observeSession()
        poller.start()
        model.startStatusStream()
        if demoTour == nil {
            model.startUpdateCheck(wanted: { preferences.notifyUpdate })
        }
        log.notice("k3sm app started")
        // A login-item launch, or one with --background, shows only the status
        // item, unless Settings asks for the window at login too; any launch
        // the user made (Finder, Spotlight, the Dock) shows the window.
        if let demoTour {
            // The demo tour always shows the window, then walks it and quits.
            windowController.show()
            let demo = DemoTourRunner(entries: demoTour, model: model, window: { [weak windowController] in windowController?.consoleWindow })
            self.demo = demo
            demo.start()
        } else if preferences.preferences.opensWindow(loginLaunch: loginLaunch, background: background) {
            windowController.show()
        }
        // The swap helper launched this app and waits for its answer, now
        // that the status item is up.
        if SwapLaunchArguments(arguments: CommandLine.arguments).answersHandshake {
            Self.answerHandshake()
        }
    }

    /// Runs the launch-time reconcile of a self-update (`SwapReconciler`).
    /// A developer build pins no team and never updates itself, so it has
    /// nothing to reconcile.
    private static func reconcileSwap() -> ReconcileResult {
        guard let team = SelfCheck.teamID(), let paths = SwapPaths.forCurrentUser() else { return .carryOn }
        let appRequirement = AppUpdateTrust.appRequirement(teamID: team)
        let helper = Bundle.main.bundlePath + "/" + SwapPaths.bundledHelperPath
        let spawner = HelperSpawner(paths: paths, requirement: AppUpdateTrust.helperRequirement(teamID: team))
        let reconciler = SwapReconciler(
            paths: paths,
            verifier: StaticCodeVerifier(requirement: appRequirement, runningTeam: team),
            currentApp: ProcessIdentity.current(),
            spawnGoBack: {
                do {
                    try spawner.installHelperCopy(from: helper)
                    try spawner.spawn(mode: .goBack, bundled: helper)
                    return true
                } catch {
                    return false
                }
            })
        return reconciler.reconcile(runningTag: AppVersion.payloadTag(info: Bundle.main.infoDictionary),
                                    runningSelfCheck: { SelfCheck.signatureValid(team: team) })
    }

    /// Answers the swap helper's handshake once this bundle's own signature
    /// check passes (`SelfCheck`); the helper binds the answer to this
    /// process's pid and code.
    private static func answerHandshake() {
        guard let team = SelfCheck.teamID(), SelfCheck.signatureValid(team: team),
              let paths = SwapPaths.forCurrentUser()
        else { return }
        if HandshakeAnswer.write(paths: paths) {
            log.notice("self-update: answered the swap helper")
        }
    }

    /// Sets the app's appearance, which every window, the popover and the
    /// menus inherit; System clears it so they follow macOS. The status
    /// item's button is drawn in the menu bar and keeps the menu bar's own.
    private static func apply(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.appearanceName.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A tour still running puts the user's layout back before it is saved.
        model?.tour.end()
        poller?.stop()
        model?.statusStream.stop()
        // No held kubectl watch outlives the app.
        model?.workloads.stopStreams()
        CLIStream.killAll()
        // A join command still on the pasteboard, unchanged, goes with the app.
        model?.joinClipboard.clearIfUnchanged()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// After a login-item launch, the first poll decides whether k3sm is
    /// stopped with a recorded stop; if so, the notice is posted once.
    private func checkStoppedNotice(_ report: StatusReport?) {
        guard noticePending else { return }
        noticePending = false
        notifier?.postIfDue(loginLaunch: true, report: report)
    }

    /// Posts the update notice when `UpdateNotice` says one is due, after
    /// recording its release, so each release is announced once.
    private static func noteUpdate(_ plan: UpdatePlan, preferences: AppPreferences, notifier: StoppedNotifier) {
        guard let notice = UpdateNotice.decide(plan: plan, enabled: preferences.notifyUpdate,
                                               notified: preferences.updateNotifiedRelease) else { return }
        preferences.updateNotifiedRelease = notice.release
        notifier.postUpdate(notice)
    }

    /// Pauses polling while this user's session is not the active console
    /// session (fast user switching), and resumes when it returns.
    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        sessionObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poller?.stop()
                self?.model?.statusStream.stop()
            }
        })
        sessionObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poller?.start()
                self?.model?.startStatusStream()
            }
        })
        // A held watch may be half-open after sleep: each is restarted once.
        sessionObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.workloads.wakeStreams()
                self?.model?.statusStream.wake()
            }
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
