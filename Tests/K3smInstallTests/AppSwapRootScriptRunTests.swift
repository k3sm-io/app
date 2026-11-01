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

/// Runs the administrator swap root script itself, rendered over a scratch
/// root with stub `codesign`, `ditto` and `chown`, as this account in place
/// of root. The golden test pins the shipped text; these prove its refusals
/// fire when the script runs.
@Suite("the administrator swap root script, executed against hostile fixtures")
struct AppSwapRootScriptRunTests {
    static let team = TeamID("ABCDE12345")!

    enum Hostile: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case symlinkedApplications
        case symlinkedTarget
        case symlinkedHelper
        case targetNotOwned
        case groupWritableEntry
        case floorAboveInstalled
        case installedFailsRequirement
        case helperMissing
        case helperNotAFile
        case helperFailsRequirement

        var testDescription: String { rawValue }

        /// The status the script must exit with.
        var status: Int32 {
            switch self {
            case .symlinkedApplications, .symlinkedTarget: AppSwapRootExit.targetRefused
            // The target check refuses any symlink in the target's tree, so a
            // symlinked helper never reaches the copy or the helper check.
            case .symlinkedHelper, .targetNotOwned, .groupWritableEntry, .floorAboveInstalled: AppSwapRootExit.targetUntrusted
            case .installedFailsRequirement: CopyOutExit.signatureRejected
            case .helperMissing, .helperNotAFile, .helperFailsRequirement: AppSwapRootExit.helperRejected
            }
        }

        /// Whether the refusal comes after the copy of the installed bundle
        /// (one ditto) or before anything is copied (none).
        var copies: Bool {
            switch self {
            case .symlinkedApplications, .symlinkedTarget, .symlinkedHelper, .targetNotOwned, .groupWritableEntry: false
            case .floorAboveInstalled, .installedFailsRequirement, .helperMissing, .helperNotAFile, .helperFailsRequirement: true
            }
        }
    }

    @Test("the shipped render is the system-rooted render, and a scratch root needs no quoting")
    func renderRootsOnlyInTests() {
        #expect(AppSwapRootScriptBuilder.render(teamID: Self.team)
            == AppSwapRootScriptBuilder.render(teamID: Self.team, root: .system, owner: 0))
        #expect(ScriptRoot.system.prefix.isEmpty)
        for bad in ["", "/", "relative", "/trailing/", "/two words", "/it's", "/$(id)", "/a\nb", "/semi;colon",
                    "/.", "/..", "/a/./b", "/a/../b", "/a/..", "/a//b"] {
            #expect(ScriptRoot(prefix: bad) == nil, "\(bad)")
        }
        #expect(ScriptRoot(prefix: "/private/var/folders/ab/x_y-1.z/T") != nil)
        #expect(ScriptRoot(prefix: "/a/.hidden/..dots/b...") != nil)
    }

    @Test("an untouched installed bundle passes every check and its copy's helper runs as root with --admin-swap")
    func appSwapRootScriptRunsTheHelper() throws {
        let w = try SwapScriptWorld()
        defer { w.cleanUp() }
        let result = try w.run()
        #expect(result.status == 0, "\(result)")
        let calls = w.calls()
        #expect(calls.filter { $0.hasPrefix("ditto ") }.count == 1, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("codesign ") && $0.contains(#"identifier "io.k3sm.app""#) }, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("codesign ") && $0.contains(#"identifier "io.k3sm.app.update""#) }, "\(calls)")
        #expect(calls.last == "helper --admin-swap", "\(calls)")
        #expect(w.log().hasSuffix("copy-out: exit 0\n"), "\(w.log())")
        #expect(w.leftoverStages().isEmpty)
    }

    @Test("a symlinked Applications or target, an untrusted target, a target below root's floor and a rejected bundle or helper refuse, and no helper runs",
          arguments: Hostile.allCases)
    func appSwapRootScriptExecutesRefusals(_ c: Hostile) throws {
        let w = try SwapScriptWorld()
        defer { w.cleanUp() }
        var owner = getuid()
        let fm = FileManager.default
        switch c {
        case .symlinkedApplications:
            try fm.moveItem(atPath: w.applications, toPath: w.root + "/real-apps")
            try fm.createSymbolicLink(atPath: w.applications, withDestinationPath: w.root + "/real-apps")
        case .symlinkedTarget:
            try fm.moveItem(atPath: w.target, toPath: w.root + "/real-k3sm.app")
            try fm.createSymbolicLink(atPath: w.target, withDestinationPath: w.root + "/real-k3sm.app")
        case .symlinkedHelper:
            try fm.moveItem(atPath: w.helper, toPath: w.root + "/other-helper")
            try fm.createSymbolicLink(atPath: w.helper, withDestinationPath: w.root + "/other-helper")
        case .targetNotOwned:
            owner = getuid() + 1
        case .groupWritableEntry:
            try #require(chmod(w.target + "/Contents/MacOS", 0o775) == 0)
        case .floorAboveInstalled:
            try w.writeFloor("v2.0.0\n")
        case .installedFailsRequirement:
            try w.mark("fail-app")
        case .helperMissing:
            try fm.removeItem(atPath: w.helper)
        case .helperNotAFile:
            try fm.removeItem(atPath: w.helper)
            try fm.createDirectory(atPath: w.helper, withIntermediateDirectories: false)
        case .helperFailsRequirement:
            try w.mark("fail-helper")
        }
        let result = try w.run(owner: owner)
        #expect(result.status == c.status, "\(result) \(w.log())")
        let calls = w.calls()
        #expect(calls.filter { $0.hasPrefix("ditto ") }.count == (c.copies ? 1 : 0), "\(calls)")
        #expect(!calls.contains { $0.hasPrefix("helper") }, "\(calls)")
        if !c.copies { #expect(!calls.contains { $0.hasPrefix("codesign ") }, "\(calls)") }
        let helperChecked = calls.contains { $0.hasPrefix("codesign ") && $0.contains(#"identifier "io.k3sm.app.update""#) }
        #expect(helperChecked == (c == .helperFailsRequirement), "\(calls)")
        #expect(w.log().hasSuffix("copy-out: exit \(c.status)\n"), "\(w.log())")
        #expect(w.leftoverStages().isEmpty)
    }
}

/// SwapScriptWorld is one run's scratch root: the system tools the script
/// uses, linked under the root, stubs for `codesign`, `ditto` and `chown`
/// that record each call in `calls`, an installed bundle at the re-rooted
/// target whose helper records its run, and the log and staging folders the
/// script makes. Nothing in it runs privileged.
private final class SwapScriptWorld: @unchecked Sendable {
    let root: String
    var applications: String { root + AppSwapRoot.applicationsDirectory }
    var target: String { root + AppSwapRoot.target }
    var helper: String { target + "/" + AppSwapRoot.helperPath }
    var callLog: String { root + "/calls" }

    static let linkedTools = ["/usr/bin/stat", "/usr/bin/find", "/bin/cat", "/usr/bin/grep", "/usr/bin/plutil", "/usr/bin/awk",
                              "/bin/mkdir", "/bin/chmod", "/bin/rm", "/usr/bin/chflags", "/usr/bin/mktemp", "/usr/bin/head"]

    init() throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = realpath(NSTemporaryDirectory(), &buffer).map { String(cString: $0) } ?? NSTemporaryDirectory()
        root = tmp + "/k3sm-swapsh-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        for dir in ["/usr/bin", "/usr/sbin", "/bin", "/Library"] {
            try fm.createDirectory(atPath: root + dir, withIntermediateDirectories: true)
        }
        for tool in Self.linkedTools { try fm.createSymbolicLink(atPath: root + tool, withDestinationPath: tool) }
        try stub("/usr/bin/codesign", "echo \"codesign $*\" >> \(ShellQuote.quote(callLog))\n" + #"""
            case $* in
            *'identifier "io.k3sm.app.update"'*) [ ! -e \#(ShellQuote.quote(root + "/fail-helper")) ] ;;
            *'identifier "io.k3sm.app"'*) [ ! -e \#(ShellQuote.quote(root + "/fail-app")) ] ;;
            *) exit 1 ;;
            esac

            """#)
        try stub("/usr/bin/ditto", "echo \"ditto $*\" >> \(ShellQuote.quote(callLog))\n"
            + "for a; do src=${dst-}; dst=$a; done\nexec /usr/bin/ditto --norsrc --noextattr --noqtn --noacl \"$src\" \"$dst\"\n")
        try stub("/usr/sbin/chown", "echo \"chown $*\" >> \(ShellQuote.quote(callLog))\n")
        try fm.createDirectory(atPath: target + "/Contents/MacOS", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: target + "/Contents/Helpers", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "io.k3sm.app", "K3smPayloadTag": "v1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: target + "/Contents/Info.plist"))
        try write(target + "/Contents/MacOS/k3sm-app", "app", mode: 0o755)
        try write(helper, "#!/bin/sh\necho \"helper $*\" >> \(ShellQuote.quote(callLog))\n", mode: 0o755)
        try write(callLog, "", mode: 0o644)
    }

    func stub(_ tool: String, _ body: String) throws {
        try write(root + tool, "#!/bin/sh\n" + body, mode: 0o755)
    }

    func write(_ path: String, _ text: String, mode: mode_t) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try #require(chmod(path, mode) == 0)
    }

    func mark(_ name: String) throws { try write(root + "/" + name, "", mode: 0o644) }

    func writeFloor(_ text: String) throws { try write(root + AppSwapRoot.floorRecord, text, mode: 0o600) }

    /// Runs the re-rooted script under /bin/sh with the stubs first on PATH.
    func run(owner: uid_t = getuid()) throws -> (status: Int32, output: String) {
        let scriptRoot = try #require(ScriptRoot(prefix: root))
        let script = AppSwapRootScriptBuilder.render(teamID: AppSwapRootScriptRunTests.team, root: scriptRoot, owner: owner)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.text]
        process.environment = ["PATH": [root + "/usr/bin", root + "/bin", root + "/usr/sbin", "/usr/bin", "/bin"].joined(separator: ":")]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func calls() -> [String] {
        ((try? String(contentsOfFile: callLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("chown ") }
    }

    func log() -> String { (try? String(contentsOfFile: root + CopyOutPlan.logPath, encoding: .utf8)) ?? "" }

    func leftoverStages() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root + CopyOutPlan.stagingRoot)) ?? [])
            .filter { $0.hasPrefix("app-swap-helper.") }
    }

    func cleanUp() {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwx", root]
        try? chmod.run()
        chmod.waitUntilExit()
        try? FileManager.default.removeItem(atPath: root)
    }
}
