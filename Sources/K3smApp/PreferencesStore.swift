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
import K3smStatus

/// PreferencesStore mirrors `AppPreferences` for the views and for the
/// parts that follow a preference while running (the Dock icon): each
/// property is read once and written through on every change. There is one
/// for the app, since the user defaults it stands for are one domain.
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    let preferences: AppPreferences

    @Published var notifyStoppedAtLogin: Bool {
        didSet { preferences.notifyStoppedAtLogin = notifyStoppedAtLogin }
    }
    @Published var openWindowAtLogin: Bool {
        didSet { preferences.openWindowAtLogin = openWindowAtLogin }
    }
    @Published var dockAnimation: Bool {
        didSet { preferences.dockAnimation = dockAnimation }
    }

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        notifyStoppedAtLogin = preferences.notifyStoppedAtLogin
        openWindowAtLogin = preferences.openWindowAtLogin
        dockAnimation = preferences.dockAnimation
    }
}
