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

@testable import K3smInstall

/// The staging sweep runs as root, but uchg and uappnd are user flags, so the
/// sweep's own lines can run unprivileged against a user-owned directory: a
/// wrong flag spelling or find predicate leaves the flagged leftover in place
/// and the run fails, where the golden scripts would only pin the text.
@Suite("root sweep")
struct RootSweepTests {
    @Test("the sweep clears user locking flags and removes the leftover")
    func rootSweepClearsUserLockingFlags() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("k3sm-sweep-\(UUID().uuidString)").path
        let root = base + "/staging"
        defer {
            _ = try? shell(["-c", "/usr/bin/chflags -R nouchg,nouappnd \"$1\"; /bin/rm -rf \"$1\"", "sh", base])
        }
        let leftover = root + "/0.2.0.ABCDEFGH"
        let contents = leftover + "/k3sm.app/Contents"
        try fm.createDirectory(atPath: contents, withIntermediateDirectories: true)
        let locked = contents + "/Info.plist"
        let appendOnly = contents + "/log"
        for path in [locked, appendOnly] {
            #expect(fm.createFile(atPath: path, contents: Data("x\n".utf8)))
        }
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(appendOnly, UInt32(UF_APPEND)) == 0)
        // Without the flag clear, rm cannot remove the leftover.
        let plain = try shell(["-c", "/bin/rm -rf \"$1\" 2>/dev/null", "sh", leftover])
        try #require(plain.status != 0 && fm.fileExists(atPath: locked), "the fixture is not locked")

        let text = RootScriptBuilder.stagedCopy(bundlePath: "/Applications/k3sm.app",
                                                stagingTemplate: CopyOutPlan.stagingRoot + "/0.2.0.XXXXXXXX",
                                                designatedRequirement: nil)
        let rootLine = "root=" + ShellQuote.quote(CopyOutPlan.stagingRoot)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try #require(lines.contains(rootLine), "the script sets the staging root")
        let sweep = lines.filter { $0.hasPrefix("/usr/bin/find \"$root\" ") }
        try #require(sweep.count == 2, "the sweep is two find lines: the flag clear, then the removal")
        let script = (["set -eu", "root=" + ShellQuote.quote(root)] + sweep).joined(separator: "\n") + "\n"

        let run = try shell(["-c", script])
        #expect(run.status == 0, "the sweep exits \(run.status)")
        #expect(!fm.fileExists(atPath: leftover), "the flagged leftover is removed")
        #expect(fm.fileExists(atPath: root), "the staging root itself stays")
    }
}
