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

/// The one update plan (`UpdatePlan`) every Update control reads.
@Suite("the single update plan")
struct UpdatePlanTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let v018 = SemanticVersion("0.1.8")!
    static let v019 = SemanticVersion("0.1.9")!

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let facts: UpdatePlanFacts
        let plan: UpdatePlan
        var testDescription: String { name }
    }

    static func facts(_ role: NodeRole?, installed: SemanticVersion? = v017, payload: SemanticVersion? = v017,
                      managed: ManagedUpdateState = .nothingNewer, workers: Int? = nil, controlPlane: SemanticVersion? = nil,
                      joinTarget: Bool = true, developerBuild: Bool = false, refusal: String? = nil,
                      managedRefusal: String? = nil) -> UpdatePlanFacts {
        UpdatePlanFacts(role: role, installed: installed, payload: payload, managed: managed, workers: workers,
                        controlPlane: controlPlane, joinTargetReadable: joinTarget, developerBuild: developerBuild,
                        refusal: refusal, managedRefusal: managedRefusal)
    }

    static let cases: [Case] = [
        // Current.
        Case(name: "a single node on the app's release", facts: facts(.server, workers: 0), plan: .none),
        Case(name: "a server on the latest release", facts: facts(.server, workers: 2), plan: .none),
        Case(name: "a worker on the server's release", facts: facts(.agent, controlPlane: v017), plan: .none),
        Case(name: "a worker with no node list read", facts: facts(.agent), plan: .none),
        // This Mac from the app's payload.
        Case(name: "a single node behind the app", facts: facts(.server, payload: v018, workers: 0), plan: .payload(v018)),
        Case(name: "a single node behind the app, the latest newer still",
             facts: facts(.server, payload: v018, managed: .behind(tag: "v0.1.9"), workers: 0), plan: .payload(v018)),
        Case(name: "a worker behind the app", facts: facts(.agent, payload: v018, controlPlane: v018), plan: .payload(v018)),
        Case(name: "a worker behind the app, ahead of the server", facts: facts(.agent, payload: v018, controlPlane: v017),
             plan: .payload(v018)),
        // The managed cluster roll.
        Case(name: "a server with workers behind the latest", facts: facts(.server, managed: .behind(tag: "v0.1.8"), workers: 1),
             plan: .managed(tag: "v0.1.8")),
        Case(name: "a server with workers, the app newer too",
             facts: facts(.server, payload: v018, managed: .behind(tag: "v0.1.9"), workers: 1), plan: .managed(tag: "v0.1.9")),
        Case(name: "a server with no worker list, behind the latest", facts: facts(.server, managed: .behind(tag: "v0.1.8")),
             plan: .managed(tag: "v0.1.8")),
        Case(name: "a single node on the app's release, behind the latest",
             facts: facts(.server, managed: .behind(tag: "v0.1.8"), workers: 0), plan: .managed(tag: "v0.1.8")),
        Case(name: "a server running a developer build, behind the latest",
             facts: facts(.server, installed: nil, managed: .behind(tag: "v0.1.8"), workers: 1), plan: .managed(tag: "v0.1.8")),
        Case(name: "a server whose app is older, behind the latest",
             facts: facts(.server, installed: v018, payload: v017, managed: .behind(tag: "v0.1.9"), workers: 1),
             plan: .managed(tag: "v0.1.9")),
        // The managed roll in progress.
        Case(name: "a roll in progress on the server", facts: facts(.server, payload: v018, managed: .rolling, workers: 0),
             plan: .rolling),
        Case(name: "a roll in progress, the role unknown", facts: facts(nil, managed: .rolling), plan: .rolling),
        Case(name: "a roll in progress in a developer build", facts: facts(.server, managed: .rolling, developerBuild: true),
             plan: .rolling),
        // Blocked, with the sentence.
        Case(name: "the role unknown", facts: facts(nil, payload: v018), plan: .blocked(.roleUnknown)),
        Case(name: "a developer build of the app, the roll offered",
             facts: facts(.server, managed: .behind(tag: "v0.1.8"), workers: 1, developerBuild: true),
             plan: .blocked(.appDeveloperBuild(.managed(tag: "v0.1.8")))),
        Case(name: "a developer build of the app, the payload offered",
             facts: facts(.agent, payload: v018, developerBuild: true), plan: .blocked(.appDeveloperBuild(.payload(v018)))),
        Case(name: "an installed developer build, nothing else to go on", facts: facts(.agent, installed: nil, payload: v018),
             plan: .blocked(.installedUnknown)),
        Case(name: "a worker behind the server, no newer payload", facts: facts(.agent, controlPlane: v018),
             plan: .blocked(.workerBehind)),
        Case(name: "a worker behind the server, the app older still",
             facts: facts(.agent, installed: v018, payload: v017, controlPlane: v019), plan: .blocked(.workerBehind)),
        Case(name: "a downgrade on a worker", facts: facts(.agent, installed: v018, payload: v017, controlPlane: v018),
             plan: .blocked(.downgrade(installed: v018, payload: v017))),
        Case(name: "a downgrade on a single node", facts: facts(.server, installed: v018, payload: v017, workers: 0),
             plan: .blocked(.downgrade(installed: v018, payload: v017))),
        Case(name: "a control plane with workers, the app newer, no newer latest",
             facts: facts(.server, payload: v018, workers: 2), plan: .blocked(.controlPlaneWithWorkers(payload: v018))),
        Case(name: "a control plane with no worker list, the app newer",
             facts: facts(.server, payload: v018), plan: .blocked(.controlPlaneWithWorkers(payload: v018))),
        Case(name: "another change runs", facts: facts(.agent, payload: v018, refusal: "Another change is running."),
             plan: .blocked(.refused("Another change is running.", .payload(v018)))),
        Case(name: "the installed CLI refused, the roll offered",
             facts: facts(.server, managed: .behind(tag: "v0.1.8"), workers: 1, managedRefusal: "Untrusted."),
             plan: .blocked(.refused("Untrusted.", .managed(tag: "v0.1.8")))),
        Case(name: "the installed CLI refused, the payload offered",
             facts: facts(.server, payload: v018, workers: 0, managedRefusal: "Untrusted."), plan: .payload(v018)),
        Case(name: "a worker whose join target failed to read", facts: facts(.agent, payload: v018, joinTarget: false),
             plan: .blocked(.joinTargetUnknown(v018))),
    ]

    @Test("one plan decides which update applies, from the role, the versions and the managed state", arguments: cases)
    func singleUpdatePlan(_ c: Case) {
        let plan = UpdatePlan.decide(c.facts)
        #expect(plan == c.plan)
        // Every control reads the same plan: a title only with a path or a
        // roll, enabled only for a path that can run, a reason for every
        // disabled one, and one line that never contradicts them.
        switch plan {
        case .payload, .managed:
            #expect(plan.isEnabled && plan.disabledReason == nil)
            #expect(plan.menuTitle != nil && plan.buttonTitle == "Update")
            #expect(plan.line == plan.path?.sentence)
        case .rolling:
            #expect(!plan.isEnabled && plan.menuTitle == "Updating…" && plan.buttonTitle == "Updating…")
            #expect(plan.disabledReason == UpdatePlan.rollingReason)
        case .blocked(let block):
            #expect(!plan.isEnabled)
            #expect(plan.disabledReason == block.sentence && plan.line == block.sentence)
            #expect((plan.menuTitle != nil) == (block.path != nil))
            #expect(!block.sentence.isEmpty && block.sentence.hasSuffix("."))
        case .none:
            #expect(!plan.isEnabled && plan.menuTitle == nil && plan.buttonTitle == nil && plan.line == nil)
        }
        let help = Help.Strip.update(plan)
        #expect(help == (plan.disabledReason ?? help))
    }

    @Test("the facts come from the report, the progress and the node list")
    func factsFromTheReads() {
        let behind = StatusRow(name: "update", state: "behind", detail: "k3sm v0.1.8 is available; behind: mac-b",
                               wide: ["latest": "v0.1.8"])
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "",
                                  rows: [StatusRow(name: "server", state: "running", detail: ""), behind],
                                  workers: [StatusWorker(name: "mac-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")])
        let nodes = [ClusterNode(name: "mac-a", ready: true, kubeletVersion: "v1.36.2+k3sm.0.1.8", controlPlane: true),
                     ClusterNode(name: "mac-b", ready: true, kubeletVersion: "v1.36.2+k3sm.0.1.7", controlPlane: false)]
        let facts = UpdatePlanFacts(report: report, progress: UpdateProgress(), installed: Self.v018, payload: Self.v018,
                                    nodes: nodes, joinTargetReadable: true, developerBuild: false, refusal: nil, managedRefusal: nil)
        #expect(facts.role == .server && facts.workers == 1 && facts.controlPlane == Self.v018)
        #expect(facts.managed == .behind(tag: "v0.1.8"))
        #expect(UpdatePlan.decide(facts) == .managed(tag: "v0.1.8"))
        // A roll the app follows wins over the row.
        var progress = UpdateProgress()
        progress.applyStarted()
        #expect(ManagedUpdateState(report: report, progress: progress) == .rolling)
        #expect(ManagedUpdateState(report: nil, progress: UpdateProgress()) == .nothingNewer)
    }

    @Test("each path says what it does, and the menu names its release")
    func pathText() {
        #expect(UpdatePath.payload(Self.v018).menuTitle == "Update This Mac to 0.1.8…")
        #expect(UpdatePath.managed(tag: "v0.1.9").menuTitle == "Update to v0.1.9…")
        #expect(UpdatePath.managed(tag: "v0.1.9").sentence == "The update moves every node to k3sm v0.1.9, the server last.")
        #expect(UpdateBlock.appDeveloperBuild(.managed(tag: "v0.1.9")).sentence == UpdateOffer.developerBuildReason)
        #expect(UpdateBlock.downgrade(installed: Self.v018, payload: Self.v017).sentence
            == "This Mac runs k3sm 0.1.8, newer than the 0.1.7 this app carries, and the app never installs an older k3sm.")
    }
}
