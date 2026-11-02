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

/// The `budget` block of `k3sm status -o json` comes from a record on this
/// Mac's disk, not from the cluster's NodeBudget, so anything that can write
/// that record can forge it. It may only ever add a refusal; it may never
/// produce a go-ahead. Today the app does not read the block at all: no
/// update fact (`UpdatePlanFacts`) depends on it, so the update plan is the
/// same with any block, calm or evicting, as with none.
@Suite("the status budget block is deny-only evidence")
struct BudgetBlockTests {
    /// A fresh block that says all is calm and pods may be admitted.
    static func calm(at now: Date = Date()) -> [String: Any] {
        ["observedAt": ISO8601DateFormatter().string(from: now), "platform": "darwin", "level": "ok", "admit": true,
         "recommendation": ["safeAdditionalBytes": 34_359_738_368, "basis": "memory.compressor"]]
    }

    /// A block that says the node is evicting and admits nothing.
    static func evicting(at now: Date = Date()) -> [String: Any] {
        ["observedAt": ISO8601DateFormatter().string(from: now), "platform": "darwin", "level": "evicting", "admit": false,
         "evictDeadline": ISO8601DateFormatter().string(from: now.addingTimeInterval(30))]
    }

    /// k3sm's multi-node server golden moved to v0.1.8 on every node (the
    /// server's own Node, its release and both workers), so the version set
    /// at v0.1.9 is a roll the plan offers, with its `budget` key set to
    /// `block` (none when nil).
    static func report(budget block: [String: Any]?) throws -> StatusReport {
        var top = try #require(try JSONSerialization.jsonObject(with: try fixture("status_json_server-with-workers.json")) as? [String: Any])
        var rows = try #require(top["rows"] as? [[String: Any]])
        for i in rows.indices where rows[i]["name"] as? String == "node" {
            rows[i]["wide"] = ["kubelet": "v1.36.2+k3sm.0.1.8", "node": "my-mac"]
        }
        top["rows"] = rows
        var workers = try #require(top["workers"] as? [[String: Any]])
        for i in workers.indices { workers[i]["version"] = "v1.36.2+k3sm.0.1.8" }
        top["workers"] = workers
        var version = try #require(top["version"] as? [String: Any])
        version["version"] = "v0.1.8"
        top["version"] = version
        top["budget"] = block
        return try StatusReport.decode(try JSONSerialization.data(withJSONObject: top))
    }

    @Test("a calm budget block with no cluster copy never turns Not now into a roll, and no block moves the plan")
    func budgetBlockNeverAllowsARoll() throws {
        let names = ["node-a", "node-b"]
        let ready = BundledOfferTests.nodes(names)
        let notReady = BundledOfferTests.nodes(names, notReady: ["node-b"])
        // The baselines with no block: every node Ready offers the roll; a
        // node not Ready is Not now.
        let offer = UpdatePlan.decide(BundledOfferTests.facts(try Self.report(budget: nil), nodes: ready))
        #expect(offer == .bundled(tag: "v0.1.9"))
        let bare = BundledOfferTests.facts(try Self.report(budget: nil), nodes: notReady)
        #expect(UpdatePlan.decide(bare) == .blocked(.bundledNodeNotReady(["node-b"])))
        // A fresh calm block with no NodeBudget from the cluster is no
        // go-ahead: Not now stays Not now, and no fact the plan reads moves.
        let calm = BundledOfferTests.facts(try Self.report(budget: Self.calm()), nodes: notReady)
        #expect(calm == bare)
        let notNow = UpdatePlan.decide(calm)
        #expect(notNow == .blocked(.bundledNodeNotReady(["node-b"])))
        #expect(!notNow.isEnabled)
        // An evicting block cannot widen anything either. The app does not
        // read the block, so it adds no refusal of its own today: the plan
        // is exactly the one without a block.
        for block in [Self.evicting(), Self.calm()] {
            let facts = BundledOfferTests.facts(try Self.report(budget: block), nodes: ready)
            #expect(facts == BundledOfferTests.facts(try Self.report(budget: nil), nodes: ready))
            #expect(UpdatePlan.decide(facts) == offer)
        }
        // k3sm's own golden with a budget block reads as the same report
        // without it.
        let golden = try StatusReport.decode(try fixture("status_json_running-budget.json"))
        let plain = try StatusReport.decode(try fixture("status_json_running.json"))
        for nodes in [ready, notReady] {
            #expect(BundledOfferTests.facts(golden, nodes: nodes) == BundledOfferTests.facts(plain, nodes: nodes))
        }
    }
}
