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
import Testing

@testable import K3smStatus

@Suite("the update row while a managed update rolls")
struct RollingRowTests {
    static func rolling(phase: String?) throws -> StatusReport {
        var wide = ["target": "v0.1.8", "node": "laptop", "node-phase": "Installing", "observed": "2026-10-15T10:00:00Z",
                    "latest": "v0.1.8"]
        wide["phase"] = phase
        return try GoldenVariant.report("status_json_server-with-workers.json", replacing: "update", with: [
            "name": "update", "state": "rolling", "severity": "ok",
            "detail": "updating the cluster to k3sm v0.1.8: Rolling, node laptop Installing", "wide": wide,
        ])
    }

    @Test("rolling is its own state with the ok tone, and the menu and button read Updating…")
    func rolling() throws {
        let report = try Self.rolling(phase: "Rolling")
        let row = try #require(report.row(named: "update"))
        #expect(row.rowState == .rolling)
        #expect(row.rowState.tone == .healthy)
        #expect(!row.rowState.degradesVerdict)
        #expect(StatusDisplay.rowDetail(row) == "updating the cluster to k3sm v0.1.8: Rolling, node laptop Installing")
        #expect(UpdateOffer.rowRolling(in: report))
        let offer = UpdateOffer.decide(report: report, progress: UpdateProgress(), developerBuild: false, blocked: nil)
        #expect(offer == .updating)
        #expect(offer.menuTitle == "Updating…" && !offer.isEnabled)
        // The row makes an idle app read the update status, to follow the roll.
        #expect(UpdateProgress().readsStatus(offerShown: false, rowRolling: true))
        #expect(!UpdateProgress().readsStatus(offerShown: false, rowRolling: false))
    }

    @Test("wide.phase reads as the update status phase does", arguments: [
        ("Pending", true), (nil, true), ("Rolling", true), ("Draining", true),
        ("Succeeded", false), ("Failed", false), ("Cancelled", false),
    ] as [(String?, Bool)])
    func phase(_ phase: String?, _ rolls: Bool) throws {
        let report = try Self.rolling(phase: phase)
        #expect(UpdateOffer.rowRolling(in: report) == rolls)
        #expect(UpdatePhase(word: phase ?? "").isFinished == !rolls)
        let offer = UpdateOffer.decide(report: report, progress: UpdateProgress(), developerBuild: false, blocked: nil)
        #expect(offer == (rolls ? .updating : .hidden))
    }

    @Test("the vendored goldens report no roll", arguments: UpdateRowTests.serverReports)
    func goldens(_ file: String) throws {
        #expect(!UpdateOffer.rowRolling(in: try StatusReport.decode(try fixture(file))))
    }
}
