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

/// AppActivation applies `WindowPresence` for every window the app opens:
/// the console and Settings each report opening and closing here, so the
/// app stays a regular app while either is up and goes back to an accessory
/// only when both are closed. No window sets the activation policy itself.
@MainActor
enum AppActivation {
    private static var presence = WindowPresence()

    static func opened(_ window: AppWindow) {
        apply(presence.opened(window))
    }

    static func closed(_ window: AppWindow) {
        apply(presence.closed(window))
    }

    private static func apply(_ regular: Bool) {
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }
}
