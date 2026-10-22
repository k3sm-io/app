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
@testable import K3smInstall
import K3smStatus
import Testing

/// The app swap's root step: the script refuses every hostile shape of the
/// target, the console user, the work folder and the helper, and carries no
/// path from the app.
@Suite("app swap root script", .serialized)
struct AppSwapScriptTests {
    static let team = TeamID("ABCDE12345")!

    /// A scratch layout: an Applications folder holding k3sm.app with a
    /// bundled helper, a work folder path, and a console stand-in owned by
    /// this account.
    final class Layout: @unchecked Sendable {
        let root: String
        var applications: String { root + "/Applications" }
        var target: String { applications + "/k3sm.app" }
        var helper: String { target + "/" + AppSwapPaths.bundledHelper }
        var work: String { root + "/work" }
        var console: String { root + "/console" }

        init() {
            let base = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")).map { "/" + $0 } ?? "/private/tmp"
            root = base + "/k3sm-appswap-" + UUID().uuidString.prefix(8)
            let fm = FileManager.default
            try? fm.createDirectory(atPath: target + "/Contents/Helpers", withIntermediateDirectories: true)
            fm.createFile(atPath: console, contents: Data())
        }

        deinit {
            _ = try? shell(["-c", "/bin/chmod -R u+rwx '\(root)' 2>/dev/null; /bin/rm -rf '\(root)'"])
        }

        var scriptLayout: AppSwapScriptBuilder.Layout {
            AppSwapScriptBuilder.Layout(applications: applications, workDirectory: work, consoleDevice: console,
                                        owner: "\(getuid()):\(getgid())")
        }

        /// Puts `source` at the bundled helper's place (a copy, keeping its
        /// signature).
        func installHelper(from source: String) {
            #expect(run("/usr/bin/ditto", [source, helper]) == 0)
        }

        func helperCopies() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).filter { $0.hasPrefix(AppSwapPaths.helperPrefix) }
        }
    }

    /// Runs a rendered script the way the runner does (`env -i`, no stdin)
    /// and returns its status and standard error.
    static func execute(_ script: RootScript) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["-i", "PATH=" + K3smCLI.systemPath, "/bin/sh", "-c", script.text]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func run(_ path: String, _ arguments: [String]) -> Int32 { Self.run(path, arguments) }

    /// A tiny helper stand-in, ad-hoc signed as `io.k3sm.app.update`, that
    /// writes its arguments next to itself in `ran`.
    static let recordingHelper: String = {
        let dir = NSTemporaryDirectory() + "k3sm-appswap-helper-" + String(getpid())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = dir + "/helper.c"
        let program = #"""
            #include <stdio.h>
            #include <string.h>
            #include <libgen.h>
            int main(int argc, char **argv) {
                char path[4096];
                char self[4096];
                strncpy(self, argv[0], sizeof self - 1);
                self[sizeof self - 1] = 0;
                snprintf(path, sizeof path, "%s/ran", dirname(self));
                FILE *f = fopen(path, "w");
                if (!f) return 1;
                for (int i = 1; i < argc; i++) fprintf(f, "%s\n", argv[i]);
                fclose(f);
                return 0;
            }
            """#
        FileManager.default.createFile(atPath: source, contents: Data(program.utf8))
        let binary = dir + "/k3sm-app-update"
        precondition(run("/usr/bin/cc", ["-O0", "-o", binary, source]) == 0, "cc could not compile the helper stand-in")
        precondition(run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "io.k3sm.app.update", binary]) == 0,
                     "codesign could not sign the helper stand-in")
        return binary
    }()

    /// HostileTarget is one shape the script must refuse, and the status.
    enum HostileTarget: String, CaseIterable, Sendable {
        case symlinkedApplications
        case symlinkedTarget
        case targetIsAFile
        case consoleIsAnotherUser
        case symlinkedWorkFolder
        case workFolderIsAFile
        case symlinkedHelpersFolder
        case symlinkedHelper
        case helperIsAFolder
        case helperFailsRequirement
        case helperWithAnotherIdentifier

        var status: AppSwapExit {
            switch self {
            case .consoleIsAnotherUser: return .consoleUser
            case .helperFailsRequirement, .helperWithAnotherIdentifier: return .helperRejected
            default: return .refusedPath
            }
        }
    }

    /// The named gate: every hostile shape is refused with its status, the
    /// helper never runs, and no helper copy is left behind.
    @Test(arguments: HostileTarget.allCases)
    func appSwapRootScriptRefusesHostileTarget(_ hostile: HostileTarget) throws {
        let l = Layout()
        let fm = FileManager.default
        var uid = UInt32(getuid())
        var requirement = #"identifier "io.k3sm.app.update""#
        l.installHelper(from: Self.recordingHelper)
        switch hostile {
        case .symlinkedApplications:
            try fm.moveItem(atPath: l.applications, toPath: l.root + "/RealApplications")
            try fm.createSymbolicLink(atPath: l.applications, withDestinationPath: l.root + "/RealApplications")
        case .symlinkedTarget:
            try fm.moveItem(atPath: l.target, toPath: l.root + "/elsewhere.app")
            try fm.createSymbolicLink(atPath: l.target, withDestinationPath: l.root + "/elsewhere.app")
        case .targetIsAFile:
            try fm.removeItem(atPath: l.target)
            fm.createFile(atPath: l.target, contents: Data("x".utf8))
        case .consoleIsAnotherUser:
            uid += 1
        case .symlinkedWorkFolder:
            try fm.createDirectory(atPath: l.root + "/realwork", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: l.work, withDestinationPath: l.root + "/realwork")
        case .workFolderIsAFile:
            fm.createFile(atPath: l.work, contents: Data())
        case .symlinkedHelpersFolder:
            try fm.moveItem(atPath: l.target + "/Contents/Helpers", toPath: l.root + "/Helpers")
            try fm.createSymbolicLink(atPath: l.target + "/Contents/Helpers", withDestinationPath: l.root + "/Helpers")
        case .symlinkedHelper:
            try fm.removeItem(atPath: l.helper)
            try fm.createSymbolicLink(atPath: l.helper, withDestinationPath: Self.recordingHelper)
        case .helperIsAFolder:
            try fm.removeItem(atPath: l.helper)
            try fm.createDirectory(atPath: l.helper, withIntermediateDirectories: true)
        case .helperFailsRequirement:
            // The real requirement for a team: an ad-hoc signature has no
            // Developer ID chain.
            requirement = AppUpdateTrust.helperRequirement(teamID: Self.team)
        case .helperWithAnotherIdentifier:
            // It satisfies the requirement it is checked against, but it is
            // not the helper.
            #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "io.k3sm.other", l.helper]) == 0)
            requirement = #"identifier "io.k3sm.other""#
        }
        let script = try #require(AppSwapScriptBuilder.render(helperRequirement: requirement, uid: uid, appPid: 4242,
                                                             appStart: 1_700_000_000_123_456, layout: l.scriptLayout))
        let result = try Self.execute(script)
        #expect(result.status == hostile.status.rawValue, "\(hostile): \(result.error)")
        #expect(result.error.contains("app-swap: refused:"))
        // The helper never ran, and no copy of it is left.
        #expect(!fm.fileExists(atPath: l.work + "/ran"))
        #expect(!fm.fileExists(atPath: l.root + "/realwork/ran"))
        #expect(l.helperCopies().isEmpty)
    }

    /// The safe shape: the work folder is made private, the helper is
    /// copied there 0500 and run with exactly the three integers.
    @Test func appSwapRootScriptRunsOnlyTheVerifiedCopy() throws {
        let l = Layout()
        l.installHelper(from: Self.recordingHelper)
        let script = try #require(AppSwapScriptBuilder.render(helperRequirement: #"identifier "io.k3sm.app.update""#,
                                                             uid: UInt32(getuid()), appPid: 4242, appStart: 1_700_000_000_123_456,
                                                             layout: l.scriptLayout))
        let result = try Self.execute(script)
        #expect(result.status == 0, "\(result.error)")
        let ran = try String(contentsOfFile: l.work + "/ran", encoding: .utf8)
        #expect(ran == "--root-swap\n\(getuid())\n4242\n1700000000123456\n")
        var st = stat()
        #expect(lstat(l.work, &st) == 0 && st.st_mode & 0o777 == 0o700 && st.st_uid == getuid())
        let copies = l.helperCopies()
        #expect(copies.count == 1)
        let copy = l.work + "/" + (copies.first ?? "")
        #expect(lstat(copy, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_mode & 0o7777 == 0o500)
        // It is a copy, not the bundled file.
        var bundled = stat()
        #expect(lstat(l.helper, &bundled) == 0 && bundled.st_ino != st.st_ino)
    }

    /// "A request file naming another path": the script carries no path
    /// from the app or the request file. Its only values are three integers
    /// and the requirement; every path in it is a compiled constant.
    @Test func appSwapRootScriptTakesNoPathFromTheApp() throws {
        let script = try #require(AppSwapScriptBuilder.render(teamID: Self.team, uid: 501, appPid: 4242, appStart: 1_700_000_000_123_456))
        for fragment in ["request", "journal", "Application Support", "/Users", "$HOME", "~", "staged", "io.k3sm.app/update"] {
            #expect(!script.text.contains(fragment), "the root script names \(fragment)")
        }
        #expect(script.text.contains("target='/Applications/k3sm.app'\n"))
        #expect(script.text.contains("work='/Library/k3sm.app-update'\n"))
        #expect(!script.text.contains("k3sm.staging"))
        #expect(script.text.contains("exec \"$helper\" --root-swap \"$uid\" 4242 1700000000123456\n"))
        #expect(script.prompt == AppSwapScriptBuilder.prompt)
        #expect(!script.readsInput)
        #expect(!script.usesStagingLock)
        #expect(script.result == .discarded)
        // No uid 0, no pid 0.
        #expect(AppSwapScriptBuilder.render(teamID: Self.team, uid: 0, appPid: 4242, appStart: 1) == nil)
        #expect(AppSwapScriptBuilder.render(teamID: Self.team, uid: 501, appPid: 0, appStart: 1) == nil)
        // The work folder is outside the copy-out's swept staging root.
        #expect(!AppSwapPaths.workDirectory.hasPrefix(CopyOutPlan.stagingRoot))
        #expect(!CopyOutPlan.stagingRoot.hasPrefix(AppSwapPaths.workDirectory))
    }

    @Test func goldenAppSwapScript() throws {
        let script = try #require(AppSwapScriptBuilder.render(teamID: Self.team, uid: 501, appPid: 4242, appStart: 1_700_000_000_123_456))
        #expect(script.text == Self.golden)
    }

    /// The statuses sit apart from every other root step's.
    @Test func appSwapExitStatusesDoNotCollide() {
        let others: Set<Int32> = [CopyOutExit.refusedPath, CopyOutExit.refusedTree, CopyOutExit.missingToken, CopyOutExit.busy,
                                  CopyOutExit.signatureRejected, LifecycleExit.failed, LifecycleExit.usage, LifecycleExit.needsRoot,
                                  LifecycleExit.lanRestoreFailed, LifecycleExit.refusedBinary, LifecycleExit.signatureRejected,
                                  BundledRollExit.recordRefused, BundledRollExit.tagMismatch, BundledRollExit.digestRefused,
                                  BundledRollExit.recordUnreadable]
        let leftovers = Set((LifecycleExit.stopLeftoverBase...95).map { $0 })
        for exit in AppSwapExit.allCases where exit != .committed {
            #expect(!others.contains(exit.rawValue) && !leftovers.contains(exit.rawValue), "\(exit) collides")
            #expect(AppSwapOutcome.text(exitStatus: exit.rawValue) != nil)
        }
        #expect(AppSwapOutcome.text(exitStatus: 0) == nil)
        #expect(AppSwapOutcome.text(exitStatus: 1) != nil)
    }

    /// The app swap needs no admin-group account; every other privileged
    /// action still does.
    @Test func appSwapAvailabilityNeedsNoAdminAccount() {
        #expect(PrivilegedAvailability.evaluateAppSwap(teamID: Self.team, signatureValid: true) == .enabled)
        #expect(PrivilegedAvailability.evaluateAppSwap(teamID: nil, signatureValid: true) != .enabled)
        #expect(PrivilegedAvailability.evaluateAppSwap(teamID: Self.team, signatureValid: false) != .enabled)
        #expect(PrivilegedAvailability.evaluate(teamID: Self.team, signatureValid: true, userIsAdmin: false) != .enabled)
    }

    static let golden = #"""
        set -eu
        umask 077
        cd /
        apps='/Applications'
        target='/Applications/k3sm.app'
        work='/Library/k3sm.app-update'
        console='/dev/console'
        uid=501
        helper=
        refuse() {
        	echo "app-swap: refused: $2" >&2
        	exit "$1"
        }
        cleanup() {
        	if [ -n "$helper" ]; then /bin/rm -f "$helper"; fi
        }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM
        if [ -L "$apps" ] || [ ! -d "$apps" ]; then refuse 106 'the Applications folder is a symlink or not a folder'; fi
        if [ -L "$target" ] || [ ! -d "$target" ]; then refuse 106 'k3sm.app in Applications is a symlink or not a folder'; fi
        owner=$(/usr/bin/stat -f %u "$console") || refuse 107 'the console user could not be read'
        if [ "$owner" != "$uid" ]; then refuse 107 'the console user is not the account that asked'; fi
        if [ -L "$work" ]; then refuse 106 'the work folder is a symlink'; fi
        if [ -e "$work" ] && [ ! -d "$work" ]; then refuse 106 'the work folder is not a folder'; fi
        if [ ! -d "$work" ]; then /bin/mkdir -m 0700 "$work"; fi
        /usr/sbin/chown 'root:wheel' "$work"
        /bin/chmod 0700 "$work"
        if [ -L "$work" ] || [ ! -d "$work" ]; then refuse 106 'the work folder is a symlink'; fi
        for p in "$target"/'Contents' "$target"/'Contents/Helpers'; do
        	if [ -L "$p" ] || [ ! -d "$p" ]; then refuse 106 'a folder inside k3sm.app is a symlink or missing'; fi
        done
        src="$target"/'Contents/Helpers/k3sm-app-update'
        if [ -L "$src" ] || [ ! -f "$src" ]; then refuse 106 'the bundled helper is a symlink or not a regular file'; fi
        helper=$(/usr/bin/mktemp "$work"/'helper.XXXXXXXX')
        /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$src" "$helper"
        if [ -L "$helper" ] || [ ! -f "$helper" ]; then refuse 108 'the helper copy is not a regular file'; fi
        /usr/sbin/chown 'root:wheel' "$helper"
        /bin/chmod 0500 "$helper"
        if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app.update"' "$helper"; then refuse 108 'the helper is not signed by the k3sm Developer ID'; fi
        ident=$(/usr/bin/codesign --display --verbose=1 "$helper" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p') || ident=
        if [ "$ident" != 'io.k3sm.app.update' ]; then refuse 108 'the helper does not carry its identifier'; fi
        trap - EXIT
        exec "$helper" --root-swap "$uid" 4242 1700000000123456

        """#
}
