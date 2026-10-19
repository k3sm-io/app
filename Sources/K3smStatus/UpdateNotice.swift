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

/// UpdateNotice is the notification the app posts when the one update plan
/// (`UpdatePlan`) first offers an update the app can start: once per
/// release, only with the Updates pane's preference on, and never for a
/// blocked plan, a roll under way or nothing to do. The release a notice
/// names is kept (`AppPreferences.updateNotifiedRelease`), so the same one
/// is never announced again, across launches too.
public struct UpdateNotice: Equatable, Sendable {
    /// The release key it names, compared without a leading "v".
    public let release: String
    public let title: String
    public let body: String

    /// The line under the Updates pane's checkbox.
    public static let paneNote = "macOS asks once whether k3sm may post notifications. Each release is announced once, and a click opens this pane."

    /// The category a click on the notice is routed by.
    public static let category = "io.k3sm.app.update-available"

    /// The release an update plan offers, clipped and without a leading
    /// "v"; nil unless the plan is an update the app can start now.
    public static func release(of plan: UpdatePlan) -> String? {
        guard plan.isEnabled, let shown = shownRelease(plan) else { return nil }
        return key(shown)
    }

    /// The notice to post for `plan`, or nil: the preference is off, the
    /// plan offers nothing the app can start, or `notified` already names
    /// its release.
    public static func decide(plan: UpdatePlan, enabled: Bool, notified: String?) -> UpdateNotice? {
        guard enabled, let release = release(of: plan), let shown = shownRelease(plan), let path = plan.path else { return nil }
        if let notified, key(notified) == release { return nil }
        return UpdateNotice(release: release, title: StatusDisplay.clip("k3sm \(shown) is available"), body: path.sentence)
    }

    /// The release as the plan's controls name it: the payload's version,
    /// or the roll's tag, clipped.
    private static func shownRelease(_ plan: UpdatePlan) -> String? {
        switch plan.path {
        case .payload(let version): return version.description
        case .managed(let tag), .catchUp(let tag, _), .bundled(let tag):
            let clipped = StatusDisplay.clip(tag)
            return clipped.isEmpty ? nil : clipped
        case nil: return nil
        }
    }

    private static func key(_ release: String) -> String {
        let clipped = StatusDisplay.clip(release)
        return clipped.hasPrefix("v") ? String(clipped.dropFirst()) : clipped
    }

    /// What macOS has answered about this app's notifications, the three
    /// cases of `UNAuthorizationStatus` that matter here.
    public enum Permission: Sendable {
        case notDetermined
        case authorized
        case denied
    }

    /// What to do with a due notice.
    public enum Step: Sendable {
        /// Ask for permission (macOS shows its prompt once), then post if granted.
        case ask
        case post
        /// The user said no; post nothing and do not ask again.
        case skip
    }

    /// The step for `permission`: the app asks only while macOS has no answer.
    public static func step(_ permission: Permission) -> Step {
        switch permission {
        case .notDetermined: .ask
        case .authorized: .post
        case .denied: .skip
        }
    }

    public init(release: String, title: String, body: String) {
        self.release = release
        self.title = title
        self.body = body
    }
}
