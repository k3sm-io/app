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

import Foundation
import K3smStatus
import ServiceManagement

/// LoginItem registers the app as the user's login item through
/// SMAppService.mainApp, once per user, so a later choice to disable it in
/// System Settings is never overridden. The General pane's Open at login
/// control reads its status and registers or unregisters it on request.
@MainActor
enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    /// Registers on the first launch from /Applications and returns the
    /// current status. A developer build run from elsewhere never registers.
    static func registerOnFirstLaunch(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> SMAppService.Status {
        let service = SMAppService.mainApp
        guard inApplications(bundle: bundle), !defaults.bool(forKey: registeredKey) else {
            return service.status
        }
        do {
            try service.register()
            defaults.set(true, forKey: registeredKey)
            log.notice("login item: registered")
        } catch {
            log.error("login item: registration failed: \(error.localizedDescription, privacy: .public)")
        }
        return service.status
    }

    /// Whether this copy runs from /Applications, the only place it registers from.
    static func inApplications(bundle: Bundle = .main) -> Bool {
        bundle.bundlePath.hasPrefix("/Applications/")
    }

    /// The login item's status as the system reports it now.
    static func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    /// Registers or unregisters the login item at the user's request. A
    /// registration also records the first-launch guard, so a later launch
    /// never registers again on its own after the user turns it off.
    static func set(enabled: Bool, defaults: UserDefaults = .standard) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
            defaults.set(true, forKey: registeredKey)
            log.notice("login item: registered from Settings")
        } else {
            try service.unregister()
            log.notice("login item: unregistered from Settings")
        }
    }

    /// Opens System Settings at Login Items, for a `.requiresApproval` status.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
