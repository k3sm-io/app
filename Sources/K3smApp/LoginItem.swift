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
import ServiceManagement

/// LoginItem registers the app as the user's login item through
/// SMAppService.mainApp, once per user, so a later choice to disable it in
/// System Settings is never overridden.
@MainActor
enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    /// Registers on the first launch from /Applications and returns the
    /// current status. A developer build run from elsewhere never registers.
    static func registerOnFirstLaunch(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> SMAppService.Status {
        let service = SMAppService.mainApp
        guard bundle.bundlePath.hasPrefix("/Applications/"), !defaults.bool(forKey: registeredKey) else {
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

    /// Opens System Settings at Login Items, for a `.requiresApproval` status.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
