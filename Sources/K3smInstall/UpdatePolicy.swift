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

import K3smStatus

/// UpdateVerdict is whether the app offers the app-carried "Update k3sm".
public enum UpdateVerdict: Equatable, Sendable {
    /// Offer the update.
    case offer
    /// The payload is the installed version; nothing to do.
    case upToDate
    /// The payload is older than the installed version, or the installed
    /// version is unreadable: only an explicit downgrade may proceed.
    case needsDowngradeConsent
}

/// UpdateDecision is the verdict on the app-carried update.
public struct UpdateDecision: Equatable, Sendable {
    public let verdict: UpdateVerdict

    public init(verdict: UpdateVerdict) {
        self.verdict = verdict
    }
}

/// UpdatePolicy is the root step's own check on the app-carried (payload)
/// install. Which update applies to a Mac, and whether a server may take the
/// payload at all (only when it is the cluster's single node), is
/// `UpdatePlan`'s decision; this check only refuses a payload that is not
/// newer than the install without an explicit downgrade.
public enum UpdatePolicy {
    /// The datastore checks the window shows before a server update (A9,
    /// from the k3sm upgrade guide). The CLI enforces them; a refused start
    /// is shown verbatim in the log.
    public static let serverChecks: [String] = [
        "Take a snapshot first, off this Mac: sudo k3sm snapshot save --out <file>.",
        "Leave free space on the data volume for the datastore migration and its automatic backup.",
        "A release that changes the datastore engine migrates it one way; going back means restoring that snapshot.",
    ]

    public static func decide(
        payload: SemanticVersion,
        installed: SemanticVersion?,
        allowDowngrade: Bool
    ) -> UpdateDecision {
        if let installed {
            switch PayloadRelation(payload: payload, installed: installed) {
            case .same:
                return UpdateDecision(verdict: .upToDate)
            case .older where !allowDowngrade:
                return UpdateDecision(verdict: .needsDowngradeConsent)
            case .newer, .older:
                break
            }
        } else if !allowDowngrade {
            return UpdateDecision(verdict: .needsDowngradeConsent)
        }
        return UpdateDecision(verdict: .offer)
    }
}
