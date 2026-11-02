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

import Darwin
import Foundation
import Testing

import K3smStatus
@testable import K3smInstall

/// What the app does around the administrator path for the app swap: the
/// prompt a refusal for an untrusted target (115) leads to, and root's floor
/// record outside the swap (seeded by an install, removed by an uninstall).
@Suite struct AppSwapFloorTests {
    static let team = TeamID("ABCDE12345")!
    static let user = ConsoleUser("alice")!

    static func plan(_ action: CopyOutAction, bundle: String = AppSwapRoot.target, policy: TrustPolicy? = nil) throws -> CopyOutPlan {
        try CopyOutPlan(bundlePath: bundle, payloadVersion: SemanticVersion("0.2.0")!, policy: policy ?? .developerID(team),
                        user: user, action: action)
    }

    // MARK: the refusal

    @Test("an administrator swap refused because k3sm.app is not root's (115) offers a reinstall from the release")
    func appSwapRefusalOffersReinstall() throws {
        let offer = try #require(AppSwapRecovery.forAdministratorExit(AppSwapRootExit.targetUntrusted))
        #expect(offer.title == "Reinstall k3sm.app from the release")
        #expect(offer.message.contains("Download k3sm.app from the release page"))
        #expect(offer.message.contains("drag it to Applications"))
        #expect(offer.actionTitle == "Open the Release Page")
        #expect(offer.url == GuidedSteps.releasesURL)
        // A success, and refusals the reinstall does not fix, are not this prompt.
        for status in [0, AppSwapRootExit.targetRefused, AppSwapRootExit.helperRejected, AppSwapRootExit.noConsoleUser,
                       AppSwapRootExit.stagedRefused, AppSwapRootExit.verificationFailed, AppSwapRootExit.volumeRefused,
                       AppSwapRootExit.swapFailed, AppSwapRootExit.undoFailed, CopyOutExit.busy] {
            #expect(AppSwapRecovery.forAdministratorExit(status) == nil, "\(status)")
        }
        // Fixed text: no line break, no path the cluster could supply.
        for text in [offer.title, offer.message, offer.actionTitle] {
            #expect(!text.contains("\n"))
        }
    }

    // MARK: the floor record

    @Test("an install from the app in Applications seeds the floor record after the signature check and before k3sm runs; an uninstall removes it after k3sm uninstall")
    func appSwapFloorRecordSeededAndReset() throws {
        for action: CopyOutAction in [.startServer, .join(try ServerAddress(parsing: "studio.local")), .update(.server), .repair] {
            let text = RootScriptBuilder.render(try Self.plan(action)).text
            let verify = try #require(text.range(of: "copy-out: verifying the signature"))
            let seed = try #require(text.range(of: AppSwapFloor.seed), "\(action)")
            let run = try #require(text.range(of: "\"$k3sm\" "))
            #expect(verify.upperBound <= seed.lowerBound && seed.upperBound <= run.lowerBound, "\(action)")
            #expect(!text.contains(AppSwapFloor.reset), "\(action)")
        }
        for purge in [false, true] {
            for policy: TrustPolicy in [.developerID(Self.team), .developer] {
                let text = RootScriptBuilder.render(try Self.plan(.uninstall(purge: purge), policy: policy)).text
                let run = try #require(text.range(of: "\"$k3sm\" 'uninstall'"))
                let reset = try #require(text.range(of: AppSwapFloor.reset), "purge \(purge) \(policy)")
                #expect(run.upperBound <= reset.lowerBound)
                #expect(!text.contains(AppSwapFloor.seed))
            }
        }
        // No seed from a bundle that is not the swap's target, nor from a
        // build only checked for an intact signature.
        #expect(!RootScriptBuilder.render(try Self.plan(.startServer, bundle: "/Users/alice/Downloads/k3sm.app")).text
            .contains(AppSwapFloor.seed))
        #expect(!RootScriptBuilder.render(try Self.plan(.startServer, policy: .developer)).text.contains(AppSwapFloor.seed))
        #expect(AppSwapFloor.resetCommand == "sudo rm -f /Library/k3sm.app-floor")
    }

    enum SeedCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case release, candidate, untagged, notATag, recordPresent, recordSymlink
        var testDescription: String { rawValue }
    }

    @Test("the seed writes the installed release tag as a 0600 file the swap's check accepts, and never replaces a record",
          arguments: SeedCase.allCases)
    func appSwapFloorSeedRunsAsTheSwapReadsIt(_ c: SeedCase) throws {
        let w = FloorScratch()
        defer { w.cleanUp() }
        switch c {
        case .release: try w.stage(tag: "v1.2.3")
        case .candidate: try w.stage(tag: "v1.3.0-rc.2")
        case .untagged: try w.stage(tag: nil)
        case .notATag: try w.stage(tag: "v1.2.3'; touch pwned; '")
        case .recordPresent:
            try w.stage(tag: "v1.2.3")
            try w.write(w.record, "v2.0.0\n")
        case .recordSymlink:
            try w.stage(tag: "v1.2.3")
            try FileManager.default.createSymbolicLink(atPath: w.record, withDestinationPath: w.root + "/elsewhere")
        }
        let seed = AppSwapFloor.seed(record: w.record, owner: getuid())
        let result = try shell(["-c", "set -eu\numask 077\nstage=" + ShellQuote.quote(w.stage) + "\n" + seed + "echo done\n"])
        #expect(result.status == 0, "\(result)")
        let written = try? String(contentsOfFile: w.record, encoding: .utf8)
        switch c {
        case .release: #expect(written == "v1.2.3\n")
        case .candidate: #expect(written == "v1.3.0-rc.2\n")
        case .untagged, .notATag: #expect(written == nil && !FileManager.default.fileExists(atPath: w.record))
        case .recordPresent: #expect(written == "v2.0.0\n")
        case .recordSymlink:
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: w.record)) == w.root + "/elsewhere")
            #expect(!FileManager.default.fileExists(atPath: w.root + "/elsewhere"))
        }
        #expect(!FileManager.default.fileExists(atPath: w.stage + "/" + AppSwapFloor.seedFileName))
        #expect(!FileManager.default.fileExists(atPath: w.root + "/pwned") && !FileManager.default.fileExists(atPath: "/pwned"))
        if c == .release || c == .candidate {
            var st = stat()
            try #require(lstat(w.record, &st) == 0)
            #expect(st.st_mode & 0o7777 == 0o600 && st.st_uid == getuid() && st.st_nlink == 1)
            // The swap's own target check reads the seeded record as its floor.
            try FileManager.default.createDirectory(atPath: w.root + "/Applications/k3sm.app/Contents", withIntermediateDirectories: true)
            let check = AppSwapRootScriptBuilder.targetCheck(applications: w.root + "/Applications", target: w.root + "/Applications/k3sm.app",
                                                             floorRecord: w.record, owner: getuid())
            let read = try shell(["-c", "set -eu\n" + check + "echo \"floor=$floor\"\n"])
            #expect(read.status == 0 && read.output == "floor=\(written ?? "")", "\(read)")
        }
    }

    @Test("the reset removes the record, a symlink in its place (never its target), and does nothing when there is none")
    func appSwapFloorResetRemovesTheRecord() throws {
        for kind in ["file", "symlink", "none"] {
            let w = FloorScratch()
            defer { w.cleanUp() }
            switch kind {
            case "file": try w.write(w.record, "v1.0.0\n")
            case "symlink":
                try w.write(w.root + "/elsewhere", "keep\n")
                try FileManager.default.createSymbolicLink(atPath: w.record, withDestinationPath: w.root + "/elsewhere")
            default: break
            }
            let result = try shell(["-c", "set -eu\n" + AppSwapFloor.reset(record: w.record) + "echo done\n"])
            #expect(result.status == 0, "\(kind): \(result)")
            var st = stat()
            #expect(lstat(w.record, &st) != 0, "\(kind)")
            if kind == "symlink" { #expect((try? String(contentsOfFile: w.root + "/elsewhere", encoding: .utf8)) == "keep\n") }
        }
        // A folder in its place is not removed: the uninstall fails and says so.
        let w = FloorScratch()
        defer { w.cleanUp() }
        try FileManager.default.createDirectory(atPath: w.record, withIntermediateDirectories: true)
        let result = try shell(["-c", "set -eu\n" + AppSwapFloor.reset(record: w.record) + "echo done\n"])
        #expect(result.status != 0 && !result.output.contains("done"), "\(result)")
    }

    // MARK: the target check's own refusals the hostile cases do not reach

    @Test("the target check refuses a named pipe in the tree and a tree it cannot read, before the copy")
    func appSwapTargetCheckRefusesPipeAndUnreadableTree() throws {
        for kind in ["fifo", "unreadable"] {
            let w = FloorScratch()
            defer { w.cleanUp() }
            let target = w.root + "/Applications/k3sm.app"
            try FileManager.default.createDirectory(atPath: target + "/Contents/Resources", withIntermediateDirectories: true)
            if kind == "fifo" {
                try #require(mkfifo(target + "/Contents/Resources/pipe", 0o600) == 0)
            } else {
                try #require(chmod(target + "/Contents/Resources", 0o000) == 0)
            }
            let check = AppSwapRootScriptBuilder.targetCheck(applications: w.root + "/Applications", target: target,
                                                             floorRecord: w.record, owner: getuid())
            let result = try shell(["-c", "set -eu\n" + check + "echo passed\n"])
            #expect(result.status == AppSwapRootExit.targetUntrusted, "\(kind): \(result)")
        }
    }
}

/// FloorScratch is a scratch folder standing in for `/Library`: a floor
/// record path and a stage holding a bundle's Info.plist.
private final class FloorScratch: @unchecked Sendable {
    let root: String
    var record: String { root + "/app-floor" }
    var stage: String { root + "/stage" }

    init() {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = realpath(NSTemporaryDirectory(), &buf).map { String(cString: $0) } ?? NSTemporaryDirectory()
        root = tmp + "/k3sm-appfloor-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
    }

    func stage(tag: String?) throws {
        let info: [String: Any] = tag.map { ["K3smPayloadTag": $0] } ?? ["CFBundleIdentifier": "io.k3sm.app"]
        try FileManager.default.createDirectory(atPath: stage + "/k3sm.app/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: stage + "/k3sm.app/Contents/Info.plist"))
    }

    func write(_ path: String, _ text: String) throws {
        try #require(FileManager.default.createFile(atPath: path, contents: Data(text.utf8)))
        try #require(chmod(path, 0o600) == 0)
    }

    func cleanUp() {
        _ = try? shell(["-c", "/bin/chmod -R u+rwx " + ShellQuote.quote(root) + " 2>/dev/null; /bin/rm -rf " + ShellQuote.quote(root)])
    }
}
