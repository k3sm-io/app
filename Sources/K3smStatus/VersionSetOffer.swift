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

/// VersionSetOffer is the question the app asks once after it updated
/// itself: whether to move k3sm to the release it now carries. It is a
/// presenter over `UpdatePlan` and decides nothing: the plan says which
/// update applies (the roll of the whole cluster to the version set, or the
/// app-carried install on this Mac), and this only words the question, asks
/// it once per release, and asks nothing when the plan offers nothing the
/// app can start. Answering no leaves the update in the menu and Settings.
///
/// `updatedFrom` is the caller's hint that this launch follows a
/// self-update (the swap's launch argument, parsed by the caller); it is a
/// trigger only and its text is never shown. `answeredTag` is the release
/// the question was last answered for (`AppPreferences.versionSetAnsweredTag`).
public struct VersionSetOffer: Equatable, Sendable {
    /// The release the question names and is answered for: the version
    /// set's tag, or for the app-carried install the payload tag when the
    /// app has one, else its version.
    public let tag: String
    public let title: String
    public let body: String
    /// The path a yes runs: the plan's own.
    public let path: UpdatePath

    /// The question for `facts`, by the one plan (`UpdatePlan.decide`).
    public static func decide(facts: UpdatePlanFacts, updatedFrom: String?, answeredTag: String?) -> VersionSetOffer? {
        present(plan: UpdatePlan.decide(facts), role: facts.role, payloadTag: facts.payloadTag,
                updatedFrom: updatedFrom, answeredTag: answeredTag)
    }

    /// The question for a decided plan: nil unless this launch follows a
    /// self-update, the plan can run now, and it is the version set's roll
    /// or the app-carried install; nil too when the question was already
    /// answered for this release.
    public static func present(plan: UpdatePlan, role: NodeRole?, payloadTag: String?,
                               updatedFrom: String?, answeredTag: String?) -> VersionSetOffer? {
        guard updatedFrom != nil, plan.isEnabled, let path = plan.path else { return nil }
        let tag: String
        let title: String
        let body: String
        switch path {
        case .bundled(let set):
            tag = set
            let shown = StatusDisplay.clip(set)
            title = StatusDisplay.clip("Update the cluster to \(set)?")
            body = "This app now carries k3sm \(shown). Update the cluster to it? Workers first, this server last. "
                + Self.later
        case .payload(let version):
            tag = payloadTag ?? "v\(version)"
            let shown = StatusDisplay.clip(tag)
            if role == .agent {
                title = StatusDisplay.clip("Update this Mac to \(tag)?")
                body = "This app now carries k3sm \(shown). Update k3sm on this Mac to it? "
                    + "The server's app updates the rest of the cluster. " + Self.later
            } else {
                title = StatusDisplay.clip("Update k3sm on this Mac to \(tag)?")
                body = "This app now carries k3sm \(shown). Update k3sm on this Mac to it? " + Self.later
            }
        case .managed, .catchUp:
            return nil
        }
        if answeredTag == tag { return nil }
        return VersionSetOffer(tag: tag, title: title, body: body, path: path)
    }

    /// What a no leaves.
    public static let later = "If you choose Not Now, the update stays in the menu and in Settings, Updates."
    /// The button that answers yes.
    public static let confirmTitle = "Update"
    /// The button that answers no.
    public static let declineTitle = "Not Now"
}
