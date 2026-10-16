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

/// The build and builder verbs the Builds tab runs, pinned against the k3sm
/// CLI source (K3SM_DIR, or a sibling checkout); skipped without one.
@Suite("the Builds tab's k3sm CLI contract")
struct BuildCLIContractTests {
    static var cliDirectory: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let cmd = dir.appending(path: "cmd/k3sm")
        return FileManager.default.fileExists(atPath: cmd.appending(path: "buildmanage.go").path) ? dir : nil
    }

    @Test("every build and builder verb and flag the app passes is one the CLI declares", .enabled(if: cliDirectory != nil))
    func verbsDeclared() throws {
        let dir = try #require(Self.cliDirectory)
        let read = { (name: String) in try String(contentsOf: dir.appending(path: name), encoding: .utf8) }
        let builder = try read("cmd/k3sm/builder.go")
        let build = try read("cmd/k3sm/build.go")
        let manage = try read("cmd/k3sm/buildmanage.go")
        let ls = try read("cmd/k3sm/buildls.go")
        #expect(builder.contains(#"case "up", "down", "delete", "status":"#), "k3sm builder has no up/down/delete")
        #expect(build.contains(#"case "ls":"#), "k3sm build has no ls")
        #expect(build.contains(#"case "cancel", "rm", "logs", "prune":"#), "k3sm build has no cancel/rm/logs/prune")
        #expect(ls.contains(#"fs.String("o", "text""#) && ls.contains(#"format == "json""#), "k3sm build ls has no -o json")
        #expect(manage.contains(#"fs.BoolVar(&follow, "f","#), "k3sm build logs has no -f")
        #expect(manage.contains(#"fs.Bool("force","#), "k3sm build prune has no --force")
        // The lines the app reads its figures from.
        #expect(manage.contains(#""would reclaim %s (%d bytes) from %d cache record(s)\n""#))
        #expect(manage.contains(#""reclaimed %s (%d bytes) from %d cache record(s)\n""#))
        // The engine verbs and the prune pick the user's admin kubeconfig as
        // `k3sm kubectl` does, so the app runs them as the user with no
        // --work-dir; the history verbs read the user's ledger.
        #expect(builder.contains("resolveKubectlConfig(in)"), "k3sm builder does not choose its kubeconfig like k3sm kubectl")
        #expect(manage.contains("newBuilderManager(builderOptions{workDir: dir, workDirExplicit: explicit})"), "k3sm build prune does not share the builder's kubeconfig choice")
        #expect(manage.contains("buildledger.DefaultDir()") && ls.contains("buildledger.DefaultDir()"))
        let ledger = try read("pkg/buildledger/buildledger.go")
        #expect(ledger.contains("`^[0-9a-f]{12}\\.json$`"), "the ledger's record id is no longer 12 lowercase hex")
    }
}
