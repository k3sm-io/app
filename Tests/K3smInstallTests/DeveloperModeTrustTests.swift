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

/// Developer mode's trust table: which builds may enter it, what the root
/// steps check under it, and that the Developer ID policy renders exactly
/// what it rendered before developer mode existed (the goldens).
@Suite("developer mode trust table")
struct DeveloperModeTrustTests {
    typealias Facts = InstalledCLITrust.PathFacts
    static let team = RootScriptGoldenTests.team
    static let marker = Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o644)

    // MARK: availability

    struct AvailabilityRow: Sendable, CustomTestStringConvertible {
        let name: String
        let pinned: Bool
        let signature: Bool
        let admin: Bool
        let developerMode: Bool
        /// nil when enabled, else a fragment of the reason.
        let refusal: String?
        let warns: Bool
        var testDescription: String { name }
    }

    static let availability: [AvailabilityRow] = [
        AvailabilityRow(name: "unpinned, mode off: refused by default", pinned: false, signature: false, admin: true,
                        developerMode: false, refusal: "not Developer ID signed", warns: false),
        AvailabilityRow(name: "unpinned, mode off, even signed: refused", pinned: false, signature: true, admin: true,
                        developerMode: false, refusal: "not Developer ID signed", warns: false),
        AvailabilityRow(name: "unpinned, mode on, admin: enabled with the warning", pinned: false, signature: false, admin: true,
                        developerMode: true, refusal: nil, warns: true),
        AvailabilityRow(name: "unpinned, mode on, not admin: still needs an administrator", pinned: false, signature: false,
                        admin: false, developerMode: true, refusal: "administrator account", warns: true),
        AvailabilityRow(name: "pinned, marker present, signature bad: today's rule refuses", pinned: true, signature: false,
                        admin: true, developerMode: true, refusal: "failed its signature check", warns: false),
        AvailabilityRow(name: "pinned, marker present, not admin: today's rule refuses", pinned: true, signature: true,
                        admin: false, developerMode: true, refusal: "administrator account", warns: false),
        AvailabilityRow(name: "pinned, marker present, all good: enabled with no warning", pinned: true, signature: true,
                        admin: true, developerMode: true, refusal: nil, warns: false),
        AvailabilityRow(name: "pinned, mode off, all good: enabled", pinned: true, signature: true, admin: true,
                        developerMode: false, refusal: nil, warns: false),
    ]

    @Test("availability: developer mode enables only an unpinned build, and never skips the admin check", arguments: availability)
    func developerModeTrustTableAvailability(_ row: AvailabilityRow) {
        let team = row.pinned ? Self.team : nil
        let got = PrivilegedAvailability.evaluate(
            teamID: team, signatureValid: row.signature, userIsAdmin: row.admin, developerMode: row.developerMode)
        switch (got, row.refusal) {
        case (.enabled, nil): break
        case (.disabled(let why), let fragment?): #expect(why.contains(fragment), "\(why)")
        default: Issue.record("got \(got), want refusal \(row.refusal ?? "none")")
        }
        let warning = PrivilegedAvailability.warning(teamID: team, developerMode: row.developerMode)
        #expect(warning == (row.warns ? DeveloperMode.warning : nil))
    }

    @Test("a pinned build's verdict ignores the developer-mode argument")
    func developerModeTrustTablePinnedIgnoresMode() {
        for signature in [false, true] {
            for admin in [false, true] {
                #expect(PrivilegedAvailability.evaluate(teamID: Self.team, signatureValid: signature, userIsAdmin: admin, developerMode: true)
                    == PrivilegedAvailability.evaluate(teamID: Self.team, signatureValid: signature, userIsAdmin: admin, developerMode: false))
            }
        }
    }

    // MARK: the marker in Swift

    static let badMarkers: [(String, Facts?)] = [
        ("absent", nil),
        ("a symlink", Facts(isSymlink: true, isDirectory: false, isRegularFile: false, ownerUID: 0, mode: 0o644)),
        ("a directory", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755)),
        ("another owner", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 501, mode: 0o644)),
        ("group-writable", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o664)),
        ("other-writable", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o646)),
        ("carries an ACL", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o644, hasACL: true)),
    ]

    static let rootDir = Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755)

    /// `lstat` facts for `/`, `/Library` and the marker: good directories,
    /// with `marker` at the marker path and `overrides` replacing any path.
    static func layout(marker: Facts?, _ overrides: [String: Facts?] = [:]) -> (String) -> Facts? {
        { path in
            if let o = overrides[path] { return o }
            if path == DeveloperMode.markerPath { return marker }
            return ["/", "/Library"].contains(path) ? rootDir : nil
        }
    }

    static func on(marker: Facts?, _ overrides: [String: Facts?] = [:]) -> Bool {
        DeveloperMode.isOn(facts: layout(marker: marker, overrides))
    }

    @Test("isOn: only a root-owned regular file, not group or other writable, with no ACL")
    func developerModeTrustTableIsOn() {
        #expect(Self.on(marker: Self.marker))
        #expect(Self.on(marker: Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o600)))
        for (name, facts) in Self.badMarkers {
            #expect(!Self.on(marker: facts), "\(name)")
        }
    }

    @Test("isOn: every directory above the marker is checked as the root step checks it")
    func developerModeTrustTableIsOnAncestors() {
        let bad: [(String, Facts?)] = [
            ("absent", nil),
            ("a symlink", Facts(isSymlink: true, isDirectory: false, isRegularFile: false, ownerUID: 0, mode: 0o755)),
            ("a regular file", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o755)),
            ("another owner", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 501, mode: 0o755)),
            ("group-writable", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o775)),
            ("other-writable", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o757)),
            ("carries an ACL", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755, hasACL: true)),
        ]
        for ancestor in ["/", "/Library"] {
            for (name, facts) in bad {
                #expect(!Self.on(marker: Self.marker, [ancestor: facts]), "\(ancestor) \(name)")
            }
        }
        // The owners set widens every path's owner check, and only that.
        let mine = Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 501, mode: 0o644)
        #expect(DeveloperMode.isOn(owners: [0, 501], facts: Self.layout(marker: mine)))
        #expect(!DeveloperMode.isOn(owners: [0], facts: Self.layout(marker: mine)))
    }

    @Test("TrustPolicy.current: a pinned build is never developer mode; an unpinned one only with a valid marker")
    func developerModeTrustTableCurrent() {
        #expect(TrustPolicy.current(pin: Self.team, developerModeOn: true) == .developerID(Self.team))
        #expect(TrustPolicy.current(pin: Self.team, developerModeOn: false) == .developerID(Self.team))
        #expect(TrustPolicy.current(pin: nil, developerModeOn: true) == .developer)
        #expect(TrustPolicy.current(pin: nil, developerModeOn: false) == nil)
        #expect(DeveloperMode.markerPath == "/Library/k3sm.developer-mode")
        #expect(TrustPolicy.developer.requirementClause == nil)
        #expect(TrustPolicy.developerID(Self.team).requirementClause == DesignatedRequirement.developerID(teamID: Self.team))
    }

    // MARK: Developer ID renders are the goldens

    /// Every golden, rendered through the policy API with `.developerID`.
    static func policyRenders() -> [(name: String, text: String)] {
        let policy = TrustPolicy.developerID(team)
        let g = RootScriptGoldenTests.self
        func plan(_ action: CopyOutAction) -> CopyOutPlan {
            try! CopyOutPlan(bundlePath: g.bundle, payloadVersion: g.version, policy: policy, user: g.user, action: action)
        }
        var out: [(String, String)] = []
        out.append(("preamble.sh", InstalledCLIPreamble.render(policy: policy, cliPath: K3smCLI.path)))
        let p = plan(.startServer)
        out.append(("staged-copy.sh", RootScriptBuilder.stagedCopy(
            bundlePath: p.bundlePath, stagingTemplate: p.stagingTemplate, policy: policy)))
        for (name, action) in g.copyOutActions {
            out.append(("copy-out-\(name).sh", RootScriptBuilder.render(plan(action)).text))
        }
        for verb in LifecycleScriptBuilder.FixedVerb.allCases {
            out.append(("lifecycle-\(verb.rawValue).sh", LifecycleScriptBuilder.render(verb, policy: policy).text))
        }
        for (name, verb) in g.imageVerbs {
            out.append(("image-\(name).sh", LifecycleScriptBuilder.renderImage(verb, policy: policy).text))
        }
        for mint in JoinTokenMint.allCases {
            out.append(("join-mint-\(mint.rawValue).sh", JoinTokenMint.render(mint, policy: policy).text))
        }
        out.append(("update-apply-defaults.sh",
                     LifecycleScriptBuilder.renderUpdateApply(policy: policy, options: .defaults, release: g.release).text))
        out.append(("update-apply-all-options.sh",
                     LifecycleScriptBuilder.renderUpdateApply(policy: policy, options: g.allOptions, release: g.release).text))
        return out
    }

    @Test("every .developerID render equals its golden byte for byte")
    func developerModeTrustTableDeveloperIDGoldens() throws {
        let renders = Self.policyRenders()
        // The goldens' developer-mode renders (`developer-*`) are checked by the golden suite itself.
        #expect(Set(renders.map(\.name)) == Set(RootScriptGoldenTests.renders().map(\.name).filter { !$0.hasPrefix("developer-") }))
        for (name, text) in renders {
            let expected = try RootScriptGoldenTests.fixture(name)
            if let d = RootScriptGoldenTests.diff(expected: expected, actual: text) {
                Issue.record("\(name) differs from its golden at \(d)")
            }
        }
    }

    // MARK: .developer renders

    @Test("every .developer script that runs the installed CLI checks the marker and runs no codesign")
    func developerModeTrustTableDeveloperRenders() {
        let g = RootScriptGoldenTests.self
        var texts = [InstalledCLIPreamble.render(policy: .developer, cliPath: K3smCLI.path)]
        texts += LifecycleScriptBuilder.FixedVerb.allCases.map { LifecycleScriptBuilder.render($0, policy: .developer).text }
        texts += g.imageVerbs.map { LifecycleScriptBuilder.renderImage($0.1, policy: .developer).text }
        texts += JoinTokenMint.allCases.map { JoinTokenMint.render($0, policy: .developer).text }
        texts.append(LifecycleScriptBuilder.renderUpdateApply(policy: .developer, options: .defaults, release: g.release).text)
        for text in texts {
            #expect(!text.contains("codesign"))
            #expect(!text.contains("-R="))
            #expect(text.contains("marker=" + ShellQuote.quote(DeveloperMode.markerPath) + "\n"))
            #expect(text.contains("exit \(LifecycleExit.developerModeMissing)\n"))
            // The CLI's path checks stay on.
            #expect(text.contains("exit \(LifecycleExit.refusedBinary)\n"))
        }
    }

    @Test("the .developer staged copy verifies an intact signature with no requirement")
    func developerModeTrustTableStagedCopy() {
        let text = RootScriptBuilder.stagedCopy(bundlePath: "/Applications/k3sm.app", stagingTemplate: "/Library/k3sm.staging/x.XXXXXXXX",
                                                policy: .developer)
        #expect(text.contains("if ! /usr/bin/codesign --verify --strict --deep \"$stage\"/'k3sm.app'; then\n"))
        #expect(!text.contains("-R="))
        #expect(text.contains("exit \(CopyOutExit.signatureRejected)\n"))
    }

    static func plan(_ action: CopyOutAction, _ policy: TrustPolicy) -> CopyOutPlan {
        let g = RootScriptGoldenTests.self
        return try! CopyOutPlan(bundlePath: g.bundle, payloadVersion: g.version, policy: policy, user: g.user, action: action)
    }

    @Test("the copy-out argv carries --developer-mode on only for a first install under .developer")
    func developerModeTrustTableCopyOutArgv() {
        let flag = RootScriptBuilder.developerModeArguments
        for (name, action) in RootScriptGoldenTests.copyOutActions {
            let dev = RootScriptBuilder.arguments(for: Self.plan(action, .developer))
            let signed = RootScriptBuilder.arguments(for: Self.plan(action, .developerID(Self.team)))
            #expect(!signed.contains(.literal("--developer-mode")), "\(name)")
            if action.isFirstInstall {
                #expect(dev == signed + flag, "\(name)")
                #expect(dev.suffix(2) == flag[...], "\(name)")
            } else {
                #expect(dev == signed, "\(name)")
            }
        }
    }

    @Test("the copy-out checks the marker in every step but the first install, before the staged CLI runs")
    func developerModeTrustTableCopyOutMarker() {
        for (name, action) in RootScriptGoldenTests.copyOutActions {
            let text = RootScriptBuilder.render(Self.plan(action, .developer)).text
            #expect(!text.contains("-R="), "\(name)")
            let check = text.range(of: "marker=" + ShellQuote.quote(DeveloperMode.markerPath) + "\n")
            if action.isFirstInstall {
                #expect(check == nil, "\(name)")
            } else {
                let run = text.range(of: "\n\"$k3sm\" ")
                #expect(check != nil && run != nil && check!.upperBound < run!.lowerBound, "\(name)")
            }
        }
    }

    @Test("the administrator prompt says the checks are off for install, update and repair, not uninstall")
    func developerModeTrustTablePrompts() {
        for (name, action) in RootScriptGoldenTests.copyOutActions {
            let signed = action.prompt(policy: .developerID(Self.team))
            let dev = action.prompt(policy: .developer)
            #expect(signed == action.prompt, "\(name)")
            #expect(RootScriptBuilder.render(Self.plan(action, .developer)).prompt == dev, "\(name)")
            if case .uninstall = action {
                #expect(dev == signed, "\(name)")
            } else {
                #expect(dev == String(signed.dropLast()) + ", with signature checks off.", "\(name)")
            }
        }
        #expect(CopyOutAction.startServer.prompt(policy: .developer)
            == "k3sm wants to install a k3sm server on this Mac, with signature checks off.")
    }

    @Test("a lifecycle run refused for a missing marker gets its own sentence")
    func developerModeTrustTableOutcome() {
        for verb in LifecycleVerb.allCases {
            #expect(LifecycleOutcome.text(.failed(exitStatus: LifecycleExit.developerModeMissing), verb: verb)
                == DeveloperMode.missingText)
        }
        let taken: [Int32] = [LifecycleExit.failed, LifecycleExit.usage, LifecycleExit.needsRoot, LifecycleExit.lanRestoreFailed,
                              LifecycleExit.refusedBinary, LifecycleExit.signatureRejected,
                              BundledRollExit.recordRefused, BundledRollExit.tagMismatch, BundledRollExit.digestRefused,
                              BundledRollExit.recordUnreadable, CopyOutExit.refusedPath, CopyOutExit.refusedTree,
                              CopyOutExit.missingToken, CopyOutExit.busy, CopyOutExit.signatureRejected]
        #expect(!taken.contains(LifecycleExit.developerModeMissing))
        #expect(!(33...95).contains(LifecycleExit.developerModeMissing))
        #expect(CopyOutExit.developerModeMissing == LifecycleExit.developerModeMissing)
    }

    // MARK: the .developer preamble, run

    /// A flat CLI layout (`InstalledCLIChainTests`) plus a marker in its own
    /// folder `mark` under the layout's base.
    struct MarkerLayout {
        let cli: InstalledCLIChainTests.Layout
        var folder: String { cli.base + "/mark" }
        var marker: String { folder + "/k3sm.developer-mode" }
    }

    static func makeMarkerLayout() throws -> MarkerLayout {
        let layout = MarkerLayout(cli: try InstalledCLIChainTests.makeLayout(chain: false))
        try FileManager.default.createDirectory(atPath: layout.folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try Data("developer mode enabled by k3sm install on 2026-10-31T00:00:00Z\n".utf8)
            .write(to: URL(fileURLWithPath: layout.marker))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: layout.marker)
        return layout
    }

    /// The `.developer` preamble for `layout`, trusting root and this user,
    /// then a line that reports the CLI in place of running it.
    static func script(_ layout: MarkerLayout) -> String {
        let owners: [UInt32] = [0, getuid()]
        return InstalledCLIPreamble.render(
            cliPath: layout.cli.cli, requirement: nil, owners: owners,
            markerCheck: DeveloperMode.shellCheck(markerPath: layout.marker, owners: owners))
            + "echo \"\(InstalledCLIChainTests.accepted)$k3sm\" >&2\n"
    }

    struct MarkerCase: Sendable, CustomTestStringConvertible {
        let name: String
        let message: String
        let mutate: @Sendable (MarkerLayout) throws -> Void
        /// Rewrites the script, for the owner case.
        var edit: @Sendable (String, MarkerLayout) -> String = { s, _ in s }
        var testDescription: String { name }
    }

    static let refusals: [MarkerCase] = [
        MarkerCase(name: "a symlink", message: "is a symlink", mutate: { l in
            let real = l.folder + "/real"
            try FileManager.default.moveItem(atPath: l.marker, toPath: real)
            try FileManager.default.createSymbolicLink(atPath: l.marker, withDestinationPath: real)
        }),
        MarkerCase(name: "a directory", message: "is not a regular file", mutate: { l in
            try FileManager.default.removeItem(atPath: l.marker)
            try FileManager.default.createDirectory(atPath: l.marker, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
        }),
        MarkerCase(name: "mode 0664", message: "is not owned by root, or is writable by group or others",
                   mutate: { try InstalledCLIChainTests.chmod("0664", $0.marker) }),
        MarkerCase(name: "mode 0662", message: "is not owned by root, or is writable by group or others",
                   mutate: { try InstalledCLIChainTests.chmod("0662", $0.marker) }),
        MarkerCase(name: "mode 0646", message: "is not owned by root, or is writable by group or others",
                   mutate: { try InstalledCLIChainTests.chmod("0646", $0.marker) }),
        MarkerCase(name: "an ACL", message: "carries an ACL",
                   mutate: { try InstalledCLIChainTests.chmod("+a 'everyone deny delete'", $0.marker) }),
        MarkerCase(name: "another owner", message: "is not owned by root, or is writable by group or others",
                   mutate: { _ in }, edit: { s, l in
                       let uid = getuid()
                       return s.replacingOccurrences(
                           of: "! -user \(uid)", with: "\\( ! -user \(uid) -o -path \(ShellQuote.quote(l.marker)) \\)")
                   }),
        MarkerCase(name: "a group-writable parent", message: "is not owned by root, or is writable by group or others",
                   mutate: { try InstalledCLIChainTests.chmod("g+w", $0.folder) }),
        MarkerCase(name: "absent", message: "does not exist",
                   mutate: { try FileManager.default.removeItem(atPath: $0.marker) }),
    ]

    @Test("the .developer preamble refuses a marker that does not count, and runs nothing", arguments: refusals)
    func developerModeTrustTableShellRefuses(_ c: MarkerCase) throws {
        let layout = try Self.makeMarkerLayout()
        defer { try? FileManager.default.removeItem(atPath: layout.cli.base) }
        try c.mutate(layout)
        let script = c.edit(Self.script(layout), layout)
        let result = try InstalledCLIChainTests.run(script)
        #expect(result.status == LifecycleExit.developerModeMissing, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("developer mode is off"), "stderr: \(result.stderr)")
        #expect(result.stderr.contains(c.message), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains(InstalledCLIChainTests.accepted), "the CLI line was reached")
    }

    @Test("the .developer preamble accepts a 0644 marker and checks no signature")
    func developerModeTrustTableShellAccepts() throws {
        let layout = try Self.makeMarkerLayout()
        defer { try? FileManager.default.removeItem(atPath: layout.cli.base) }
        let result = try InstalledCLIChainTests.run(Self.script(layout))
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(InstalledCLIChainTests.accepted + layout.cli.cli))
    }

    @Test("the .developer preamble still refuses a CLI that fails its path checks")
    func developerModeTrustTableShellKeepsCLIChecks() throws {
        let layout = try Self.makeMarkerLayout()
        defer { try? FileManager.default.removeItem(atPath: layout.cli.base) }
        try InstalledCLIChainTests.chmod("g+w", layout.cli.cli)
        let result = try InstalledCLIChainTests.run(Self.script(layout))
        #expect(result.status == LifecycleExit.refusedBinary, "stderr: \(result.stderr)")
        #expect(!result.stderr.contains(InstalledCLIChainTests.accepted))
    }

    // MARK: what keeps a Developer ID requirement

    /// `BundledRollPlan` and `AppUpdateTrust` take no `TrustPolicy`: this
    /// row calls the only initializer and function they have, which take a
    /// `TeamID`. A `TrustPolicy` overload would be a second way in, and a
    /// test that fails to compile is no test, so the row pins the shape by
    /// use: adding a policy parameter breaks these calls.
    @Test("the version set's roll and the app's own update keep a TeamID")
    func developerModeTrustTableKeepsTeamID() throws {
        let plan = try BundledRollPlan(bundlePath: "/Applications/k3sm.app", release: ReleaseTag("v0.2.0")!, teamID: Self.team)
        #expect(BundledRollScriptBuilder.render(plan: plan).text.contains(DesignatedRequirement.developerID(teamID: Self.team)))
        #expect(AppUpdateTrust.appRequirement(teamID: Self.team).contains(Self.team.description))
    }

    // MARK: the screens' questions

    @Test("Repair's question carries the warning only in developer mode")
    func developerModeRepairConfirmation() {
        let version = SemanticVersion("0.0.0-0.20261031000000-abcdef012345")!
        #expect(!RepairConfirmation(payload: version, role: .server).message.contains(DeveloperMode.warning))
        #expect(RepairConfirmation(payload: version, role: .server, developerMode: true).message.hasSuffix(DeveloperMode.warning))
    }

    @Test("an update in developer mode asks first, with the warning; nothing else does")
    func developerModeUpdateConfirmation() throws {
        let version = SemanticVersion("0.0.0-0.20261031000000-abcdef012345")!
        let q = try #require(DeveloperModeConfirmation(action: .update(.server), payload: version, policy: .developer))
        #expect(q.message.contains(DeveloperMode.warning))
        #expect(q.message.contains(version.description))
        #expect(DeveloperModeConfirmation(action: .update(.server), payload: version, policy: .developerID(Self.team)) == nil)
        for action: CopyOutAction in [.startServer, .repair, .uninstall(purge: false), .uninstall(purge: true)] {
            #expect(DeveloperModeConfirmation(action: action, payload: version, policy: .developer) == nil, "\(action)")
        }
    }

    @Test("Repair runs on a developer build only in developer mode, from the build's pseudo-version")
    func developerModeRepairPolicy() {
        let build = AppVersion(shortVersion: "0.0.0", buildVersion: "v0.0.0-0.20261031000000-abcdef012345")
        let off = DeveloperModeChoice.payload(release: nil, build: build, pinned: false, developerMode: false, payloadCLI: true)
        let on = DeveloperModeChoice.payload(release: nil, build: build, pinned: false, developerMode: true, payloadCLI: true)
        let state = HealthState.cliMissing
        #expect(RepairPolicy.refusal(health: state, rootStep: DeveloperModeChoice.rootStep(pinned: false, developerMode: false),
                                     payload: off) == .noRootStep)
        #expect(RepairPolicy.refusal(health: state, rootStep: DeveloperModeChoice.rootStep(pinned: false, developerMode: true),
                                     payload: on) == nil)
        // Developer mode without a payload k3sm still has nothing to repair from.
        let bare = DeveloperModeChoice.payload(release: nil, build: build, pinned: false, developerMode: true, payloadCLI: false)
        #expect(RepairPolicy.refusal(health: state, rootStep: true, payload: bare) == .payloadUnknown)
    }
}

