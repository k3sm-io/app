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

/// hack/build-version.sh over throwaway repositories: an app checkout with no
/// tags of its own beside a k3sm checkout carrying the releases, as the app's
/// releases are named by k3sm's tags.
@Suite("development build version")
struct BuildVersionTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs a program with only the environment given, returning its stdout.
    @discardableResult
    static func run(_ program: String, _ args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = args
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@invalid",
            "GIT_AUTHOR_DATE": "2026-10-16T22:15:30Z", "GIT_COMMITTER_DATE": "2026-10-16T22:15:30Z",
        ].merging(env) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(program) \(args)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repository with one commit at a fixed time; returns its 12-hex prefix.
    static func repo(_ dir: URL, tags: [String]) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a\n".write(to: dir.appending(path: "a"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["-C", dir.path, "init", "-q"])
        try run("/usr/bin/git", ["-C", dir.path, "add", "a"])
        try run("/usr/bin/git", ["-C", dir.path, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"])
        for tag in tags {
            try run("/usr/bin/git", ["-C", dir.path, "-c", "tag.gpgsign=false", "tag", tag])
        }
        return String(try run("/usr/bin/git", ["-C", dir.path, "rev-parse", "HEAD"]).prefix(12))
    }

    @Test func developerBuildVersionCoreIsTheNextPatch() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "k3sm-build-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appending(path: "app")
        let k3sm = base.appending(path: "k3sm")
        let sha = try Self.repo(app, tags: [])
        _ = try Self.repo(k3sm, tags: ["v0.2.2", "v0.2.3", "v0.2.4-rc.1", "not-a-version"])
        let script = Self.root.appending(path: "hack/build-version.sh").path

        // The sibling ../k3sm is the default; K3SM_DIR names another checkout.
        let sibling = try Self.run("/bin/bash", [script, app.path])
        #expect(sibling == "v0.2.4-0.20261016221530-\(sha)")
        let named = try Self.run("/bin/bash", [script, app.path], env: ["K3SM_DIR": k3sm.path])
        #expect(named == sibling)

        // It ranks above the latest release and below every rc and release of
        // its own core, and the app shows it as a development build.
        let version = try #require(SemanticVersion(sibling))
        #expect(version > SemanticVersion("0.2.3")!)
        #expect(version < SemanticVersion("0.2.4-rc.1")!)
        #expect(version < SemanticVersion("0.2.4")!)
        let shown = AppVersion(shortVersion: "0.0.0", buildVersion: sibling)
        #expect(shown.text == sibling)
        #expect(shown.isDevelopment)
        #expect(AppVersion.payloadRelease(info: ["CFBundleShortVersionString": "0.0.0", AppVersion.buildVersionKey: sibling]) == nil)
    }
}
