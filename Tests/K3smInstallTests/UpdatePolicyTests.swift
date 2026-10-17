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
        let payload: String
        let installed: String?
        var allowDowngrade = false
        let want: UpdateVerdict
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "newer payload", payload: "0.2.0", installed: "0.1.7", want: .offer),
        Case(name: "same version", payload: "0.2.0", installed: "v0.2.0", want: .upToDate),
        Case(name: "older payload needs consent", payload: "0.1.6", installed: "0.1.7", want: .needsDowngradeConsent),
        Case(name: "older payload with consent", payload: "0.1.6", installed: "0.1.7", allowDowngrade: true, want: .offer),
        Case(name: "unknown installed needs consent", payload: "0.2.0", installed: nil, want: .needsDowngradeConsent),
        Case(name: "unknown installed with consent", payload: "0.2.0", installed: nil, allowDowngrade: true, want: .offer),
    ]

    @Test("decide", arguments: cases)
    func decide(_ c: Case) throws {
        let decision = UpdatePolicy.decide(
            payload: try #require(SemanticVersion(c.payload)),
            installed: c.installed.flatMap(SemanticVersion.init),
            allowDowngrade: c.allowDowngrade
        )
        #expect(decision.verdict == c.want)
    }

    /// The policy admits every payload install the plan can choose, and
    /// every verdict it can give is one the plan produces too.
    @Test("updatePolicyMatchesPlan")
    func updatePolicyMatchesPlan() throws {
        let versions = ["0.1.5", "0.1.7", "0.2.0", "0.2.1-rc.1"].compactMap(SemanticVersion.init)
        var installs = 0
        var seen: Set<String> = []
        for role in [NodeRole.server, .agent] {
            for installed in [nil] + versions.map(Optional.some) {
                for payload in [nil] + versions.map(Optional.some) {
                    for workers in [nil, 0, 2] as [Int?] {
                        for developerBuild in [false, true] {
                            let facts = UpdatePlanFacts(
                                role: role, installed: installed, payload: payload, workers: workers,
                                developerBuild: developerBuild)
                            let plan = UpdatePlan.decide(facts)
                            // The guard the policy no longer carries: a server with
                            // other nodes, or an unknown count, never plans the payload.
                            if role == .server, workers != 0 {
                                if case .payload = plan { Issue.record("server with workers \(String(describing: workers)) planned the payload") }
                            }
                            if case .payload(let version) = plan {
                                installs += 1
                                let decision = UpdatePolicy.decide(payload: version, installed: installed, allowDowngrade: false)
                                #expect(decision.verdict == .offer)
                            }
                            guard let payload else { continue }
                            // Every verdict the policy gives has a plan that produces it.
                            let verdict = UpdatePolicy.decide(payload: payload, installed: installed, allowDowngrade: false).verdict
                            switch verdict {
                            case .offer:
                                seen.insert("offer")
                            case .upToDate:
                                seen.insert("upToDate")
                                if developerBuild == false, workers == 0, let installed, role == .server {
                                    #expect(plan == .none, "\(payload) \(installed)")
                                }
                            case .needsDowngradeConsent:
                                seen.insert("needsDowngradeConsent")
                                if developerBuild == false, workers == 0, role == .server {
                                    if let installed {
                                        #expect(plan == .blocked(.downgrade(installed: installed, payload: payload)))
                                    } else {
                                        #expect(plan == .blocked(.installedUnknown))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(installs > 0)
        #expect(seen == ["offer", "upToDate", "needsDowngradeConsent"])
    }

    @Test("the server checks name the snapshot, the free space and the one-way engine change")
    func serverChecks() {
        let text = UpdatePolicy.serverChecks.joined(separator: " ")
        #expect(text.contains("k3sm snapshot save"))
        #expect(text.contains("free space"))
        #expect(text.contains("one way"))
    }
}
