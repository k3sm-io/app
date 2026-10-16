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

@Suite("the Settings window's Network pane")
struct NetworkPaneTests {
    private static func report(_ name: String) throws -> StatusReport {
        try StatusReport.decode(fixture(name))
    }

    @Test("the Network pane shows the state, the listeners and the node's address")
    func networkPaneFacts() throws {
        let recorded = try Self.report("status_json_network-recorded.json")
        let nodes = [ClusterNode(name: "my-mac", ready: true, internalIP: "192.0.2.10"),
                     ClusterNode(name: "other", ready: true, internalIP: "192.0.2.11")]
        #expect(NetworkPaneFacts.lines(report: recorded, nodes: nodes) == [
            "Now: off, as k3sm serves it",
            "The switch controls: nodeports, loadbalancers, ingress",
            "Always open to the network: apiserver, join, mesh",
            "This node's address is 192.0.2.10; workloads there answer only this Mac and the cluster mesh",
        ])
        // No node list read yet: no address line.
        #expect(NetworkPaneFacts.lines(report: recorded, nodes: nil).count == 3)

        let absent = try Self.report("status_json_network-absent.json")
        #expect(NetworkPaneFacts.lines(report: absent, nodes: nodes).first == "Now: on, since no setting is recorded")
        #expect(NetworkPaneFacts.lines(report: absent, nodes: nodes).last == "Other devices reach this node at 192.0.2.10")

        let applied = try Self.report("status_json_network-applied-unreadable.json")
        #expect(NetworkPaneFacts.lines(report: applied, nodes: nil).first == "Now: off, as recorded")

        let none = try Self.report("status_json_not-installed.json")
        #expect(NetworkPaneFacts.lines(report: none, nodes: nil) == [NetworkPaneFacts.noSwitchText])
        #expect(NetworkPaneFacts.lines(report: nil, nodes: nodes).isEmpty)

        #expect(NetworkPaneFacts.stateLine(.unreadableField) == "Now: unknown")
    }

    @Test("a node address from the cluster is clipped to one line")
    func addressClipped() throws {
        let recorded = try Self.report("status_json_network-recorded.json")
        let nodes = [ClusterNode(name: "my-mac", ready: true, internalIP: "192.0.2.10\nforged line")]
        let address = NetworkPaneFacts.address(report: recorded, nodes: nodes)
        #expect(address?.contains("\n") == false)
    }
}
