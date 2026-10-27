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
@testable import K3smStatus

func maskNode(_ name: String, server: Bool = false) -> ClusterNode {
    ClusterNode(name: name, ready: true, controlPlane: server)
}

/// The demo recording's node name mask: the mapping, its application to a
/// name, a pod row, an address and free text, and the launch option. The
/// tests pass the mapping in; none turns the process's mask on, which would
/// change what every other test renders.
@Suite("the demo node name mask")
struct NodeNameMaskTests {
    @Test("the control-plane node is server and the others worker-n in name order",
          arguments: [
              // One control-plane node and two workers listed out of order.
              ([maskNode("zeta"), maskNode("main", server: true), maskNode("alpha")],
               ["main": "server", "alpha": "worker-1", "zeta": "worker-2"]),
              // No control-plane node: every node is a worker.
              ([maskNode("b"), maskNode("a"), maskNode("c")],
               ["a": "worker-1", "b": "worker-2", "c": "worker-3"]),
              // A second control-plane node, in name order.
              ([maskNode("cp-b", server: true), maskNode("cp-a", server: true), maskNode("w")],
               ["cp-a": "server", "cp-b": "server-2", "w": "worker-1"]),
              ([], [:]),
          ] as [([ClusterNode], [String: String])])
    func mapping(nodes: [ClusterNode], want: [String: String]) {
        #expect(NodeNameMask.make(nodes: nodes) == want)
    }

    @Test("a name the node list did not carry is node, never itself")
    func unknownName() {
        let mask = NodeNameMask.make(nodes: [maskNode("main", server: true)])
        #expect(NodeNameMask.apply(mask, to: "main") == "server")
        #expect(NodeNameMask.apply(mask, to: "other") == NodeNameMask.unknown)
        #expect(NodeNameMask.shown("other", mask: [:]) == "node")
        #expect(NodeNameMask.shown("other", mask: nil) == "other")
    }

    @Test("a pod row's node column shows the masked name; this Mac and unscheduled stay")
    func podRow() {
        let mask = NodeNameMask.make(nodes: [maskNode("main", server: true), maskNode("laptop")])
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "laptop"), ownNode: nil, mask: mask) == .node("worker-1"))
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "main"), ownNode: nil, mask: mask) == .node("server"))
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "main"), ownNode: "main", mask: mask) == .thisMac)
        #expect(WorkloadsDisplay.nodeLabel(testPod("p"), ownNode: nil, mask: mask) == .unscheduled)
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "laptop"), ownNode: nil, mask: nil) == .node("laptop"))
    }

    @Test("an address equal to a node's name masks; an IP address does not",
          arguments: [
              ("k3sm-main", "server"),
              ("k3sm-laptop", "worker-1"),
              ("100.64.0.1", "100.64.0.1"),
              ("192.0.2.7", "192.0.2.7"),
              ("k3sm-main.local", "k3sm-main.local"),
          ])
    func address(address: String, want: String) {
        let mask = NodeNameMask.make(nodes: [maskNode("k3sm-main", server: true), maskNode("k3sm-laptop")])
        #expect(NodeNameMask.apply(mask, toAddress: address) == want)
    }

    @Test("free text masks a node name only where it stands as a whole word",
          arguments: [
              ("Successfully assigned default/web-1 to k3sm-laptop", "Successfully assigned default/web-1 to worker-1"),
              ("Node k3sm-main", "Node server"),
              ("k3sm-main and k3sm-main.", "server and server."),
              ("k3sm-mainline k3sm-main-2 xk3sm-main", "k3sm-mainline k3sm-main-2 xk3sm-main"),
              ("nothing here", "nothing here"),
          ])
    func text(text: String, want: String) {
        let mask = NodeNameMask.make(nodes: [maskNode("k3sm-main", server: true), maskNode("k3sm-laptop")])
        #expect(NodeNameMask.apply(mask, toText: text) == want)
    }

    @Test("a longer name is replaced whole before a shorter one inside it")
    func overlapping() {
        let mask = NodeNameMask.make(nodes: [maskNode("mac", server: true), maskNode("mac-2")])
        #expect(NodeNameMask.apply(mask, toText: "mac-2 and mac") == "worker-1 and server")
    }

    @Test("--demo-mask is honoured only beside --demo-tour")
    func launch() throws {
        #expect(try NodeNameMask.requested(in: ["k3sm-app"]) == false)
        #expect(try NodeNameMask.requested(in: ["k3sm-app", "--demo-tour", "release-tour"]) == false)
        #expect(try NodeNameMask.requested(in: ["k3sm-app", "--demo-tour", "release-tour", "--demo-mask"]) == true)
        #expect(try NodeNameMask.requested(in: ["k3sm-app", "--demo-mask", "--demo-tour", "release-tour"]) == true)
        #expect(throws: NodeNameMask.LaunchError.withoutTour) { try NodeNameMask.requested(in: ["k3sm-app", "--demo-mask"]) }
        #expect(throws: NodeNameMask.LaunchError.withoutTour) { try NodeNameMask.requested(in: ["--demo-tour", "--demo-mask"]) }
        #expect(NodeNameMask.LaunchError.withoutTour.message == "--demo-mask needs --demo-tour")
    }
}
