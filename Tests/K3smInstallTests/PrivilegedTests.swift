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

@testable import K3smInstall

@Suite("privileged availability")
struct PrivilegedAvailabilityTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let team: Bool
        let signature: Bool
        let admin: Bool
        let enabled: Bool
        let reasonContains: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "all checks pass", team: true, signature: true, admin: true, enabled: true, reasonContains: ""),
        Case(name: "ad-hoc build", team: false, signature: true, admin: true, enabled: false, reasonContains: "not Developer ID signed"),
        Case(name: "tampered bundle", team: true, signature: false, admin: true, enabled: false, reasonContains: "signature check"),
        Case(name: "standard user", team: true, signature: true, admin: false, enabled: false, reasonContains: "administrator"),
        Case(name: "first failing check wins", team: false, signature: false, admin: false, enabled: false, reasonContains: "not Developer ID signed"),
    ]

    @Test("evaluate", arguments: cases)
    func evaluate(_ c: Case) {
        let got = PrivilegedAvailability.evaluate(
            teamID: c.team ? TeamID("ABCDE12345") : nil, signatureValid: c.signature, userIsAdmin: c.admin)
        switch got {
        case .enabled:
            #expect(c.enabled)
        case .disabled(let reason):
            #expect(!c.enabled)
            #expect(reason.contains(c.reasonContains))
        }
    }
}
