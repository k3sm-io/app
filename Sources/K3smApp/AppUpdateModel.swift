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

import Combine
import Foundation
import K3smHost
import K3smStatus

/// AppUpdateModel runs the app's own update check and holds its line for
/// Settings > Updates and the menu: the first check a minute after launch,
/// then one a day (`AppUpdateSchedule`), and Check Now. Every decision is in
/// `K3smStatus` (`AppUpdateState`, `AppUpdateRecord`, `AppUpdateFollowUp`)
/// and the request in `K3smHost` (`AppUpdateChecker`); this only schedules
/// them and keeps the record. Nothing here runs the CLI or rolls the cluster.
@MainActor
final class AppUpdateModel: ObservableObject {
    @Published private(set) var state: AppUpdateState
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var checking = false

    let own: AppUpdateOwn
    private let checker: AppUpdateChecker?
    private let preferences: AppPreferences
    private var result: AppUpdateResult?
    private var task: Task<Void, Never>?

    /// Whether the app is still in first run, when no automatic check runs.
    var firstRun: () -> Bool = { false }
    /// A follow-up the state calls for (the notice, the download).
    var onFollowUp: ((AppUpdateFollowUp) -> Void)?

    init(pinned: Bool, preferences: AppPreferences) {
        let own = AppUpdateOwn(info: Bundle.main.infoDictionary, pinned: pinned)
        self.own = own
        self.preferences = preferences
        checker = own.isRelease ? AppUpdateChecker.pinned : nil
        lastSuccess = preferences.appUpdateLastSuccess
        state = AppUpdateState.decide(own: own, result: nil, download: .idle, macOS: ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// Starts the automatic loop; a second start is a no-op. A development
    /// build starts nothing.
    func start() {
        guard task == nil, checker != nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: AppUpdateSchedule.firstDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.run(.automatic)
                try? await Task.sleep(for: AppUpdateSchedule.wait(profile: PollSchedule.profile, unit: PollJitter.draw()))
            }
        }
    }

    /// Check for Updates in the app menu and Check Now in Settings.
    func checkNow() {
        Task { await run(.user) }
    }

    private func run(_ trigger: AppUpdateSchedule.Trigger) async {
        guard let checker, !checking else { return }
        checking = true
        defer { checking = false }
        let outcome = await checker.check(trigger, checksOn: preferences.checkAppUpdates, own: own, firstRun: firstRun(),
                                          record: preferences.appUpdateRecord)
        guard let fresh = outcome.result else { return }
        result = fresh
        preferences.appUpdateRecord = outcome.record
        if case .verified = fresh {
            let now = Date()
            lastSuccess = now
            preferences.appUpdateLastSuccess = now
        }
        let next = AppUpdateState.decide(own: own, result: fresh, download: .idle, macOS: ProcessInfo.processInfo.operatingSystemVersion)
        if next != state { appUpdateLog.notice("app update: state \(next.line, privacy: .public)") }
        state = next
        for step in AppUpdateFollowUp.decide(next, downloadOn: preferences.downloadAppUpdates, notifyOn: preferences.notifyUpdate,
                                             notified: preferences.appUpdateNotifiedRelease) {
            if case .notify(let release) = step { preferences.appUpdateNotifiedRelease = release }
            onFollowUp?(step)
        }
    }
}
