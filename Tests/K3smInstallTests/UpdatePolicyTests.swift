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

import Testing

import K3smStatus
@testable import K3smInstall

@Suite("update policy")
struct UpdatePolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let role: NodeRole
        let payload: String
        let installed: String?
        let workers: [(String, String?)]?
        var allowDowngrade = false
        var confirmed = false
        let want: UpdateVerdict
        var wantBehind: [String] = []
        var wantUnverified: [String] = []
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "worker, newer payload", role: .agent, payload: "0.2.0", installed: "0.1.7", workers: [], want: .offer),
        Case(name: "worker ignores other workers", role: .agent, payload: "0.2.0", installed: "0.1.7",
             workers: [("w2", "0.1.0")], want: .offer),
        Case(name: "same version", role: .server, payload: "0.2.0", installed: "v0.2.0", workers: [], want: .upToDate),
        Case(name: "older payload needs consent", role: .agent, payload: "0.1.6", installed: "0.1.7", workers: [], want: .needsDowngradeConsent),
        Case(name: "older payload with consent", role: .agent, payload: "0.1.6", installed: "0.1.7", workers: [],
             allowDowngrade: true, want: .offer),
        Case(name: "unknown installed needs consent", role: .server, payload: "0.2.0", installed: nil, workers: [], want: .needsDowngradeConsent),
        Case(name: "unknown installed with consent", role: .server, payload: "0.2.0", installed: nil, workers: [],
             allowDowngrade: true, want: .offer),
        Case(name: "server alone", role: .server, payload: "0.2.0", installed: "0.1.7", workers: [], want: .offer),
        Case(name: "server, workers already updated", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w1", "0.2.0"), ("w2", "0.2.1")], want: .offer),
        Case(name: "server, workers behind", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w2", "0.1.7"), ("w1", "0.2.0"), ("a3", "0.2.0-rc.1")], want: .waitForWorkers, wantBehind: ["a3", "w2"]),
        Case(name: "server, a worker without a version keeps the confirmation", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w1", nil), ("w2", "0.2.0")], want: .confirmWorkersUpdated, wantUnverified: ["w1"]),
        Case(name: "server, a worker without a version, confirmed", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w1", nil), ("w2", "0.2.0")], confirmed: true, want: .offer, wantUnverified: ["w1"]),
        Case(name: "server, behind beats unknown", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w1", nil), ("w2", "0.1.7")], confirmed: true, want: .waitForWorkers, wantBehind: ["w2"]),
        Case(name: "server downgrade with consent still checks workers", role: .server, payload: "0.1.6", installed: "0.1.7",
             workers: [("w1", "0.1.5")], allowDowngrade: true, want: .waitForWorkers, wantBehind: ["w1"]),
        // An absent worker list (nil) is unknown, never "no workers": a server
        // waits for the user's confirmation, a worker does not.
        Case(name: "server, worker versions unknown", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: nil, want: .confirmWorkersUpdated),
        Case(name: "server, worker versions unknown, confirmed", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: nil, confirmed: true, want: .offer),
        Case(name: "worker, versions unknown", role: .agent, payload: "0.2.0", installed: "0.1.7", workers: nil, want: .offer),
        Case(name: "confirmation does not override a known lagging worker", role: .server, payload: "0.2.0", installed: "0.1.7",
             workers: [("w1", "0.1.7")], confirmed: true, want: .waitForWorkers, wantBehind: ["w1"]),
        Case(name: "confirmation does not override up to date", role: .server, payload: "0.2.0", installed: "0.2.0",
             workers: nil, confirmed: true, want: .upToDate),
        Case(name: "confirmation does not license a downgrade", role: .server, payload: "0.1.6", installed: "0.1.7",
             workers: nil, confirmed: true, want: .needsDowngradeConsent),
    ]

    @Test("decide", arguments: cases)
    func decide(_ c: Case) throws {
        let decision = UpdatePolicy.decide(
            role: c.role,
            payload: try #require(SemanticVersion(c.payload)),
            installed: c.installed.flatMap(SemanticVersion.init),
            workers: c.workers.map { $0.map { NodeVersion(name: $0.0, version: $0.1.flatMap(SemanticVersion.init)) } },
            allowDowngrade: c.allowDowngrade,
            workersConfirmed: c.confirmed
        )
        #expect(decision.verdict == c.want)
        #expect(decision.workersToUpdate == c.wantBehind)
        #expect(decision.workersUnverified == c.wantUnverified)
    }

    @Test("the server checks name the snapshot, the free space and the one-way engine change")
    func serverChecks() {
        let text = UpdatePolicy.serverChecks.joined(separator: " ")
        #expect(text.contains("k3sm snapshot save"))
        #expect(text.contains("free space"))
        #expect(text.contains("one way"))
    }
}
