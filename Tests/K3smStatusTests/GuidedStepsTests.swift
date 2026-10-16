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

@Suite("guided steps")
struct GuidedStepsTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let v018 = SemanticVersion("0.1.8")!
    static let byUser = StoppedBy(actor: "user", reason: "", at: "2026-10-16T10:00:00Z", phase: "stopped")

    /// The name of a state's case. The switch is exhaustive, so a new
    /// `HealthState` case fails to compile here until the table covers it.
    static func caseName(_ state: HealthState) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .installedStopped: return "installedStopped"
        case .partlyRunning: return "partlyRunning"
        case .cliMissing: return "cliMissing"
        case .cliUntrusted: return "cliUntrusted"
        case .statusUnreadable: return "statusUnreadable"
        case .versionMismatch(_, _, let relation): return relation == .older ? "ahead" : "behind"
        case .healthy: return "healthy"
        }
    }

    static let allCaseNames: Set<String> = [
        "notInstalled", "installedStopped", "partlyRunning", "cliMissing", "cliUntrusted",
        "statusUnreadable", "behind", "ahead", "healthy",
    ]

    struct Row {
        let name: String
        let state: HealthState
        let role: NodeRole?
        /// The primary with the root step, then in a developer build.
        let primary: GuidedAction?
        let devPrimary: GuidedAction?
        /// The Terminal command with the root step, then in a developer build.
        let command: String?
        let devCommand: String?
        let opensLogs: Bool
    }

    static let pinned = "curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.8 sh"

    static let table: [Row] = [
        Row(name: "stopped by the user", state: .installedStopped(byUser), role: .server,
            primary: .start, devPrimary: nil, command: nil, devCommand: "sudo k3sm start", opensLogs: false),
        Row(name: "stopped, no record", state: .installedStopped(nil), role: .agent,
            primary: .start, devPrimary: nil, command: nil, devCommand: "sudo k3sm start", opensLogs: false),
        Row(name: "netd down under a running node", state: .partlyRunning(down: ["io.k3sm.netd"]), role: .server,
            primary: .restart, devPrimary: nil, command: nil, devCommand: "sudo k3sm restart", opensLogs: false),
        Row(name: "the node daemon down beside netd", state: .partlyRunning(down: ["io.k3sm.server"]), role: .server,
            primary: .start, devPrimary: nil, command: nil, devCommand: "sudo k3sm start", opensLogs: false),
        Row(name: "behind the app on the control plane", state: .versionMismatch(payload: v018, installed: v017, relation: .newer), role: .server,
            primary: .update, devPrimary: nil, command: nil, devCommand: pinned, opensLogs: false),
        Row(name: "behind the app on a worker", state: .versionMismatch(payload: v018, installed: v017, relation: .newer), role: .agent,
            primary: .update, devPrimary: nil, command: nil, devCommand: "sudo k3sm update apply", opensLogs: false),
        Row(name: "behind with no report", state: .versionMismatch(payload: v018, installed: v017, relation: .newer), role: nil,
            primary: .update, devPrimary: nil, command: nil, devCommand: pinned, opensLogs: false),
        Row(name: "ahead of the app", state: .versionMismatch(payload: v017, installed: v018, relation: .older), role: .server,
            primary: nil, devPrimary: nil, command: nil, devCommand: nil, opensLogs: false),
        Row(name: "the command missing", state: .cliMissing, role: nil,
            primary: .repair, devPrimary: nil, command: nil, devCommand: pinned, opensLogs: false),
        Row(name: "the command untrusted", state: .cliUntrusted("/Library/k3sm/k3sm is a symlink"), role: nil,
            primary: .repair, devPrimary: nil, command: nil, devCommand: pinned, opensLogs: false),
        Row(name: "status unreadable", state: .statusUnreadable, role: .server,
            primary: .refresh, devPrimary: .refresh, command: nil, devCommand: nil, opensLogs: true),
    ]

    @Test("every health state maps to its guided steps, with and without the root step")
    func guidedStepsForEveryHealthState() {
        // Every case is in the table, or is one of the two with no plan.
        let covered = Set(Self.table.map { Self.caseName($0.state) }).union(["notInstalled", "healthy"])
        #expect(covered == Self.allCaseNames)

        for state in [HealthState.notInstalled, .healthy] {
            for root in [true, false] {
                #expect(GuidedSteps.plan(for: state, rootStep: root, role: .server, payload: Self.v018) == nil)
            }
        }

        for row in Self.table {
            for root in [true, false] {
                let label = "\(row.name), root step \(root)"
                guard let plan = GuidedSteps.plan(for: row.state, rootStep: root, role: row.role, payload: Self.v018) else {
                    Issue.record("\(label): no plan")
                    continue
                }
                #expect(plan.state == row.state, "\(label)")
                #expect(plan.banner == row.state.line, "\(label): the banner is the state's own line")
                #expect(!plan.bannerButton.isEmpty, "\(label)")
                #expect((2...5).contains(plan.steps.count), "\(label): a short step list")
                #expect(plan.steps.allSatisfy { !$0.isEmpty && $0.hasSuffix(".") }, "\(label): each step a sentence")
                #expect(plan.primary == (root ? row.primary : row.devPrimary), "\(label): primary")
                #expect(plan.terminalCommand == (root ? row.command : row.devCommand), "\(label): Terminal command")
                #expect(plan.opensLogs == row.opensLogs, "\(label): Open Logs")
                // A developer build never shows a button that needs the root
                // step; it shows the command to run instead.
                if !root {
                    #expect(plan.primary?.needsRootStep != true, "\(label): a dead button")
                }
                // Every plan leaves the user something to do or read.
                let ahead = row.state == .versionMismatch(payload: Self.v017, installed: Self.v018, relation: .older)
                #expect(plan.primary != nil || plan.terminalCommand != nil || ahead, "\(label): no next step")
                // A command run in Terminal is followed by Refresh.
                if plan.terminalCommand != nil {
                    #expect(plan.offersRefresh, "\(label): Refresh after Terminal")
                }
                // Repair is offered, first or beside the primary, exactly
                // for the half-installed states, and only with the root step.
                let offersRepair = plan.primary == .repair || plan.secondary == .repair
                #expect(offersRepair == (root && row.state.repairable), "\(label): Repair offered")
                #expect(plan.secondary != plan.primary || plan.secondary == nil, "\(label)")
                if !root {
                    #expect(plan.secondary == nil, "\(label): a dead second button")
                }
            }
        }
    }

    @Test("Repair replaces the Terminal fallback for a missing or untrusted command")
    func repairReplacesTerminal() throws {
        for state in [HealthState.cliMissing, .cliUntrusted("not owned by root")] {
            let plan = try #require(GuidedSteps.plan(for: state, rootStep: true, role: nil, payload: Self.v018))
            #expect(plan.primary == .repair)
            #expect(plan.terminalCommand == nil)
            #expect(plan.bannerButton == "Repair k3sm…")
            #expect(plan.steps.contains(GuidedSteps.repairWhatLine))
            // Without the release the app carries there is nothing to repair
            // from: the install script again.
            let unknown = try #require(GuidedSteps.plan(for: state, rootStep: true, role: nil, payload: nil))
            #expect(unknown.primary == nil)
            #expect(unknown.terminalCommand == GuidedSteps.installScriptCommand(version: nil))
        }
        for down in [["io.k3sm.netd"], ["io.k3sm.server"]] {
            let plan = try #require(GuidedSteps.plan(for: .partlyRunning(down: down), rootStep: true, role: .server, payload: Self.v018))
            #expect(plan.primary == GuidedSteps.partlyRunningAction(down: down))
            #expect(plan.secondary == .repair)
            #expect(plan.steps.last == GuidedSteps.repairBesideLine)
            let noPayload = try #require(GuidedSteps.plan(for: .partlyRunning(down: down), rootStep: true, role: .server, payload: nil))
            #expect(noPayload.secondary == nil)
        }
    }

    @Test("ahead of the app offers nothing destructive")
    func aheadOffersNothing() throws {
        let plan = try #require(GuidedSteps.plan(for: .versionMismatch(payload: Self.v017, installed: Self.v018, relation: .older),
                                                 rootStep: true, role: .server, payload: Self.v017))
        #expect(plan.primary == nil)
        #expect(plan.terminalCommand == nil)
        #expect(plan.steps.joined(separator: " ").contains("0.1.8"))
        #expect(plan.steps.joined(separator: " ").contains("never installs an older"))
    }

    @Test("the install script pins the app's release, or runs unpinned when it is unknown")
    func installScriptCommand() {
        #expect(GuidedSteps.installScriptCommand(version: Self.v018) == Self.pinned)
        #expect(GuidedSteps.installScriptCommand(version: nil) == "curl -fsSL https://k3sm.io/install.sh | sh")
        let plan = GuidedSteps.plan(for: .cliMissing, rootStep: true, role: nil, payload: nil)
        #expect(plan?.terminalCommand == "curl -fsSL https://k3sm.io/install.sh | sh")
    }

    @Test("a refusal's reason reaches the steps clipped to one line")
    func untrustedReasonIsClipped() throws {
        let hostile = "bad\nline\u{202E}" + String(repeating: "x", count: 400)
        let plan = try #require(GuidedSteps.plan(for: .cliUntrusted(hostile), rootStep: true, role: nil, payload: Self.v018))
        #expect(plan.steps.allSatisfy { !$0.contains("\n") && !$0.contains("\u{202E}") })
        #expect(!plan.banner.contains("\n"))
    }

    @Test("a finished step ends on a plain success or failure line with its message")
    func finishedLine() {
        #expect(GuidedRun.idle.line == nil)
        #expect(GuidedRun.running(.start).line == nil)
        #expect(GuidedRun.running(.start).isRunning)
        #expect(GuidedRun.finished(.start, succeeded: true, message: "k3sm is starting.").line == "Done: k3sm is starting.")
        #expect(GuidedRun.finished(.restart, succeeded: false, message: "k3sm restart failed with exit status 1.\nThe logs say why.").line
                == "Failed: k3sm restart failed with exit status 1. The logs say why.")
        #expect(GuidedRun.finished(.refresh, succeeded: false, message: "").line == "Failed.")
    }

    @Test("each update block says why Update waits")
    func updateBlocks() {
        let blocks: [GuidedUpdateBlock] = [.unknown, .waitForWorkers(["mac-b", "evil\u{202E}"]), .confirmWorkers, .joinTargetUnknown, .notNewer]
        for block in blocks {
            #expect(block.text.hasSuffix("."), "\(block)")
        }
        #expect(GuidedUpdateBlock.waitForWorkers(["mac-b", "evil\u{202E}"]).text == "Update these workers first: mac-b, evil.")
    }
}
