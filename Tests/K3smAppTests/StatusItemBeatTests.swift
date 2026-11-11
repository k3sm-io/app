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
import Testing
@testable import K3smApp

/// The status item's beat: the icon follows the wordmark's angle unless the
/// waiting frames play, and a pointer on the icon reaches the controller.
struct StatusItemBeatTests {
    @Test("the waiting frames take precedence while they play, the wordmark's angle otherwise")
    func precedence() {
        #expect(StatusItemController.shownAngle(waitingPlaying: true, waiting: 35, flap: 70) == 35)
        #expect(StatusItemController.shownAngle(waitingPlaying: true, waiting: 0, flap: 70) == 0)
        #expect(StatusItemController.shownAngle(waitingPlaying: false, waiting: 0, flap: 70) == 70)
        #expect(StatusItemController.shownAngle(waitingPlaying: false, waiting: 0, flap: 0) == 0)
    }

    /// The tracking area's owner is an NSObject, so AppKit reaches the hover
    /// methods only by their Objective-C names. Without a status item on
    /// screen, the selectors are what can be checked.
    @Test("the controller answers the tracking area's mouseEntered: and mouseExited:")
    @MainActor func answersTrackingSelectors() {
        _ = NSApplication.shared
        let controller = StatusItemController(model: AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:]),
                                              openWindow: {}, openSettings: {})
        #expect(controller.responds(to: NSSelectorFromString("mouseEntered:")))
        #expect(controller.responds(to: NSSelectorFromString("mouseExited:")))
    }
}
