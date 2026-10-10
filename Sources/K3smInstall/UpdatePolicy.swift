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

/// NodeVersion is one joined worker and the k3sm version it reports. A nil
/// version means the worker's version could not be read.
public struct NodeVersion: Hashable, Sendable {
    public let name: String
    public let version: SemanticVersion?

    public init(name: String, version: SemanticVersion?) {
        self.name = name
        self.version = version
    }
}

/// UpdateVerdict is whether the app offers "Update k3sm".
public enum UpdateVerdict: Equatable, Sendable {
    /// Offer the update.
    case offer
    /// The payload is the installed version; nothing to do.
    case upToDate
    /// The payload is older than the installed version, or the installed
    /// version is unreadable: only an explicit downgrade may proceed.
    case needsDowngradeConsent
    /// This Mac is a server and some workers are below the payload version;
    /// they update first.
    case waitForWorkers
}

/// UpdateDecision is the verdict plus the workers still to update, sorted by
/// name, which the window lists when the verdict is `waitForWorkers`.
public struct UpdateDecision: Equatable, Sendable {
    public let verdict: UpdateVerdict
    public let workersToUpdate: [String]
}

/// UpdatePolicy enforces the documented rollout order: workers first, the
/// control-plane Mac last. A worker may update at any time. A server with
/// joined workers updates only once every worker reports a version at or
/// above the payload's, which bounds the skew to one release with the
/// workers ahead.
public enum UpdatePolicy {
    public static func decide(
        role: NodeRole,
        payload: SemanticVersion,
        installed: SemanticVersion?,
        workers: [NodeVersion],
        allowDowngrade: Bool
    ) -> UpdateDecision {
        if let installed {
            switch PayloadRelation(payload: payload, installed: installed) {
            case .same:
                return UpdateDecision(verdict: .upToDate, workersToUpdate: [])
            case .older where !allowDowngrade:
                return UpdateDecision(verdict: .needsDowngradeConsent, workersToUpdate: [])
            case .newer, .older:
                break
            }
        } else if !allowDowngrade {
            return UpdateDecision(verdict: .needsDowngradeConsent, workersToUpdate: [])
        }

        guard role == .server else {
            return UpdateDecision(verdict: .offer, workersToUpdate: [])
        }
        // An unreadable worker version counts as behind: the server never
        // updates past a worker it cannot vouch for.
        let behind = workers
            .filter { worker in worker.version.map { $0 < payload } ?? true }
            .map(\.name)
            .sorted()
        if behind.isEmpty {
            return UpdateDecision(verdict: .offer, workersToUpdate: [])
        }
        return UpdateDecision(verdict: .waitForWorkers, workersToUpdate: behind)
    }
}
