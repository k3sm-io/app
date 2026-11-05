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
import Synchronization
import Testing

import K3smStatus
@testable import K3smInstall
@testable import K3smSwap

/// The administrator path for the app swap: the root script, byte for byte,
/// and the root half it runs (`AdminSwapEngine`) over ad-hoc signed fixture
/// bundles, with every hostile target the plan names.
@Suite struct AppSwapRootTests {
    static let team = TeamID("ABCDE12345")!

    // MARK: the root script

    static let goldenTargetCheck = #"""
        tagrank() {
        	case $tag in ''|*[!0-9a-z.-]*) return 1 ;; esac
        	printf '%s\n' "$tag" | /usr/bin/grep -Eqx 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?' || return 1
        	core=${tag#v}
        	rc=99999
        	case $core in *-rc.*) rc=${core#*-rc.}; core=${core%%-*} ;; esac
        	major=${core%%.*}
        	rest=${core#*.}
        	printf '%09d%09d%09d%05d\n' "$major" "${rest%%.*}" "${rest#*.}" "$rc"
        }
        apps='/Applications'
        target='/Applications/k3sm.app'
        if [ -L "$apps" ] || [ ! -d "$apps" ] || [ -L "$target" ] || [ ! -d "$target" ]; then
        	echo 'app-swap: refused: Applications or k3sm.app in it is a symlink or not a folder'
        	exit 120
        fi
        if ! foreign=$(/usr/bin/find "$target" ! -user 0 -print -quit); then
        	echo 'app-swap: refused: k3sm.app in Applications could not be read'
        	exit 115
        fi
        if ! bad=$(/usr/bin/find "$target" \( -perm +022 -o -acl -o ! \( -type f -o -type d \) -o \( -type f -links +1 \) \) -print -quit); then
        	echo 'app-swap: refused: k3sm.app in Applications could not be read'
        	exit 115
        fi
        if [ -n "$bad" ]; then
        	echo 'app-swap: refused: k3sm.app holds an entry writable by group or others, with an ACL, or not a plain file or folder'
        	exit 115
        fi
        record='/Library/k3sm.app-floor'
        floor=
        if [ -e "$record" ] || [ -L "$record" ]; then
        	if [ -L "$record" ] || [ ! -f "$record" ] || [ "$(/usr/bin/stat -f '%u %Lp %l' "$record")" != '0 600 1' ] || [ "$(/usr/bin/stat -f %z "$record")" -gt 128 ]; then
        		echo 'app-swap: refused: the floor record is not a root-owned 0600 file'
        		exit 115
        	fi
        	tag=$(/bin/cat "$record")
        	if [ "$(/usr/bin/stat -f %z "$record")" != "$((${#tag} + 1))" ] || ! tagrank > /dev/null; then
        		echo 'app-swap: refused: the floor record does not hold one release tag'
        		exit 115
        	fi
        	floor=$tag
        fi

        """#

    static let goldenTail = #"""
        if [ -n "$floor" ]; then
        	tag=$floor
        	floorrank=$(tagrank)
        	tag=$(/usr/bin/plutil -extract K3smPayloadTag raw -o - "$stage"/'k3sm.app'/'Contents/Info.plist' 2>/dev/null) || tag=
        	if ! installedrank=$(tagrank); then
        		echo 'app-swap: refused: the installed k3sm.app carries no release tag'
        		exit 115
        	fi
        	if [ "$(/usr/bin/awk -v a="$installedrank" -v b="$floorrank" 'BEGIN { print ("" a < "" b) }')" != 0 ]; then
        		echo 'app-swap: refused: the installed k3sm.app is older than the release root installed last'
        		exit 115
        	fi
        fi
        if [ -n "$foreign" ]; then
        tagrank() {
        	case $tag in ''|*[!0-9a-z.-]*) return 1 ;; esac
        	printf '%s\n' "$tag" | /usr/bin/grep -Eqx 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?' || return 1
        	core=${tag#v}
        	rc=99999
        	case $core in *-rc.*) rc=${core#*-rc.}; core=${core%%-*} ;; esac
        	major=${core%%.*}
        	rest=${core#*.}
        	printf '%09d%09d%09d%05d\n' "$major" "${rest%%.*}" "${rest#*.}" "$rc"
        }
        record='/Library/k3sm.app-floor'
        if [ ! -e "$record" ] && [ ! -L "$record" ]; then
        	tag=$(/usr/bin/plutil -extract K3smPayloadTag raw -o - "$stage"/'k3sm.app'/'Contents/Info.plist' 2>/dev/null) || tag=
        	if tagrank > /dev/null; then
        		copytag=$tag
        		copyrank=$(tagrank)
        		tag='v0.2.4-rc.0'
        		if [ "$(/usr/bin/awk -v a="$copyrank" -v b="$(tagrank)" 'BEGIN { print ("" a < "" b) }')" = 0 ]; then tag=$copytag; fi
        		printf '%s\n' "$tag" > "$stage"/'app-floor'
        		/usr/sbin/chown 0 "$stage"/'app-floor'
        		/bin/chmod 0600 "$stage"/'app-floor'
        		/bin/mv -f "$stage"/'app-floor' "$record"
        		echo "copy-out: recorded $tag as the app release floor"
        	fi
        fi
        	tag=$(/usr/bin/plutil -extract K3smPayloadTag raw -o - "$stage"/'k3sm.app'/'Contents/Info.plist' 2>/dev/null) || tag=
        	if ! copyrank=$(tagrank); then
        		echo 'app-swap: refused: k3sm.app in Applications is not owned by root and carries no release tag'
        		exit 115
        	fi
        	tag='v0.2.4-rc.0'
        	if [ "$(/usr/bin/awk -v a="$copyrank" -v b="$(tagrank)" 'BEGIN { print ("" a < "" b) }')" != 0 ]; then
        		echo 'app-swap: refused: k3sm.app in Applications is not owned by root and is older than the lowest release this path accepts from it'
        		exit 115
        	fi
        	echo 'app-swap: k3sm.app in Applications is not owned by root; the swap replaces it with a copy root owns'
        fi
        helper="$stage"/'k3sm.app'/'Contents/Helpers/k3sm-app-update'
        if [ -L "$helper" ] || [ ! -f "$helper" ]; then
        	echo 'app-swap: refused: the installed helper is missing or not a regular file'
        	exit 121
        fi
        /bin/chmod 0500 "$helper"
        if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app.update"' "$helper"; then
        	echo 'app-swap: refused: the installed helper is not signed by the k3sm Developer ID'
        	exit 121
        fi
        echo 'app-swap: running the installed helper as root'
        "$helper" '--admin-swap'

        """#

    @Test("the script, byte for byte: the target check, the copy-out's staged copy of the installed bundle, its helper as root")
    func goldenScript() throws {
        let script = AppSwapRootScriptBuilder.render(teamID: Self.team)
        #expect(AppSwapRootScriptBuilder.targetCheck == Self.goldenTargetCheck)
        let staged = RootScriptBuilder.stagedCopy(
            bundlePath: "/Applications/k3sm.app", stagingTemplate: "/Library/k3sm.staging/app-swap-helper.XXXXXXXX",
            designatedRequirement: #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app" and notarized"#,
            beforeCopy: Self.goldenTargetCheck)
        #expect(script.text == staged + Self.goldenTail)
        #expect(script.prompt == "k3sm wants to replace k3sm.app in Applications with the update it downloaded and verified.")
        #expect(!script.readsInput && script.usesStagingLock && script.result == .discarded)
        let line = script.command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/lockf -k -t 0 '/Library/k3sm.staging.lock' /bin/sh -c "))
        #expect(try shell(["-n", "-c", script.text]).status == 0)
    }

    @Test("the verb takes no path: the target is the constant, checked before the copy, and only the copy's helper runs")
    func closedVerb() throws {
        let text = AppSwapRootScriptBuilder.render(teamID: Self.team).text
        func at(_ s: String) throws -> String.Index { try #require(text.range(of: s), "missing \(s)").lowerBound }
        #expect(try at("exit 120") < at("/usr/bin/ditto"))
        #expect(try at("/usr/bin/ditto") < at("codesign --verify --strict --deep"))
        #expect(try at("codesign --verify --strict --deep") < at("helper=\"$stage\""))
        #expect(try at("helper=\"$stage\"") < at("\"$helper\" '--admin-swap'"))
        // Only the constant target and the stage name anything to run or copy.
        let named = text.split(separator: "\n").filter { $0.contains("/Applications/k3sm.app") }
        #expect(named.count == 2, "\(named)")
        #expect(named.contains { $0.hasPrefix("target=") } && named.contains { $0.hasPrefix("/usr/bin/ditto ") })
        #expect(!text.contains("io.k3sm.app/update") && !text.contains("request.json") && !text.contains("$1"))
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("\"$helper\"") } == ["\"$helper\" '--admin-swap'"])
    }

    @Test("the relaunch runs the user's helper as the user, in the console session, by absolute path")
    func relaunchArguments() {
        #expect(AppSwapRoot.relaunchArguments(uid: 501, home: "/Users/kit") == [
            "/bin/launchctl", "asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--",
            "/Users/kit/Library/Application Support/io.k3sm.app/update/k3sm-app-update", "--relaunch",
        ])
        #expect(ConsoleAccount(uid: 501, home: "/Users/kit").stagedBundle
            == "/Users/kit/Library/Application Support/io.k3sm.app/admin-staging/k3sm.app")
    }

    // MARK: the root half, over fixtures

    enum Hostile: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case symlinkedTarget
        case targetSwappedBeforeRename
        case requestNamesAnotherPath
        case stagedOnAnotherVolume
        case workOnAnotherVolume
        case lowerTag
        case equalTag

        var testDescription: String { rawValue }
    }

    @Test("every hostile target is refused or ignored, and no path but the constant target is renamed",
          arguments: Hostile.allCases)
    func appSwapRootScriptRefusesHostileTarget(_ hostile: Hostile) throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        switch hostile {
        case .symlinkedTarget:
            // The target is a symlink to a real, older bundle elsewhere.
            let elsewhere = s.root + "/Elsewhere/k3sm.app"
            s.makeBundle(at: elsewhere, tag: "v1.0.0")
            try FileManager.default.createSymbolicLink(atPath: s.target, withDestinationPath: elsewhere)
            s.stage(tag: "v1.1.0")
            let before = (identity(elsewhere), identity(s.target), identity(s.staged))
            #expect(s.engine().run() == AppSwapRootExit.targetRefused)
            #expect((identity(elsewhere), identity(s.target), identity(s.staged)) == before)
            #expect(s.tag(at: elsewhere) == "v1.0.0")
            s.expectNothingLeft()

        case .targetSwappedBeforeRename:
            // Between the last check and the rename, the target is moved
            // away and another directory put in its place.
            s.install(tag: "v1.0.0")
            s.stage(tag: "v1.1.0")
            let moved = s.root + "/Moved"
            try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
            let decoy = s.root + "/Decoy/k3sm.app"
            s.makeBundle(at: decoy, tag: "v0.5.0")
            let original = identity(s.target)
            let decoyID = identity(decoy)
            let renamer = ReplacingRenamer(target: s.target, movedTo: moved + "/k3sm.app", replacement: decoy)
            #expect(s.engine(renamer: renamer).run() == AppSwapRootExit.targetRefused)
            // The swap was undone: the replacement is back at the target, the
            // original is where the attacker put it, the staged copy untouched.
            #expect(identity(s.target) == decoyID)
            #expect(identity(moved + "/k3sm.app") == original)
            #expect(s.tag(at: s.target) == "v0.5.0" && s.tag(at: s.staged) == "v1.1.0")
            #expect(renamer.swaps == 2)
            s.expectNothingLeft()

        case .requestNamesAnotherPath:
            // The user's request file names another Applications folder and a
            // valid staged bundle in it; root never reads it, and the
            // compiled staging location is empty.
            s.install(tag: "v1.0.0")
            let other = s.root + "/OtherApps"
            let paths = SwapPaths(home: s.home, applicationsRoots: [other])
            let name = SwapPaths.newStagingName()
            s.makeBundle(at: other + "/" + name + "/k3sm.app", tag: "v1.1.0")
            s.makeBundle(at: other + "/k3sm.app", tag: "v1.0.0")
            let store = JournalStore(paths: paths)
            try store.prepare()
            try store.write(SwapJournal(request: SwapRequest(
                mode: .update, target: other + "/k3sm.app", stagedName: name, expectedTag: "v1.1.0",
                token: SwapRequest.newToken(), app: try #require(ProcessIdentity.current()))))
            let before = (identity(s.target), identity(other + "/k3sm.app"), identity(other + "/" + name + "/k3sm.app"))
            #expect(s.engine().run() == AppSwapRootExit.stagedRefused)
            #expect((identity(s.target), identity(other + "/k3sm.app"), identity(other + "/" + name + "/k3sm.app")) == before)
            #expect(s.tag(at: s.target) == "v1.0.0")
            s.expectNothingLeft()

        case .stagedOnAnotherVolume:
            // The home folder is another volume. The staged bundle is never
            // renamed: root copies it onto the target's volume and swaps the
            // copy.
            let volume = try MountedVolume(name: "k3smhome")
            defer { volume.detach() }
            let t = AdminScratch(home: volume.mount + "/home")
            defer { t.cleanUp() }
            t.install(tag: "v1.0.0")
            t.stage(tag: "v1.1.0")
            let staged = identity(t.staged)
            #expect(t.engine().run() == 0)
            #expect(identity(t.staged) == staged, "the staged bundle moved")
            #expect(t.tag(at: t.staged) == "v1.1.0" && t.tag(at: t.target) == "v1.1.0")
            #expect(identity(t.target) != staged)
            #expect(AdminSwapEngine.sameVolume(AdminSwapEngine.fsid(t.target), AdminSwapEngine.fsid(t.applications)))
            #expect(t.relaunched == [t.account])
            t.expectNothingLeft()

        case .workOnAnotherVolume:
            // Root's own copy would land on another volume than the target:
            // refused before anything is copied or renamed.
            let volume = try MountedVolume(name: "k3smwork")
            defer { volume.detach() }
            let t = AdminScratch(workRoot: volume.mount + "/work")
            defer { t.cleanUp() }
            t.install(tag: "v1.0.0")
            t.stage(tag: "v1.1.0")
            let before = (identity(t.target), identity(t.staged))
            #expect(t.engine().run() == AppSwapRootExit.volumeRefused)
            #expect((identity(t.target), identity(t.staged)) == before)
            #expect(t.relaunched.isEmpty)

        case .lowerTag, .equalTag:
            s.install(tag: "v1.0.0")
            s.stage(tag: hostile == .lowerTag ? "v0.9.0" : "v1.0.0")
            let before = (identity(s.target), identity(s.staged))
            #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
            #expect((identity(s.target), identity(s.staged)) == before)
            #expect(s.tag(at: s.target) == "v1.0.0")
            s.expectNothingLeft()
        }
    }

    enum Untrusted: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case userOwnedTree
        case groupWritableEntry
        case olderTargetBelowRootFloor
        case floorRecordNotPrivate
        case symlinkEntry
        case hardLinkEntry
        case aclEntry
        case floorRecordNoNewline
        case floorRecordOverLongTag

        var testDescription: String { rawValue }
    }

    @Test("a target tree another account owns with no floor record, an unsafe tree, or a target below root's own floor, is refused before anything is copied",
          arguments: Untrusted.allCases)
    func appSwapRefusesNonRootOwnedTarget(_ untrusted: Untrusted) throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        let before = (identity(s.target), identity(s.staged))
        switch untrusted {
        case .userOwnedTree:
            // The target's tree reads as another account's and root has no
            // floor record: its own tag cannot be the floor, so nothing moves.
            let inspector = OwnerOverride(prefix: s.target, owner: getuid() + 1)
            #expect(s.engine(inspector: inspector).run() == AppSwapRootExit.targetUntrusted)
        case .groupWritableEntry:
            try #require(chmod(s.target + "/Contents/Resources", 0o775) == 0)
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .olderTargetBelowRootFloor:
            // Root installed v1.2.0; an older genuine release now sits at the
            // target, and the staged bundle is above it but below root's floor.
            s.writeFloor("v1.2.0\n")
            #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        case .floorRecordNotPrivate:
            s.writeFloor("v0.1.0\n", mode: 0o644)
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .symlinkEntry:
            try FileManager.default.createSymbolicLink(atPath: s.target + "/Contents/Resources/link", withDestinationPath: "/etc/passwd")
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .hardLinkEntry:
            try #require(link(s.target + "/Contents/Info.plist", s.root + "/outside-link") == 0)
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .aclEntry:
            try #require(run("/bin/chmod", ["+a", "everyone allow read", s.target + "/Contents/Info.plist"]) == 0)
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .floorRecordNoNewline:
            s.writeFloor("v0.1.0")
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        case .floorRecordOverLongTag:
            s.writeFloor("v0.1.0-" + String(repeating: "a", count: 200) + "\n")
            #expect(s.engine().run() == AppSwapRootExit.targetUntrusted)
        }
        #expect((identity(s.target), identity(s.staged)) == before)
        #expect(s.tag(at: s.target) == "v1.0.0" && s.relaunched.isEmpty)
        s.expectNothingLeft()
    }

    // MARK: a bundle an account dragged to Applications

    /// A group this account belongs to other than `gid`, which stands in for
    /// root's group: a test cannot chown a file to root, but it can move it
    /// between its own groups, so the adopted copy's group is observable.
    static func anotherGroup(than gid: gid_t) throws -> gid_t {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return try #require(groups.prefix(Int(max(count, 0))).first { $0 != gid })
    }

    @Test("a target another account owns does not pass its top directory's mode to root's copy; a tree root's alone keeps its own")
    func appSwapForeignTargetCopyIsMode0755() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        s.makeBundle(at: s.helperCopy, tag: "v1.0.0")
        s.writeFloor("v1.0.0\n")
        try #require(chmod(s.target, 0o750) == 0)
        #expect(s.engine(inspector: OwnerOverride(prefix: s.target, owner: getuid() + 1), installedCopy: s.helperCopy).run() == 0)
        var after = stat()
        try #require(lstat(s.target, &after) == 0)
        #expect(after.st_mode & 0o7777 == 0o755)
        // A tree root's alone keeps what an administrator chose.
        try #require(chmod(s.target, 0o750) == 0)
        try FileManager.default.removeItem(atPath: s.staged)
        s.stage(tag: "v1.2.0")
        #expect(s.engine().run() == 0)
        try #require(lstat(s.target, &after) == 0)
        #expect(after.st_mode & 0o7777 == 0o750)
    }

    @Test("what the engine knows of a target another account owns comes from the verified copy: a live Info.plist changed under it is not read")
    func appSwapForeignTargetIsReadFromTheVerifiedCopy() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        s.makeBundle(at: s.helperCopy, tag: "v1.0.0")
        s.writeFloor("v1.0.0\n")
        try Data("not a property list".utf8).write(to: URL(fileURLWithPath: s.target + "/Contents/Info.plist"))
        #expect(s.engine(inspector: OwnerOverride(prefix: s.target, owner: getuid() + 1), installedCopy: s.helperCopy).run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        // The old bundle is named for the copy's tag.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: s.previousRoot)) == ["k3sm-v1.0.0.previous"])
    }

    @Test("a target another account owns with no verified copy to read is refused")
    func appSwapForeignTargetNeedsTheVerifiedCopy() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        s.writeFloor("v1.0.0\n")
        #expect(s.engine(inspector: OwnerOverride(prefix: s.target, owner: getuid() + 1)).run() == AppSwapRootExit.targetUntrusted)
        #expect(s.tag(at: s.target) == "v1.0.0" && s.relaunched.isEmpty)
    }

    struct AdoptionCase: CustomTestStringConvertible, Sendable {
        let record: String?
        let copy: String
        let accept: Bool
        let after: String
        var testDescription: String { "record \(record ?? "none"), copy \(copy)" }
    }

    static let minimum = AppSwapRoot.minimumAdoptedRelease

    @Test("a foreign target's copy must reach the compiled minimum, with or without a record, and the seed is the higher of the two",
          arguments: [
              AdoptionCase(record: nil, copy: "v0.1.0", accept: false, after: minimum),
              AdoptionCase(record: "v0.1.0", copy: "v0.1.0", accept: false, after: "v0.1.0"),
              AdoptionCase(record: nil, copy: minimum, accept: true, after: minimum),
              AdoptionCase(record: nil, copy: "v1.0.0", accept: true, after: "v1.0.0"),
              AdoptionCase(record: "v0.1.0", copy: "v1.0.0", accept: true, after: "v0.1.0"),
          ])
    func appSwapAdoptionHoldsTheCompiledMinimum(_ c: AdoptionCase) throws {
        let w = ShellScratch()
        defer { w.cleanUp() }
        if let record = c.record { w.writeRecord(record + "\n") }
        let stage = w.root + "/stage"
        try FileManager.default.createDirectory(atPath: stage + "/k3sm.app/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["K3smPayloadTag": c.copy], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: stage + "/k3sm.app/Contents/Info.plist"))
        let text = "set -eu\numask 077\nforeign=x\nstage=" + ShellQuote.quote(stage) + "\n"
            + AppSwapRootScriptBuilder.adoption(record: w.record, owner: getuid()) + "echo passed\n"
        let result = try shell(["-c", text])
        #expect(result.status == (c.accept ? 0 : AppSwapRootExit.targetUntrusted), "\(result)")
        #expect(result.output.hasSuffix("passed\n") == c.accept, "\(result)")
        #expect((try? String(contentsOfFile: w.record, encoding: .utf8)) == c.after + "\n")
        #expect(AppVersion.releaseTagVersion(Self.minimum) != nil)
    }

    /// `hack/root-swap-leg.sh` is how this runs: as root, over a scratch path
    /// only. Off unless that script armed it, so it is skipped in every
    /// ordinary run. A real chown to uid 0 and a real `RENAME_SWAP`, which the
    /// tests above run as this account can only stand in for.
    @Test("root leg: a bundle a user really owns comes out owned by root through a real rename swap, and the next swap is not refused",
          .enabled(if: AdminRootLeg.armed))
    func appSwapRootLegRealChownAndRenameSwap() throws {
        let scratch = realPath(try #require(AdminRootLeg.scratch))
        for forbidden in ["/Applications", "/Library", "/System"] {
            try #require(scratch != forbidden && !scratch.hasPrefix(forbidden + "/"), "the root leg never runs under \(forbidden)")
        }
        let user = try #require(AdminRootLeg.user)
        let s = AdminScratch(base: scratch)
        s.group = 0
        let decoy = s.root + "/decoy"
        defer {
            _ = chflags(decoy, 0)
            s.cleanUp()
        }
        // The floor record's parent must be root's and writable by nobody else.
        try #require(run("/usr/sbin/chown", ["0:0", s.root]) == 0 && chmod(s.root, 0o755) == 0)
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        s.makeBundle(at: s.helperCopy, tag: "v1.0.0")
        s.writeFloor("v1.0.0\n")
        try #require(run("/usr/sbin/chown", ["-R", "\(user.uid):\(user.gid)", s.target]) == 0)
        try #require(chmod(s.target, 0o750) == 0)
        let before = identity(s.target)
        let console = FixedConsole(owner: ConsoleAccount(uid: user.uid, home: s.home))

        #expect(s.engine(console: console, installedCopy: s.helperCopy).run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(identity(s.target) != before, "a chown in place would keep the identity")
        var top = stat()
        try #require(lstat(s.target, &top) == 0)
        #expect(top.st_mode & 0o7777 == 0o755)
        var entries = [s.target]
        entries += try FileManager.default.subpathsOfDirectory(atPath: s.target).map { s.target + "/" + $0 }
        for entry in entries {
            var st = stat()
            try #require(lstat(entry, &st) == 0)
            #expect(st.st_uid == 0 && st.st_gid == 0, "\(entry)")
        }
        let previous = s.previousRoot + "/k3sm-v1.0.0.previous"
        var old = stat()
        try #require(lstat(previous, &old) == 0)
        #expect(old.st_uid == user.uid, "the bundle that came out keeps its owner in root's private directory")

        // Root walks that tree next: a symlink planted in it leads nowhere.
        try Data("decoy".utf8).write(to: URL(fileURLWithPath: decoy))
        try #require(chflags(decoy, UInt32(UF_IMMUTABLE)) == 0)
        try FileManager.default.createSymbolicLink(atPath: previous + "/Contents/planted", withDestinationPath: decoy)
        try FileManager.default.removeItem(atPath: s.staged)
        s.stage(tag: "v1.2.0")
        #expect(s.engine(console: console).run() == 0)
        #expect(s.tag(at: s.target) == "v1.2.0")
        var after = stat()
        try #require(lstat(decoy, &after) == 0)
        #expect(after.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(!FileManager.default.fileExists(atPath: previous))
    }

    static func status(uid: uid_t, gid: gid_t) -> stat {
        var st = stat()
        st.st_uid = uid
        st.st_gid = gid
        return st
    }

    @Test("a user-owned bundle reinstalled from the release goes through the administrator step, comes out root's, and the next swap is not refused 115")
    func appSwapRefusalReinstallLeavesARootOwnedBundle() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        var before = stat()
        try #require(lstat(s.target, &before) == 0)
        s.group = try Self.anotherGroup(than: before.st_gid)

        // The disk image's copy, dragged to Applications: another account's
        // tree. The script's check lets it through, and the script's seed
        // leaves the verified copy's tag as root's floor for the engine.
        let dragged = getuid() + 1
        let check = "set -eu\n" + AppSwapRootScriptBuilder.targetCheck(applications: s.applications, target: s.target, floorRecord: s.floorRecord, owner: dragged)
            + "echo passed\n"
        let first = try shell(["-c", check])
        #expect(first.status == 0 && first.output == "passed\n", "\(first)")
        s.writeFloor("v1.0.0\n")
        s.makeBundle(at: s.helperCopy, tag: "v1.0.0")
        #expect(s.engine(inspector: OwnerOverride(prefix: s.target, owner: dragged), installedCopy: s.helperCopy).run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")

        // Root's copy took root's group, not the dragged bundle's.
        var after = stat()
        try #require(lstat(s.target, &after) == 0)
        #expect(after.st_uid == s.locations.owner && after.st_gid == s.locations.group)
        var inner = stat()
        try #require(lstat(s.target + "/Contents/MacOS/k3sm-app", &inner) == 0)
        #expect(inner.st_uid == s.locations.owner && inner.st_gid == s.locations.group)

        let foreign = AdminSwapEngine.copyAttributes(target: Self.status(uid: 501, gid: 20), rootsAlone: false, locations: .standard)
        #expect(foreign.owner == 0 && foreign.group == 0 && foreign.mode == 0o755)
        let roots = AdminSwapEngine.copyAttributes(target: Self.status(uid: 0, gid: 80), rootsAlone: true, locations: .standard)
        #expect(roots.owner == 0 && roots.group == 80)

        // The next swap, on the same Mac, reads a tree that is root's alone.
        let next = try shell(["-c", "set -eu\n" + AppSwapRootScriptBuilder.targetCheck(applications: s.applications, target: s.target, floorRecord: s.floorRecord, owner: getuid()) + "echo passed\n"])
        #expect(next.status == 0 && next.output == "passed\n", "\(next)")
        try FileManager.default.removeItem(atPath: s.staged)
        s.stage(tag: "v1.2.0")
        #expect(s.engine().run() == 0)
        #expect(s.tag(at: s.target) == "v1.2.0")
        #expect(s.relaunched.count == 2)
    }

    // MARK: the root script's own target and floor checks, run over scratch trees

    enum ShellTarget: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case good
        case userOwnedTop
        case userOwnedGroupWritable
        case groupWritableEntry
        case symlinkEntry
        case hardLinkEntry
        case aclEntry
        case goodRecord
        case recordNotPrivate
        case recordNoNewline
        case recordOverLongTag
        case recordTwoLines
        case recordSymlink

        var testDescription: String { rawValue }
    }

    @Test("the root script notes a target tree that is not root's alone, and refuses an unsafe one or a floor record that is not root's own, before the copy",
          arguments: ShellTarget.allCases)
    func appSwapScriptRefusesUntrustedTarget(_ c: ShellTarget) throws {
        let w = ShellScratch()
        defer { w.cleanUp() }
        var owner = getuid()
        switch c {
        case .good: break
        case .userOwnedTop: owner = getuid() + 1
        case .userOwnedGroupWritable:
            owner = getuid() + 1
            try #require(chmod(w.target + "/Contents/Resources", 0o775) == 0)
        case .groupWritableEntry: try #require(chmod(w.target + "/Contents/Resources", 0o775) == 0)
        case .symlinkEntry:
            try FileManager.default.createSymbolicLink(atPath: w.target + "/Contents/Resources/link", withDestinationPath: "/etc/passwd")
        case .hardLinkEntry: try #require(link(w.target + "/Contents/Info.plist", w.root + "/outside-link") == 0)
        case .aclEntry: try #require(run("/bin/chmod", ["+a", "everyone allow read", w.target + "/Contents/MacOS/k3sm-app"]) == 0)
        case .goodRecord: w.writeRecord("v1.0.0\n")
        case .recordNotPrivate: w.writeRecord("v1.0.0\n", mode: 0o644)
        case .recordNoNewline: w.writeRecord("v1.0.0")
        case .recordOverLongTag: w.writeRecord("v1.0.0-" + String(repeating: "a", count: 200) + "\n")
        case .recordTwoLines: w.writeRecord("v1.0.0\nv1.0.0\n")
        case .recordSymlink:
            w.writeRecord("v1.0.0\n", at: w.root + "/real-record")
            try FileManager.default.createSymbolicLink(atPath: w.record, withDestinationPath: w.root + "/real-record")
        }
        let result = try shell(["-c", "set -eu\n" + w.targetCheck(owner: owner) + "echo \"floor=$floor foreign=${foreign:+yes}\"\n"])
        switch c {
        case .good: #expect(result.status == 0 && result.output == "floor= foreign=\n", "\(result)")
        case .userOwnedTop: #expect(result.status == 0 && result.output == "floor= foreign=yes\n", "\(result)")
        case .goodRecord: #expect(result.status == 0 && result.output == "floor=v1.0.0 foreign=\n", "\(result)")
        default: #expect(result.status == AppSwapRootExit.targetUntrusted, "\(result)")
        }
    }

    struct FloorCase: CustomTestStringConvertible, Sendable {
        let record: String?
        let installed: String?
        let accept: Bool
        var testDescription: String { "record \(record ?? "none"), installed \(installed ?? "untagged")" }
    }

    @Test("the root script runs the installed helper only when the installed copy's tag is not below root's floor",
          arguments: [
              FloorCase(record: nil, installed: "v1.0.0", accept: true),
              FloorCase(record: nil, installed: nil, accept: true),
              FloorCase(record: "v1.0.0", installed: "v1.0.0", accept: true),
              FloorCase(record: "v1.0.0-rc.2", installed: "v1.0.0", accept: true),
              FloorCase(record: "v1.2.0", installed: "v1.0.0", accept: false),
              FloorCase(record: "v1.0.0", installed: "v1.0.0-rc.9", accept: false),
              FloorCase(record: "v1.0.10", installed: "v1.0.9", accept: false),
              FloorCase(record: "v1.0.0", installed: nil, accept: false),
          ])
    func appSwapScriptComparesTheInstalledTagWithTheFloor(_ c: FloorCase) throws {
        let w = ShellScratch()
        defer { w.cleanUp() }
        if let record = c.record { w.writeRecord(record + "\n") }
        let stage = w.root + "/stage"
        let info: [String: Any] = c.installed.map { ["K3smPayloadTag": $0] } ?? ["CFBundleIdentifier": "io.k3sm.app"]
        try FileManager.default.createDirectory(atPath: stage + "/k3sm.app/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: stage + "/k3sm.app/Contents/Info.plist"))
        let text = "set -eu\n" + w.targetCheck(owner: getuid()) + "stage=" + ShellQuote.quote(stage) + "\n"
            + AppSwapRootScriptBuilder.floorCompare + "echo passed\n"
        let result = try shell(["-c", text])
        if c.accept {
            #expect(result.status == 0 && result.output == "passed\n", "\(result)")
        } else {
            #expect(result.status == AppSwapRootExit.targetUntrusted, "\(result)")
        }
    }

    @Test("the script's tag rank accepts exactly the engine's release tags and orders them as the engine does")
    func appSwapScriptTagRankAgreesWithTheEngine() throws {
        let tags = ["v0.0.0", "v0.1.0", "v0.2.3", "v1.0.0-rc.0", "v1.0.0-rc.1", "v1.0.0-rc.2", "v1.0.0-rc.10", "v1.0.0-rc.9999",
                    "v1.0.0", "v1.0.1", "v1.0.9", "v1.0.10", "v1.1.0", "v1.10.0", "v2.0.0", "v999999999.999999999.999999999",
                    // Not release tags.
                    "1.0.0", "v1.0", "v1.0.0.0", "v01.0.0", "v1.0.0-rc.01", "v1.0.0-rc.10000", "v1.0.0-beta.1", "v1.0.0-rc",
                    "v1.0.0+build", "v1234567890.0.0", "v1.0.0 ", "v1.0.0\nv1.0.0", "", "v1.0.0-rc.1.2"]
        #expect(AppSwapRootScriptBuilder.floorRecordLimit == AdminSwapEngine.floorRecordLimit)
        var text = AppSwapRootScriptBuilder.tagRank
        for tag in tags {
            text += "tag=" + ShellQuote.quote(tag) + "\nif rank=$(tagrank); then echo \"$rank\"; else echo bad; fi\n"
        }
        let result = try shell(["-c", text])
        try #require(result.status == 0)
        let ranks = result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        try #require(ranks.count == tags.count, "\(result.output)")
        var valid: [(SemanticVersion, String)] = []
        for (tag, rank) in zip(tags, ranks) {
            let version = AppVersion.releaseTagVersion(tag)
            #expect((rank != "bad") == (version != nil), "\(tag): \(rank)")
            if let version, rank != "bad" { valid.append((version, rank)) }
        }
        for (a, ra) in valid {
            for (b, rb) in valid {
                #expect((ra < rb) == (a < b), "\(a) \(b)")
            }
        }
    }

    @Test("an undo whose rename fails is reported as such, with the bundle that came out kept")
    func appSwapUndoFailureIsReported() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        let moved = s.root + "/Moved"
        try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
        let decoy = s.root + "/Decoy/k3sm.app"
        s.makeBundle(at: decoy, tag: "v0.5.0")
        let decoyID = identity(decoy)
        // The first swap races a replacement of the target; the second, the
        // undo, fails.
        let renamer = ReplacingRenamer(target: s.target, movedTo: moved + "/k3sm.app", replacement: decoy, failUndo: EIO)
        #expect(s.engine(renamer: renamer).run() == AppSwapRootExit.undoFailed)
        #expect(renamer.swaps == 2)
        // Root's copy of the staged bundle is live at the target; the bundle
        // that came out is kept in root's work directory, not removed.
        #expect(s.tag(at: s.target) == "v1.1.0" && identity(s.target) != identity(s.staged))
        let work = try FileManager.default.contentsOfDirectory(atPath: s.workRoot)
        #expect(work.count == 1)
        #expect(work.map { identity(s.workRoot + "/" + $0 + "/k3sm.app") } == [decoyID])
        #expect(s.relaunched.isEmpty)
        #expect(FileManager.default.fileExists(atPath: s.floorRecord) == false, "a failed undo records no floor")
    }

    @Test("a newer staged bundle is copied, verified, given the target's owner and mode, swapped, and relaunched")
    func swapsAndRelaunches() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        chmod(s.target, 0o755)
        s.stage(tag: "v1.1.0")
        chmod(s.staged, 0o700)
        let original = identity(s.target)
        #expect(s.engine().run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        var st = stat()
        #expect(lstat(s.target, &st) == 0 && st.st_mode & 0o7777 == 0o755 && st.st_uid == getuid())
        #expect(identity(s.previousRoot + "/k3sm-v1.0.0.previous") == original)
        #expect(s.tag(at: s.staged) == "v1.1.0", "the staged bundle is left for the app to remove")
        #expect(s.relaunched == [s.account])
        // Root records the release it installed, 0600.
        #expect(FileManager.default.contents(atPath: s.floorRecord) == Data("v1.1.0\n".utf8))
        #expect(lstat(s.floorRecord, &st) == 0 && st.st_mode & 0o7777 == 0o600 && st.st_uid == getuid())
        s.expectNothingLeft()
    }

    @Test("EXDEV makes one fresh copy, verifies it and retries once; a second EXDEV refuses with the old bundle in place")
    func crossDevice() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        #expect(s.engine(renamer: FailingRenamer(errnos: [EXDEV])).run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        s.expectNothingLeft()

        let t = AdminScratch()
        defer { t.cleanUp() }
        t.install(tag: "v1.0.0")
        t.stage(tag: "v1.1.0")
        let original = identity(t.target)
        #expect(t.engine(renamer: FailingRenamer(errnos: [EXDEV, EXDEV])).run() == AppSwapRootExit.volumeRefused)
        #expect(identity(t.target) == original)
        t.expectNothingLeft()

        let u = AdminScratch()
        defer { u.cleanUp() }
        u.install(tag: "v1.0.0")
        u.stage(tag: "v1.1.0")
        #expect(u.engine(renamer: FailingRenamer(errnos: [ENOTSUP])).run() == AppSwapRootExit.volumeRefused)
        #expect(u.engine(renamer: FailingRenamer(errnos: [EPERM])).run() == AppSwapRootExit.swapFailed)
        #expect(u.tag(at: u.target) == "v1.0.0" && u.relaunched.isEmpty)
    }

    @Test("no console user, a symlinked staged bundle, an unsafe staged tree and an unsigned copy are refused")
    func otherRefusals() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        #expect(s.engine(console: FixedConsole(owner: nil)).run() == AppSwapRootExit.noConsoleUser)
        #expect(s.engine().run() == AppSwapRootExit.stagedRefused, "nothing staged")
        // A symlink at the staged location, to a valid newer bundle.
        let real = s.root + "/Real/k3sm.app"
        s.makeBundle(at: real, tag: "v1.1.0")
        try FileManager.default.createDirectory(atPath: (s.staged as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.staged, withDestinationPath: real)
        #expect(s.engine().run() == AppSwapRootExit.stagedRefused)
        try FileManager.default.removeItem(atPath: s.staged)
        // A symlink inside the staged tree.
        s.stage(tag: "v1.1.0")
        try FileManager.default.createSymbolicLink(atPath: s.staged + "/Contents/Resources/link", withDestinationPath: "/etc/passwd")
        #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        try FileManager.default.removeItem(atPath: s.staged)
        // Another team's stamp.
        s.makeBundle(at: s.staged, tag: "v1.1.0", executable: AdminFixtures.otherTeam)
        #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        #expect(s.tag(at: s.target) == "v1.0.0" && s.relaunched.isEmpty)
        s.expectNothingLeft()
    }

    @Test("a staged file flagged uchg is refused before the chown, and root's copy of it is removed")
    func immutableStagedFile() throws {
        let s = AdminScratch()
        defer {
            run("/usr/bin/chflags", ["-R", "nouchg", s.root])
            s.cleanUp()
        }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        // A file the signature seals, so the flag is the only fault.
        let locked = s.staged + "/Contents/Info.plist"
        try #require(run("/usr/bin/chflags", ["uchg", locked]) == 0)
        #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        #expect(s.tag(at: s.target) == "v1.0.0" && s.relaunched.isEmpty)
        s.expectNothingLeft()
        var st = stat()
        #expect(lstat(locked, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0, "the staged file is left as it was")
    }
}

// MARK: fixtures

/// The requirement the ad-hoc signed fixtures satisfy.
private let fixtureRequirement = "identifier \"io.k3sm.test.fixture\""

private func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func identity(_ path: String) -> FileIdentity? { FileIdentity.of(path: path) }

/// AdminFixtures compiles the swap engine's fixture app once, for the
/// fixtures' team and another team.
private enum AdminFixtures {
    static let directory: String = {
        // One directory per test process; those of processes that are gone
        // are swept first.
        let tmp = realPath(NSTemporaryDirectory())
        let prefix = "k3sm-adminswap-fixtures-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix(prefix) {
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: tmp + "/" + name)
            }
        }
        let dir = tmp + "/" + prefix + String(getpid())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "K3smSwapTests/Fixtures/fixture-app.c").path
        for (name, team) in [("fixture-app", "ABCDE12345"), ("fixture-app-other-team", "ZZZZZ99999")] {
            precondition(run("/usr/bin/cc", ["-O0", "-DFIXTURE_TEAM=\"\(team)\"", "-o", dir + "/" + name, source]) == 0,
                         "cc could not compile the fixture app")
        }
        return dir
    }()

    static var app: String { directory + "/fixture-app" }
    static var otherTeam: String { directory + "/fixture-app-other-team" }
}

/// AdminRootLeg is what `hack/root-swap-leg.sh` arms: root, the scratch path
/// it works under, and the account that ran sudo.
private enum AdminRootLeg {
    static var scratch: String? { ProcessInfo.processInfo.environment["K3SM_ROOT_SWAP_LEG_SCRATCH"] }
    static var user: (uid: uid_t, gid: gid_t)? {
        let environment = ProcessInfo.processInfo.environment
        guard let uid = environment["SUDO_UID"].flatMap({ uid_t($0) }), uid != 0,
              let gid = environment["SUDO_GID"].flatMap({ gid_t($0) }) else { return nil }
        return (uid, gid)
    }
    static var armed: Bool { getuid() == 0 && scratch != nil && user != nil }
}

/// FixedConsole is a console owned by a given account, or by nobody.
private struct FixedConsole: ConsoleSession {
    let owner: ConsoleAccount?
    func account() -> ConsoleAccount? { owner }
}

/// RecordingRelauncher records every relaunch.
private final class RecordingRelauncher: SessionRelauncher, @unchecked Sendable {
    let calls = Mutex<[ConsoleAccount]>([])
    func relaunch(_ account: ConsoleAccount) { calls.withLock { $0.append(account) } }
}

/// ReplacingRenamer, on its first swap, moves the target away and puts
/// `replacement` in its place, then swaps: the race between the engine's last
/// check and its rename.
private final class ReplacingRenamer: Renamer, @unchecked Sendable {
    let target: String
    let movedTo: String
    let replacement: String
    /// The errno the second swap, the engine's undo, fails with; nil to run it.
    let failUndo: Int32?
    private let count = Mutex<Int>(0)

    init(target: String, movedTo: String, replacement: String, failUndo: Int32? = nil) {
        self.target = target
        self.movedTo = movedTo
        self.replacement = replacement
        self.failUndo = failUndo
    }

    var swaps: Int { count.withLock { $0 } }

    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        let n = count.withLock { n -> Int in n += 1; return n }
        if n == 1 {
            precondition(rename(target, movedTo) == 0 && rename(replacement, target) == 0)
        }
        if n == 2, let failUndo { return failUndo }
        return SystemRenamer().swap(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }

    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        SystemRenamer().move(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }
}

/// FailingRenamer fails its first swaps with the given errnos, then swaps.
private final class FailingRenamer: Renamer, @unchecked Sendable {
    private let errnos: Mutex<[Int32]>

    init(errnos: [Int32]) {
        self.errnos = Mutex(errnos)
    }

    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        if let e = errnos.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return e }
        return SystemRenamer().swap(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }

    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        SystemRenamer().move(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }
}

/// OwnerOverride reports `owner` for every entry at or under `prefix`: a
/// tree another account owns, which a test cannot make by chown.
private struct OwnerOverride: TreeInspector {
    let prefix: String
    let owner: uid_t

    func status(at dirFD: Int32, _ name: String) -> stat? {
        guard var st = SystemTreeInspector().status(at: dirFD, name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let got = buffer.withUnsafeMutableBufferPointer { fcntl(dirFD, F_GETPATH, $0.baseAddress!) }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "/" + name
        if got == 0, path == prefix || path.hasPrefix(prefix + "/") { st.st_uid = owner }
        return st
    }

    func hasExtendedACL(at dirFD: Int32, _ name: String) -> Bool? { SystemTreeInspector().hasExtendedACL(at: dirFD, name) }
}

/// ShellScratch is a scratch Applications folder holding an unsigned bundle
/// tree and a floor record path, for running the root script's checks as
/// this account, which stands in for root.
private final class ShellScratch: @unchecked Sendable {
    let root: String
    var applications: String { root + "/Applications" }
    var target: String { applications + "/k3sm.app" }
    var record: String { root + "/app-floor" }

    init() {
        root = realPath(NSTemporaryDirectory()) + "/k3sm-adminswap-sh-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: target + "/Contents/MacOS", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: target + "/Contents/Resources", withIntermediateDirectories: true)
        fm.createFile(atPath: target + "/Contents/Info.plist", contents: Data("plist".utf8))
        fm.createFile(atPath: target + "/Contents/MacOS/k3sm-app", contents: Data("app".utf8))
    }

    func cleanUp() {
        run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    func targetCheck(owner: uid_t) -> String {
        AppSwapRootScriptBuilder.targetCheck(applications: applications, target: target, floorRecord: record, owner: owner)
    }

    func writeRecord(_ text: String, mode: mode_t = 0o600, at path: String? = nil) {
        let path = path ?? record
        precondition(FileManager.default.createFile(atPath: path, contents: Data(text.utf8)))
        precondition(chmod(path, mode) == 0)
    }
}

/// MountedVolume is a scratch APFS disk image, attached without browsing.
private struct MountedVolume {
    let image: String
    let mount: String

    init(name: String) throws {
        let dir = realPath(NSTemporaryDirectory()) + "/k3sm-adminswap-vol-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir + "/mnt", withIntermediateDirectories: true)
        image = dir + "/volume.dmg"
        mount = dir + "/mnt"
        try #require(run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", name, image]) == 0)
        try #require(run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount, image]) == 0)
    }

    func detach() {
        run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount])
        try? FileManager.default.removeItem(atPath: (image as NSString).deletingLastPathComponent)
    }
}

/// AdminScratch is one test's world: an Applications folder holding the
/// target, a home folder holding the compiled staging location, and root's
/// work and previous directories, owned by this account in place of root.
private final class AdminScratch: @unchecked Sendable {
    let root: String
    let home: String
    let workRoot: String
    let previousRoot: String
    var floorRecord: String { root + "/app-floor" }
    let relauncher = RecordingRelauncher()
    var applications: String { root + "/Applications" }
    var target: String { applications + "/k3sm.app" }
    var account: ConsoleAccount { ConsoleAccount(uid: getuid(), home: home) }
    var staged: String { account.stagedBundle }
    var relaunched: [ConsoleAccount] { relauncher.calls.withLock { $0 } }

    init(home: String? = nil, workRoot: String? = nil, base: String? = nil) {
        root = (base ?? realPath(NSTemporaryDirectory())) + "/k3sm-adminswap-" + UUID().uuidString.prefix(8)
        self.home = home ?? root + "/home"
        self.workRoot = workRoot ?? root + "/work"
        previousRoot = root + "/previous"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: self.home + "/Library/Application Support/io.k3sm.app", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/Applications", withIntermediateDirectories: true)
    }

    func cleanUp() {
        run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    /// The group standing in for root's.
    var group = getgid()

    var locations: AdminSwapLocations {
        AdminSwapLocations(target: target, workRoot: workRoot, previousRoot: previousRoot, floorRecord: floorRecord,
                           owner: getuid(), group: group)
    }

    /// The helper's own root-owned copy of the installed bundle.
    var helperCopy: String { root + "/stage/k3sm.app" }

    func engine(renamer: any Renamer = SystemRenamer(), console: (any ConsoleSession)? = nil,
                inspector: any TreeInspector = SystemTreeInspector(), installedCopy: String? = nil) -> AdminSwapEngine {
        AdminSwapEngine(verifier: StaticCodeVerifier(requirement: fixtureRequirement, runningTeam: AppSwapRootTests.team),
                        renamer: renamer, console: console ?? FixedConsole(owner: account), relauncher: relauncher,
                        locations: locations, inspector: inspector, installedCopy: installedCopy)
    }

    /// Writes root's floor record as this account, which stands in for root.
    func writeFloor(_ text: String, mode: mode_t = 0o600) {
        precondition(FileManager.default.createFile(atPath: floorRecord, contents: Data(text.utf8)))
        precondition(chmod(floorRecord, mode) == 0)
    }

    func makeBundle(at path: String, tag: String, executable: String = AdminFixtures.app) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: executable, toPath: path + "/Contents/MacOS/k3sm-app")
        let info: [String: Any] = [
            "CFBundleExecutable": "k3sm-app", "CFBundleIdentifier": "io.k3sm.app", "CFBundlePackageType": "APPL",
            "K3smPayloadTag": tag, "CFBundleShortVersionString": String(tag.dropFirst().prefix { $0 != "-" }),
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try! data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"), options: [])
        precondition(run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path]) == 0,
                     "codesign could not sign the fixture bundle")
    }

    func install(tag: String) { makeBundle(at: target, tag: tag) }

    func stage(tag: String) { makeBundle(at: staged, tag: tag) }

    func tag(at path: String) -> String? { InstalledRelease.read(bundleAt: path)?.tag }

    /// Root's work directory holds nothing after a run, and the target
    /// directory holds only the target.
    func expectNothingLeft(sourceLocation: SourceLocation = #_sourceLocation) {
        let work = (try? FileManager.default.contentsOfDirectory(atPath: workRoot)) ?? []
        #expect(work.isEmpty, "work directory: \(work)", sourceLocation: sourceLocation)
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []
        #expect(apps == ["k3sm.app"], "Applications: \(apps)", sourceLocation: sourceLocation)
    }
}
