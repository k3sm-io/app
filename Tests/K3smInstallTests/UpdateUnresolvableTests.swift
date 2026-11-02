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

import K3smStatus
@testable import K3smInstall

/// The app's Update over an installed k3sm whose entry point does not
/// resolve: it runs `install --from-staging` too, so k3sm refuses it with the
/// same recovery, and the app shows the install script and holds Update back
/// while the state is unchanged.
@Suite("update over an unresolvable install")
struct UpdateUnresolvableTests {
    static let v020 = SemanticVersion("0.2.0")!
    static let v019 = SemanticVersion("0.1.9")!
    static let refusedLog = RepairUnresolvableTests.refusedLog
    static let failed = PrivilegedOutcome.failed(exitStatus: 1)
    static let behind = HealthState.versionMismatch(payload: v020, installed: v019, relation: .newer)

    static func plan(_ action: CopyOutAction) throws -> CopyOutPlan {
        try RepairUnresolvableTests.plan(action)
    }

    @Test("update names the install script on an unresolvable install", arguments: [
        UpdateRole.server, .agent(joinServer: try! ServerAddress(parsing: "192.0.2.10")),
    ])
    func updateNamesTheInstallScriptOnAnUnresolvableInstall(_ role: UpdateRole) throws {
        let plan = try Self.plan(.update(role))
        #expect(UnresolvableInstall.refused(Self.failed, action: .update(role), log: Self.refusedLog))

        // The app's own sentence, for Update, pinned to the payload; not the
        // generic outcome, and nothing of the log's text.
        let text = OutcomeSummary.text(Self.failed, plan: plan, log: Self.refusedLog)
        #expect(text == UnresolvableInstall.sentence(for: .update(role), payload: Self.v020))
        #expect(text.contains("so Update cannot run it"))
        #expect(text.contains("curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.2.0 sh"))
        #expect(!text.contains("The log above says why"))
        #expect(!text.contains("/Library/k3sm/versions"))

        // Update is held back with that sentence while the state is the one
        // it was refused on, and Repair too where it applies.
        var mark = UnresolvableInstallMark()
        mark.rootStepFinished(Self.failed, action: .update(role), log: Self.refusedLog, state: Self.behind)
        #expect(mark.isSet)
        mark.refreshed(.afterRootStep)
        mark.stateRead(Self.behind)
        #expect(mark.updateRefusal(payload: Self.v020) == UnresolvableInstall.sentence(for: .update(.server), payload: Self.v020))
        #expect(RepairPolicy.refusal(health: .cliMissing, rootStep: true, payload: Self.v020, unresolvable: mark.isSet)
            == .installedUnresolvable(payload: Self.v020))

        // A changed state, the user's Refresh, or a success lifts it.
        var healed = mark
        healed.stateRead(.healthy)
        #expect(!healed.isSet && healed.updateRefusal(payload: Self.v020) == nil)
        var refreshed = mark
        refreshed.refreshed(.popover)
        #expect(!refreshed.isSet)
        var updated = mark
        updated.rootStepFinished(.succeeded, action: .update(role), log: "")
        #expect(!updated.isSet)
    }

    @Test("an update that failed otherwise keeps the generic outcome and clears the hold")
    func updateFailedOtherwise() throws {
        let plan = try Self.plan(.update(.server))
        let other = RepairUnresolvableTests.otherLog
        #expect(OutcomeSummary.text(Self.failed, plan: plan, log: other) == OutcomeSummary.text(Self.failed, action: .update(.server)))
        var mark = UnresolvableInstallMark()
        mark.rootStepFinished(Self.failed, action: .update(.server), log: Self.refusedLog, state: Self.behind)
        mark.rootStepFinished(Self.failed, action: .update(.server), log: other)
        #expect(!mark.isSet && mark.updateRefusal(payload: Self.v020) == nil)
        // Only Repair and Update run the install k3sm refuses this way.
        for action: CopyOutAction in [.startServer, .join(try! ServerAddress(parsing: "192.0.2.10")), .uninstall(purge: true)] {
            #expect(!UnresolvableInstall.runsFromStaging(action))
            #expect(!UnresolvableInstall.refused(Self.failed, action: action, log: Self.refusedLog))
        }
    }

    // MARK: the k3sm CLI contract

    /// The k3sm checkout: K3SM_DIR, or a sibling checkout.
    static var k3smDirectory: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "pkg/install/fromstaging.go")
        return FileManager.default.fileExists(atPath: file.path) ? dir : nil
    }

    /// The Go string constant `name` in `source`: its quoted pieces, joined
    /// across `+` continuation lines.
    static func goConstant(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "const \(name) = ") else { return nil }
        var value = ""
        for line in source[start.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "\"", let close = trimmed.lastIndex(of: "\""), close != trimmed.startIndex else { return nil }
            let literal = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            if literal.contains("\\") { return nil }
            value += literal
            if !trimmed[close...].contains("+") { return value }
        }
        return nil
    }

    @Test("the recovery phrase and its line match the k3sm source", .enabled(if: k3smDirectory != nil))
    func recoveryPhraseMatchesTheK3smSource() throws {
        let dir = try #require(Self.k3smDirectory)
        let staging = try String(contentsOf: dir.appending(path: "pkg/install/fromstaging.go"), encoding: .utf8)
        let main = try String(contentsOf: dir.appending(path: "cmd/k3sm/main.go"), encoding: .utf8)
        let phrase = try #require(Self.goConstant("installedUnresolvableRecovery", in: staging),
                                  "no installedUnresolvableRecovery in pkg/install/fromstaging.go; the scrape is stale")
        #expect(phrase == UnresolvableInstall.recoveryPhrase)
        // The line shape the recogniser anchors on: k3sm's main prints the
        // install error after `k3sm install:`, and the refusal is
        // `install: <cause>; <recovery>`.
        #expect(main.contains(#"fmt.Fprintln(os.Stderr, "k3sm install:", err)"#))
        #expect(staging.contains(#"fmt.Errorf("install: %w; %s", err, installedUnresolvableRecovery)"#))
        #expect(UnresolvableInstall.linePrefix == "k3sm install: " + "install: ")
    }

    @Test("the constant scrape reads a Go string constant")
    func goConstantScrape() {
        let source = "const other = \"x\"\nconst c = \"a, \" +\n\t\"b \" +\n\t\"c\"\n\nfunc f() {}\n"
        #expect(Self.goConstant("c", in: source) == "a, b c")
        #expect(Self.goConstant("missing", in: source) == nil)
        #expect(Self.goConstant("c", in: "const c = \"a\" +\nfunc f() {}\n") == nil)
    }
}
