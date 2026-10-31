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

/// Byte-exact snapshots of every root script the app renders, for one fixed
/// Team ID and fixed inputs. Each render is compared with its fixture under
/// `Fixtures/scripts`, so any change to a script's bytes, however small, is
/// a visible fixture change in review. `K3SM_UPDATE_SCRIPT_GOLDENS=1` writes
/// the fixtures from the renders instead of comparing.
@Suite("root script goldens")
struct RootScriptGoldenTests {
    static let team = TeamID("TEAMTEAM12")!
    static let bundle = "/Applications/k3sm.app"
    static let version = SemanticVersion("0.2.0")!
    static let user = ConsoleUser("alice")!
    static let studio = try! ServerAddress(parsing: "studio.local")
    static let hex = String(repeating: "ab", count: 32)
    static let release = ReleaseTag("v0.3.0")!

    static func plan(_ action: CopyOutAction) -> CopyOutPlan {
        try! CopyOutPlan(bundlePath: bundle, payloadVersion: version, teamID: team, user: user, action: action)
    }

    static let copyOutActions: [(String, CopyOutAction)] = [
        ("start-server", .startServer),
        ("join", .join(studio)),
        ("update-server", .update(.server)),
        ("update-agent", .update(.agent(joinServer: studio))),
        ("repair", .repair),
        ("uninstall", .uninstall(purge: false)),
        ("uninstall-purge", .uninstall(purge: true)),
    ]

    static let imageVerbs: [(String, LifecycleScriptBuilder.ImageVerb)] = [
        ("prune-dry-run", .pruneDryRun),
        ("prune", .prune),
        ("untag", .untag(RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: "sha256:" + hex)!)),
        ("pull", .pull(ImageRef("docker.io/library/nginx:1.27")!)),
    ]

    static let allOptions = UpdateOptions(drain: true, allowDowngrade: true, signature: .required)

    /// Every golden: the fixture name and today's render.
    static func renders() -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        out.append(("preamble.sh", InstalledCLIPreamble.render(teamID: team, cliPath: K3smCLI.path)))
        let p = plan(.startServer)
        out.append(("staged-copy.sh", RootScriptBuilder.stagedCopy(
            bundlePath: p.bundlePath, stagingTemplate: p.stagingTemplate, designatedRequirement: p.designatedRequirement)))
        for (name, action) in copyOutActions {
            out.append(("copy-out-\(name).sh", RootScriptBuilder.render(plan(action)).text))
        }
        for verb in LifecycleScriptBuilder.FixedVerb.allCases {
            out.append(("lifecycle-\(verb.rawValue).sh", LifecycleScriptBuilder.render(verb, teamID: team).text))
        }
        for (name, verb) in imageVerbs {
            out.append(("image-\(name).sh", LifecycleScriptBuilder.renderImage(verb, teamID: team).text))
        }
        for mint in JoinTokenMint.allCases {
            out.append(("join-mint-\(mint.rawValue).sh", JoinTokenMint.render(mint, teamID: team).text))
        }
        out.append(("update-apply-defaults.sh",
                     LifecycleScriptBuilder.renderUpdateApply(teamID: team, options: .defaults, release: release).text))
        out.append(("update-apply-all-options.sh",
                     LifecycleScriptBuilder.renderUpdateApply(teamID: team, options: allOptions, release: release).text))
        return out
    }

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/scripts")
    }

    static func fixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: fixtureDirectory.appending(path: name))
        return String(decoding: data, as: UTF8.self)
    }

    /// The first line where `actual` differs from `expected`, both shown, or
    /// nil when they are the same bytes.
    static func diff(expected: String, actual: String) -> String? {
        guard expected != actual else { return nil }
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<max(e.count, a.count) {
            let el = i < e.count ? String(e[i]) : "<end>"
            let al = i < a.count ? String(a[i]) : "<end>"
            if el != al { return "line \(i + 1):\n- \(el)\n+ \(al)" }
        }
        return "the texts differ in bytes no line split shows"
    }

    /// Compares one render with its fixture, failing with the first differing line.
    static func expectGolden(_ name: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if ProcessInfo.processInfo.environment["K3SM_UPDATE_SCRIPT_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fixtureDirectory.appending(path: name))
            return
        }
        let expected = try fixture(name)
        if let d = diff(expected: expected, actual: text) {
            Issue.record("\(name) differs from its golden at \(d)", sourceLocation: sourceLocation)
        }
    }

    @Test("every rendered root script equals its golden byte for byte")
    func rootScriptGoldens() throws {
        let renders = Self.renders()
        #expect(Set(renders.map(\.name)).count == renders.count)
        for (name, text) in renders {
            try Self.expectGolden(name, text)
        }
        // Every fixture is a render: a stale golden is a failure, not dead weight.
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path)
        #expect(Set(files) == Set(renders.map(\.name)))
    }
}
