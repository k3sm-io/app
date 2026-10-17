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
import UserNotifications

/// StoppedNotifier posts the app's two notifications and routes the user's
/// answer. The login-time "k3sm is stopped" one has a Start action, which
/// runs the start verb (a fresh confirmation and administrator prompt, after
/// a live status re-read), and a click on it opens the window. It is a
/// notification, not the status item, so the item still shows only while
/// k3sm runs. The "update available" one (`UpdateNotice`) asks macOS for
/// permission only while it has no answer, and a click on it opens the
/// Settings window's Updates pane. The center has one delegate, so both
/// live here and a response is routed by its category.
@MainActor
final class StoppedNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let onStart: @MainActor () -> Void
    private let onOpen: @MainActor () -> Void
    private let onUpdate: @MainActor () -> Void

    init(onStart: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor () -> Void,
         onUpdate: @escaping @MainActor () -> Void) {
        self.onStart = onStart
        self.onOpen = onOpen
        self.onUpdate = onUpdate
        super.init()
    }

    /// The notification center, only inside an app bundle: outside one the
    /// framework has no bundle to post for.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Registers the Start action and becomes the delegate, so a response is
    /// delivered even when the app was launched by a click on it.
    func install() {
        guard let center = Self.center else { return }
        let start = UNNotificationAction(identifier: StoppedNotice.startAction, title: "Start", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: StoppedNotice.category, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: UpdateNotice.category, actions: [], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    /// Posts the notice for this launch, if one is due.
    func postIfDue(loginLaunch: Bool, report: StatusReport?) {
        guard let title = StoppedNotice.title(loginLaunch: loginLaunch, report: report), let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = StoppedNotice.body
        content.categoryIdentifier = StoppedNotice.category
        let request = UNNotificationRequest(identifier: "io.k3sm.app.stopped-at-login", content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else {
                log.notice("stopped notice: not authorized")
                return
            }
            try? await center.add(request)
            log.notice("stopped notice: posted")
        }
    }

    /// Posts an update notice. The caller has already recorded its release,
    /// so a notice macOS refuses is not tried again for that release.
    func postUpdate(_ notice: UpdateNotice) {
        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = UpdateNotice.category
        let request = UNNotificationRequest(identifier: "io.k3sm.app.update-available", content: content, trigger: nil)
        Task {
            let permission: UpdateNotice.Permission
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined: permission = .notDetermined
            case .denied: permission = .denied
            default: permission = .authorized
            }
            switch UpdateNotice.step(permission) {
            case .skip:
                log.notice("update notice: not authorized")
                return
            case .ask:
                guard (try? await center.requestAuthorization(options: [.alert])) == true else {
                    log.notice("update notice: not authorized")
                    return
                }
            case .post:
                break
            }
            try? await center.add(request)
            log.notice("update notice: posted")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            if category == UpdateNotice.category {
                onUpdate()
            } else if action == StoppedNotice.startAction {
                onStart()
            } else if action == UNNotificationDefaultActionIdentifier {
                onOpen()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
