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

/// The roll to the version set this app carries (`UpdatePlan.bundled`): the
/// relaunch question's table, its preconditions, where it sits in the plan's
/// order, and the presenter over it (`VersionSetOffer`).
@Suite("the bundled version-set offer")
struct BundledOfferTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let v018 = SemanticVersion("0.1.8")!
    static let v019 = SemanticVersion("0.1.9")!

    static func worker(_ name: String = "node-b", on release: String = "0.1.8") -> StatusWorker {
        StatusWorker(name: name, role: "agent", version: "v1.36.2+k3sm.\(release)")
    }

    /// A server's report: its k3sm's release, its own Node `my-mac` with
    /// `kubelet` (no `node` row when nil), the other nodes and extra rows.
    static func report(release: String = "v0.1.8", kubelet: String? = "v1.36.2+k3sm.0.1.8",
                       workers: [StatusWorker]? = [worker()], role: String = "server", rows extra: [StatusRow] = []) -> StatusReport {
        var rows = [StatusRow(name: role, state: "running", detail: "d")]
        if let kubelet { rows.append(StatusRow(name: "node", state: "ready", detail: "d", wide: ["node": "my-mac", "kubelet": kubelet])) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "s", rows: rows + extra,
                            workers: workers, release: StatusRelease(text: release))
    }

    /// The node list: `my-mac` and each named node, Ready unless listed in `notReady`.
    static func nodes(_ names: [String] = ["node-b"], notReady: Set<String> = []) -> [ClusterNode] {
        (["my-mac"] + names).map { ClusterNode(name: $0, ready: notReady.contains($0) ? false : true, controlPlane: $0 == "my-mac") }
    }

    static func facts(_ report: StatusReport? = report(), nodes: [ClusterNode]? = nodes(), installed: SemanticVersion? = v018,
                      payloadTag: String? = "v0.1.9", payload: SemanticVersion? = nil, record: Bool = true, developerBuild: Bool = false,
                      refusal: String? = nil, managedRefusal: String? = nil) -> UpdatePlanFacts {
        UpdatePlanFacts(report: report, progress: UpdateProgress(), installed: installed,
                        payload: payload ?? payloadTag.flatMap(SemanticVersion.init), nodes: nodes, joinTargetReadable: true,
                        developerBuild: developerBuild, refusal: refusal, managedRefusal: managedRefusal,
                        payloadTag: payloadTag, payloadRecord: record)
    }

    static let behindRow = StatusRow(name: "update", state: "behind", detail: "k3sm v0.1.9 is available", wide: ["latest": "v0.1.9"])

    @Test("a node that is not Ready refuses the bundled offer, and the question is not asked")
    func bundledOfferRefusedWhileNodeNotReady() {
        let ready = UpdatePlan.decide(Self.facts())
        #expect(ready == .bundled(tag: "v0.1.9"))
        let facts = Self.facts(nodes: Self.nodes(notReady: ["node-b"]))
        let plan = UpdatePlan.decide(facts)
        #expect(plan == .blocked(.bundledNodeNotReady(["node-b"])))
        #expect(!plan.isEnabled)
        #expect(plan.disabledReason == "node-b is not Ready, so the cluster cannot update to this app's release now. Update it once every node is Ready.")
        #expect(VersionSetOffer.decide(facts: facts, updatedFrom: "v0.1.8", answeredTag: nil) == nil)
        // The server's own node counts too, and a node with no Ready
        // condition is not Ready.
        let own = UpdatePlan.decide(Self.facts(nodes: Self.nodes(notReady: ["my-mac"])))
        #expect(own == .blocked(.bundledNodeNotReady(["my-mac"])))
        let silent = [ClusterNode(name: "my-mac", ready: true), ClusterNode(name: "node-b", ready: nil)]
        #expect(UpdatePlan.decide(Self.facts(nodes: silent)) == .blocked(.bundledNodeNotReady(["node-b"])))
        // The managed roll to the same tag is not offered in its place.
        let behind = Self.facts(Self.report(rows: [Self.behindRow]), nodes: Self.nodes(notReady: ["node-b"]))
        #expect(UpdatePlan.decide(behind) == .blocked(.bundledNodeNotReady(["node-b"])))
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let facts: UpdatePlanFacts
        let plan: UpdatePlan
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // The relaunch question's table, row by row.
        Case(name: "a single-node server, installed older than the set: the app-carried install",
             facts: facts(report(workers: [])), plan: .payload(v019)),
        Case(name: "a multi-node server, every node at or below the set, one below: the bundled roll",
             facts: facts(), plan: .bundled(tag: "v0.1.9")),
        Case(name: "a worker: the app-carried install on this Mac",
             facts: facts(report(role: "agent")), plan: .payload(v019)),
        Case(name: "the cluster already on the set: nothing",
             facts: facts(report(release: "v0.1.9", kubelet: "v1.36.2+k3sm.0.1.9", workers: [worker(on: "0.1.9")]), installed: v019),
             plan: .none),
        Case(name: "a roll running: nothing new",
             facts: facts(report(rows: [StatusRow(name: "update", state: "rolling", detail: "rolling")])), plan: .rolling),
        // The preconditions.
        Case(name: "two minor releases apart: no offer, the intermediate release named",
             facts: facts(payloadTag: "v0.3.0"), plan: .blocked(.bundledSkewTooWide(installed: v018, set: SemanticVersion("0.3.0")!))),
        Case(name: "a major release apart: no offer",
             facts: facts(payloadTag: "v1.0.0"), plan: .blocked(.bundledSkewTooWide(installed: v018, set: SemanticVersion("1.0.0")!))),
        Case(name: "the installed CLI without the pin: no offer, the Terminal command named",
             facts: facts(report(release: "v0.1.7", kubelet: "v1.36.2+k3sm.0.1.7", workers: [worker(on: "0.1.7")]), installed: v017),
             plan: .blocked(.bundledServerCLITooOld(installed: v017, tag: "v0.1.9"))),
        Case(name: "the installed CLI without the pin, the latest offered: today's managed roll",
             facts: facts(report(release: "v0.1.7", kubelet: "v1.36.2+k3sm.0.1.7", workers: [worker(on: "0.1.7")], rows: [behindRow]),
                          installed: v017),
             plan: .managed(tag: "v0.1.9")),
        Case(name: "the running controller without the pin: no offer; today's catch-up moves the server to its installed release",
             facts: facts(report(kubelet: "v1.36.2+k3sm.0.1.7")), plan: .catchUp(tag: "v0.1.8", nodes: ["my-mac"])),
        Case(name: "the server's own node not reported",
             facts: facts(report(kubelet: nil)), plan: .blocked(.serverNodeUnknown)),
        Case(name: "a node ahead of the set",
             facts: facts(report(workers: [worker(on: "0.2.0")])), plan: .blocked(.nodesAhead(tag: "v0.1.9", nodes: ["node-b"]))),
        Case(name: "the node list not read", facts: facts(nodes: nil), plan: .blocked(.bundledNodesUnknown)),
        Case(name: "the report lists no other nodes", facts: facts(report(workers: nil)), plan: .blocked(.bundledNodesUnknown)),
        Case(name: "a developer build", facts: facts(developerBuild: true), plan: .blocked(.appDeveloperBuild(.bundled(tag: "v0.1.9")))),
        Case(name: "another change runs", facts: facts(refusal: "Another change is running."),
             plan: .blocked(.refused("Another change is running.", .bundled(tag: "v0.1.9")))),
        Case(name: "the installed CLI failed its trust check", facts: facts(managedRefusal: "Untrusted."),
             plan: .blocked(.refused("Untrusted.", .bundled(tag: "v0.1.9")))),
        Case(name: "no payload record in the bundle", facts: facts(record: false), plan: .blocked(.bundledNoPayloadRecord)),
        Case(name: "no payload tag: today's block", facts: facts(payloadTag: nil, payload: v019),
             plan: .blocked(.controlPlaneWithWorkers(payload: v019))),
        Case(name: "a release candidate set", facts: facts(payloadTag: "v0.1.9-rc.1"), plan: .bundled(tag: "v0.1.9-rc.1")),
        // The order rule.
        Case(name: "the managed row names the same tag: the pinned path wins",
             facts: facts(report(rows: [behindRow])), plan: .bundled(tag: "v0.1.9")),
        Case(name: "a worker behind the server: the set, not the catch-up to the server's release",
             facts: facts(report(workers: [worker(on: "0.1.7")])), plan: .bundled(tag: "v0.1.9")),
        Case(name: "the managed row names a newer release: still the set the app carries",
             facts: facts(report(rows: [StatusRow(name: "update", state: "behind", detail: "d", wide: ["latest": "v0.2.0"])])),
             plan: .bundled(tag: "v0.1.9")),
    ]

    @Test("the bundled offer's table, preconditions and order", arguments: cases)
    func bundledPlan(_ c: Case) {
        let plan = UpdatePlan.decide(c.facts)
        #expect(plan == c.plan)
        if case .blocked(let block) = plan {
            #expect(!block.sentence.isEmpty && block.sentence.hasSuffix("."))
        }
    }

    @Test("the bundled path's titles and sentences")
    func bundledText() {
        let path = UpdatePath.bundled(tag: "v0.1.9")
        #expect(path.menuTitle == "Update the Cluster to v0.1.9…")
        #expect(path.sentence == "The update moves every node to k3sm v0.1.9, the release this app carries. Workers first, this server last.")
        let plan = UpdatePlan.bundled(tag: "v0.1.9")
        #expect(plan.isEnabled && plan.disabledReason == nil && plan.path == path && plan.line == path.sentence)
        #expect(UpdateBlock.bundledServerCLITooOld(installed: Self.v017, tag: "v0.1.9").sentence.contains("`sudo k3sm update apply --version v0.1.9`"))
        #expect(UpdateBlock.bundledControllerTooOld(tag: "v0.1.9").sentence.contains("`sudo k3sm update apply --version v0.1.9`"))
        #expect(UpdateBlock.bundledSkewTooWide(installed: Self.v018, set: SemanticVersion("0.3.0")!).sentence.contains("a v0.2 release first"))
        #expect(Help.Strip.update(plan) == "Update every node to k3sm v0.1.9, this app's release, the server last")
    }

    @Test("the pin and skew rules")
    func support() {
        #expect(BundledRollSupport.lastReleaseWithoutPin == Self.v017)
        #expect(BundledRollSupport.skewAllowed(installed: Self.v018, set: Self.v019))
        #expect(BundledRollSupport.skewAllowed(installed: Self.v018, set: SemanticVersion("0.2.5")!))
        #expect(!BundledRollSupport.skewAllowed(installed: Self.v018, set: SemanticVersion("0.3.0")!))
        #expect(!BundledRollSupport.skewAllowed(installed: Self.v018, set: SemanticVersion("1.0.0")!))
    }

    @Test("only an exact release tag above 0.1.7 has the pin", arguments: [
        ("v0.1.8", true), ("v0.1.8-rc.1", true), ("v0.2.0", true), ("v1.0.0", true),
        ("v0.1.7", false), ("v0.1.7-rc.3", false), ("v0.0.1", false),
        // A pre-release outside the strict grammar.
        ("v0.1.8-beta.1", false), ("v0.1.8-rc.1.2", false), ("v0.1.8-rc", false),
        // git describe, a modified tree, a developer build.
        ("v0.1.8-3-gabcdef1", false), ("v0.1.8-3-gabcdef1-dirty", false), ("v0.1.8+dirty", false), ("v0.1.8.dirty", false),
        ("v0.0.0-0.20261016221530-2eda966a1b2c", false), ("dev", false),
        // Unparseable, or not a tag at all.
        ("0.1.8", false), ("v0.1", false), ("garbage", false), ("", false),
    ])
    func pinRequiresAnExactTag(_ tag: String, _ pinned: Bool) {
        #expect(BundledRollSupport.hasPin(tag: tag) == pinned)
    }

    static let notATag = ["v0.1.8-beta.1", "v0.1.8-3-gabcdef1", "v0.1.8-3-gabcdef1-dirty", "v0.0.0-0.20261016221530-2eda966a1b2c", "dev", "garbage"]

    @Test("an installed CLI whose version is not an exact release tag counts as no pin", arguments: notATag)
    func installedNotATag(_ text: String) {
        #expect(!BundledRollSupport.hasPin(tag: nil))
        let plan = UpdatePlan.decide(Self.facts(Self.report(release: text)))
        #expect(plan == .blocked(.bundledServerCLITooOld(installed: Self.v018, tag: "v0.1.9")), "\(plan)")
        // A modified tree's build of a release tag too.
        let dirty = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: Self.report().rows,
                                 workers: [Self.worker()], release: StatusRelease(text: "v0.1.8", dirty: true))
        #expect(UpdatePlan.decide(Self.facts(dirty)) == .blocked(.bundledServerCLITooOld(installed: Self.v018, tag: "v0.1.9")))
    }

    @Test("a running controller whose release is not an exact release tag counts as no pin", arguments: [
        "0.1.8.dirty", "0.1.8-3-gabcdef1", "0.1.8-beta.1", "0.0.0-0.20261016221530-2eda966a1b2c", "dev", "garbage",
    ])
    func controllerNotATag(_ part: String) {
        let facts = Self.facts(Self.report(kubelet: "v1.36.2+k3sm.\(part)"))
        #expect(UpdatePlan.bundledStep(facts) == .fallback(.bundledControllerTooOld(tag: "v0.1.9")))
        // No bundled offer: the plan goes on as before (a pre-release of the
        // installed release reads as behind it, so today's catch-up moves it).
        let plan = UpdatePlan.decide(facts)
        #expect(plan.path != .bundled(tag: "v0.1.9"), "\(plan)")
    }

    @Test("the strict release tag grammar", arguments: [
        ("v0.1.9", true), ("v0.1.9-rc.1", true), ("v0.0.0", true), ("v123456789.0.1", true), ("v0.1.9-rc.0", true),
        ("v0.1.9-rc.9999", true), ("0.1.9", false), ("v0.1", false), ("v01.1.9", false), ("v0.1.9-rc.01", false),
        ("v0.1.9-rc.10000", false), ("v1234567890.0.0", false), ("v0.1.9+x", false), ("v0.1.9-beta.1", false),
        ("v0.1.9-rc", false), ("v0.1.9\n", false), ("v0.1.9 ", false), ("", false), ("v", false), ("v0.1.9-rc.1.2", false),
    ])
    func strictTag(_ tag: String, _ valid: Bool) {
        #expect(BundledRollSupport.isReleaseTag(tag) == valid)
    }

    @Test("the facts carry the payload tag, the record, readiness, the running server and the roll to the set")
    func factsFromTheReads() {
        let facts = Self.facts(nodes: Self.nodes(notReady: ["node-b"]))
        #expect(facts.payloadTag == "v0.1.9" && facts.payloadRecord)
        #expect(facts.notReady == ["node-b"])
        #expect(facts.serverRunning == "v0.1.8" && facts.installedTag == "v0.1.8")
        #expect(facts.bundledRoll?.tag == "v0.1.9" && facts.bundledRoll?.moves == ["node-b", "my-mac"])
        #expect(Self.facts(nodes: nil).notReady == nil)
        #expect(Self.facts(payloadTag: nil).bundledRoll == nil)
    }

    // MARK: the relaunch question

    @Test("the question is asked once per release after a self-update, and only for an update that can run")
    func versionSetQuestion() throws {
        let facts = Self.facts()
        let offer = try #require(VersionSetOffer.decide(facts: facts, updatedFrom: "v0.1.8", answeredTag: nil))
        #expect(offer.tag == "v0.1.9" && offer.path == .bundled(tag: "v0.1.9"))
        #expect(offer.title == "Update the cluster to v0.1.9?")
        #expect(offer.body == "This app now carries k3sm v0.1.9. Update the cluster to it? Workers first, this server last. "
            + "If you choose Not Now, the update stays in the menu and in Settings, Updates.")
        // Not after an ordinary launch, not twice for one release.
        #expect(VersionSetOffer.decide(facts: facts, updatedFrom: nil, answeredTag: nil) == nil)
        #expect(VersionSetOffer.decide(facts: facts, updatedFrom: "v0.1.8", answeredTag: "v0.1.9") == nil)
        #expect(VersionSetOffer.decide(facts: facts, updatedFrom: "v0.1.8", answeredTag: "v0.1.8") != nil)
        // The single node and the worker are asked about this Mac.
        let single = try #require(VersionSetOffer.decide(facts: Self.facts(Self.report(workers: [])), updatedFrom: "x", answeredTag: nil))
        #expect(single.title == "Update k3sm on this Mac to v0.1.9?" && single.path == .payload(Self.v019))
        let worker = try #require(VersionSetOffer.decide(facts: Self.facts(Self.report(role: "agent")), updatedFrom: "x", answeredTag: nil))
        #expect(worker.title == "Update this Mac to v0.1.9?")
        #expect(worker.body.contains("The server's app updates the rest of the cluster."))
        // Nothing for a blocked plan, a roll, nothing to do, or another path.
        #expect(VersionSetOffer.decide(facts: Self.facts(developerBuild: true), updatedFrom: "x", answeredTag: nil) == nil)
        #expect(VersionSetOffer.present(plan: .rolling, role: .server, payloadTag: "v0.1.9", updatedFrom: "x", answeredTag: nil) == nil)
        #expect(VersionSetOffer.present(plan: .none, role: .server, payloadTag: "v0.1.9", updatedFrom: "x", answeredTag: nil) == nil)
        #expect(VersionSetOffer.present(plan: .managed(tag: "v0.1.9"), role: .server, payloadTag: "v0.1.9",
                                        updatedFrom: "x", answeredTag: nil) == nil)
        // The hint's text is never shown.
        let hostile = try #require(VersionSetOffer.decide(facts: facts, updatedFrom: "evil\u{202E}text", answeredTag: nil))
        #expect(!hostile.title.contains("evil") && !hostile.body.contains("evil"))
    }

    static var offerSource: String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appending(path: "Sources/K3smStatus/VersionSetOffer.swift"), encoding: .utf8)
    }

    @Test("the presenter decides nothing: its one decision is UpdatePlan.decide")
    func presenterOnly() throws {
        let source = try #require(Self.offerSource)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n")
        var calls: [String] = []
        var rest = Substring(code)
        while let r = rest.range(of: ".decide(") {
            let before = rest[..<r.lowerBound]
            let name = before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed()
            calls.append(String(name))
            rest = rest[r.upperBound...]
        }
        #expect(calls == ["UpdatePlan"], "VersionSetOffer calls \(calls)")
        for word in ["bundledStep", "BundledRollSupport", "ClusterCatchUp", "SemanticVersion(", "facts.installed", "facts.notReady",
                     "facts.serverRunning", "facts.bundledRoll", "facts.managed", "facts.workers"] {
            #expect(!code.contains(word), "VersionSetOffer reads \(word)")
        }
    }

    @Test("the answered release is kept, Reset to Defaults too")
    func answeredTagKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "k3sm.test.\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.versionSetAnsweredTag == nil)
        preferences.versionSetAnsweredTag = "v0.1.9"
        preferences.reset()
        #expect(preferences.versionSetAnsweredTag == "v0.1.9")
    }
}
