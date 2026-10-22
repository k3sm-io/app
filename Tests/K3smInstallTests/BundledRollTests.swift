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
import Synchronization
import Testing

import K3smStatus
@testable import K3smInstall

/// The version set's root step (`BundledRollScriptBuilder`) and its driver
/// (`BundledRollDriver`): the script byte for byte, its argv, the record and
/// tag checks run for real on fixtures, every refusal's sentence, and the
/// driver's double read and its cancel of a roll the controller did not bind.
@Suite("the bundled version-set roll")
struct BundledRollTests {
    static let team = TeamID("ABCDE12345")!
    static let tarball = String(repeating: "a1", count: 32)
    static let manifest = String(repeating: "b2", count: 32)

    static func plan(tag: String = "v0.1.9", path: String = "/Applications/k3sm.app") throws -> BundledRollPlan {
        try BundledRollPlan(bundlePath: path, release: ReleaseTag(tag)!, teamID: team)
    }

    /// The script for `/Applications/k3sm.app` and `v0.1.9`, byte for byte.
    static let golden = #"""
        exec 4>&2
        set -eu
        umask 077
        cd /
        logdir='/Library/Logs/k3sm'
        log='/Library/Logs/k3sm/copy-out.log'
        if [ -L "$logdir" ] || [ -L "$log" ]; then
        	echo 'copy-out: refused: the log path is a symlink' >&2
        	exit 64
        fi
        /bin/mkdir -p "$logdir"
        /usr/sbin/chown root:admin "$logdir"
        /bin/chmod 0750 "$logdir"
        /bin/rm -f "$log"
        : > "$log"
        /usr/sbin/chown root:admin "$log"
        /bin/chmod 0640 "$log"
        exec >> "$log" 2>&1
        stage=
        finish() {
        	status=$?
        	if [ -n "$stage" ]; then /bin/rm -rf "$stage"; fi
        	echo "copy-out: exit $status"
        }
        trap finish EXIT
        trap 'exit 130' HUP INT TERM
        root='/Library/k3sm.staging'
        if [ -L "$root" ]; then
        	echo 'copy-out: refused: the staging root is a symlink'
        	exit 64
        fi
        /bin/mkdir -p "$root"
        /usr/sbin/chown root:wheel "$root"
        /bin/chmod 0700 "$root"
        echo 'copy-out: sweeping stale staging entries'
        /usr/bin/find "$root" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
        stage=$(/usr/bin/mktemp -d '/Library/k3sm.staging/bundled-roll.XXXXXXXX')
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 0700 "$stage"
        echo 'copy-out: copying the app bundle'
        /usr/bin/ditto --norsrc --noextattr --noqtn --noacl '/Applications/k3sm.app' "$stage"/'k3sm.app'
        bad=$(/usr/bin/find "$stage"/'k3sm.app' \( ! \( -type f -o -type d \) -o -perm +6022 \) -print | /usr/bin/head -n 1)
        if [ -n "$bad" ]; then
        	echo "copy-out: refused: $bad is a symlink, a special file, setuid or setgid, or writable by group or others"
        	exit 65
        fi
        /usr/sbin/chown -R root:wheel "$stage"/'k3sm.app'
        echo 'copy-out: verifying the signature'
        if ! /usr/bin/codesign --verify --strict --deep '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app"' "$stage"/'k3sm.app'; then
        	echo 'copy-out: refused: the app is not signed by the k3sm Developer ID'
        	exit 77
        fi
        bundle="$stage"/'k3sm.app'
        tag='v0.1.9'
        echo 'bundled-roll: reading the payload record'
        record="$bundle"/'Contents/Resources/payload.release'
        nl='
        '
        cr=$(printf '\r')
        record_refused() {
        	echo "bundled-roll: refused: $1"
        	exit 102
        }
        tag_refused() {
        	echo "bundled-roll: refused: $1"
        	exit 103
        }
        check_failed() {
        	echo "bundled-roll: refused: $1"
        	exit 105
        }
        if [ -L "$record" ] || [ ! -f "$record" ]; then record_refused 'the payload record is missing, a symlink or not a regular file'; fi
        size=$(/usr/bin/stat -f %z "$record") || check_failed 'the payload record could not be measured'
        case "$size" in ''|*[!0-9]*) check_failed 'the payload record could not be measured' ;; esac
        if [ "$size" -gt 1024 ]; then record_refused 'the payload record is larger than 1024 bytes'; fi
        if /usr/bin/grep -q "$cr" "$record"; then
        	record_refused 'the payload record holds a carriage return'
        else
        	st=$?
        	if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi
        fi
        for key in 'tag' 'tarball_sha256' 'payload_manifest_sha256'; do
        	n=$(/usr/bin/grep -c "^$key=" "$record") || { st=$?; if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi; }
        	if [ "$n" != 1 ]; then record_refused "the payload record holds $n $key lines, not exactly one"; fi
        done
        record_tag=$(/usr/bin/sed -n 's/^tag=//p' "$record") || check_failed 'the payload record could not be read'
        digest=$(/usr/bin/sed -n 's/^tarball_sha256=//p' "$record") || check_failed 'the payload record could not be read'
        plist_tag=$(/usr/libexec/PlistBuddy -c 'Print :K3smPayloadTag' "$bundle"/'Contents/Info.plist') || plist_tag=
        case "$tag" in *"$nl"*|*"$cr"*) tag_refused 'the release tag holds a line break' ;; esac
        if ! printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?$'; then tag_refused 'the release tag is not a release tag'; fi
        if [ "$record_tag" != "$tag" ]; then tag_refused 'the payload record names another release'; fi
        if [ "$plist_tag" != "$tag" ]; then tag_refused 'the bundle names another release in K3smPayloadTag'; fi
        case "$digest" in *"$nl"*|*"$cr"*) digest_ok=no ;; *) digest_ok=yes ;; esac
        if [ "$digest_ok" != yes ] || ! printf '%s\n' "$digest" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
        	echo 'bundled-roll: refused: the payload record tarball_sha256 is not 64 lowercase hex digits'
        	exit 104
        fi
        echo 'bundled-roll: the payload record matches the release'
        set -eu
        umask 077
        cd /
        k3sm='/Library/k3sm/k3sm'
        refuse() {
        	echo "k3sm app: refused: $1" >&2
        	exit 100
        }
        nl='
        '
        acl_check() {
        	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
        	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
        	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
        }
        for p in '/' '/Library' '/Library/k3sm' '/Library/k3sm/k3sm'; do
        	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
        	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
        	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$p could not be checked"
        	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
        	acl_check "$p"
        done
        if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
        if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$k3sm"; then
        	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
        	exit 101
        fi
        echo 'bundled-roll: running k3sm update apply'
        "$k3sm" 'update' 'apply' '--yes' '--version' 'v0.1.9' '--pin-sha256' "$digest" 2>&4

        """#

    @Test("the script, byte for byte, and how it runs")
    func goldenScript() throws {
        let script = BundledRollScriptBuilder.render(plan: try Self.plan())
        #expect(script.text == Self.golden)
        #expect(script.prompt == "k3sm wants to update every node of this cluster to the k3sm release this app carries.")
        #expect(!script.readsInput && script.usesStagingLock && script.result == .discarded)
        let line = script.command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/lockf -k -t 0 '/Library/k3sm.staging.lock' /bin/sh -c "))
        #expect(try shell(["-n", "-c", script.text]).status == 0)
    }

    @Test("the copy comes first, the record and tag second, the installed CLI third, the apply last")
    func order() throws {
        let plan = try Self.plan()
        let text = BundledRollScriptBuilder.render(plan: plan).text
        func at(_ s: String) throws -> String.Index { try #require(text.range(of: s), "missing \(s)").lowerBound }
        let staged = RootScriptBuilder.stagedCopy(bundlePath: plan.bundlePath, stagingTemplate: BundledRollPlan.stagingTemplate,
                                                  designatedRequirement: plan.designatedRequirement)
        #expect(text.hasPrefix("exec 4>&2\n" + staged))
        #expect(text.contains(InstalledCLIPreamble.render(teamID: Self.team, cliPath: K3smCLI.path)))
        #expect(try at("/usr/bin/ditto") < at("codesign --verify --strict --deep"))
        #expect(try at("codesign --verify --strict --deep") < at("payload.release"))
        #expect(try at("payload.release") < at("PlistBuddy"))
        #expect(try at("PlistBuddy") < at("k3sm='/Library/k3sm/k3sm'"))
        #expect(try at("k3sm='/Library/k3sm/k3sm'") < at("\"$k3sm\" 'update'"))
        // The bundle in /Applications is named once, as the copy's source;
        // everything after reads the verified root-owned copy.
        let named = text.split(separator: "\n").filter { $0.contains("/Applications/k3sm.app") }
        #expect(named.count == 1 && named.first?.hasPrefix("/usr/bin/ditto ") == true, "\(named)")
        #expect(text.contains("bundle=\"$stage\"/'k3sm.app'\n"))
        // The staged copy must carry the app's identifier too.
        #expect(plan.designatedRequirement == DesignatedRequirement.developerID(teamID: Self.team) + " and identifier \"io.k3sm.app\"")
    }

    @Test("the argv is fixed, carries the tag, and passes the digest only as a quoted variable")
    func argv() throws {
        let words = BundledRollScriptBuilder.arguments(tag: ReleaseTag("v0.1.9-rc.2")!, digestVariable: "digest")
        #expect(words == [.literal("update"), .literal("apply"), .literal("--yes"), .literal("--version"), .literal("v0.1.9-rc.2"),
                          .literal("--pin-sha256"), .variable("digest")])
        #expect(words.map(\.rendered) == ["'update'", "'apply'", "'--yes'", "'--version'", "'v0.1.9-rc.2'", "'--pin-sha256'", "\"$digest\""])
        // As the shell splits the line, with the digest the script read.
        let line = (["printf '%s\\n'"] + words.map(\.rendered)).joined(separator: " ")
        let out = try shell(["-c", "digest=" + Self.tarball + "\n" + line])
        #expect(out.output == ["update", "apply", "--yes", "--version", "v0.1.9-rc.2", "--pin-sha256", Self.tarball].joined(separator: "\n") + "\n")
    }

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
    }

    @Test("BundledRollScriptBuilder.arguments is the only place in Sources that writes --pin-sha256")
    func pinFlagHasOneHome() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("\"--pin-sha256\"") {
                hits.append(url.lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(hits == ["BundledRoll.swift: .literal(\"--pin-sha256\"), .variable(digestVariable)]"], "\(hits)")
        // No option set the update menu passes produces it either.
        for drain in [false, true] {
            for downgrade in [false, true] {
                for signature in UpdateSignaturePolicy.allCases {
                    let argv = LifecycleScriptBuilder.updateApplyArguments(
                        options: UpdateOptions(drain: drain, allowDowngrade: downgrade, signature: signature), release: ReleaseTag("v0.1.9")!)
                    #expect(!argv.contains("--pin-sha256"))
                }
            }
        }
    }

    @Test("a plan refuses a path the copy-out refuses and a tag outside the strict grammar")
    func planRefusals() throws {
        #expect(throws: BundledRollPlan.PlanError.bundlePath(.bundlePathNotAbsolute)) { try Self.plan(path: "Applications/k3sm.app") }
        #expect(throws: BundledRollPlan.PlanError.bundlePath(.bundlePathNotCanonical)) { try Self.plan(path: "/Applications/../k3sm.app") }
        #expect(throws: BundledRollPlan.PlanError.bundlePath(.bundlePathNotAnApp)) { try Self.plan(path: "/Applications/k3sm") }
        #expect(throws: BundledRollPlan.PlanError.tagNotARelease) { try Self.plan(tag: "v0.1.9+meta") }
        #expect(throws: BundledRollPlan.PlanError.tagNotARelease) { try Self.plan(tag: "0.1.9") }
        let hostile = try Self.plan(path: "/Applications/it's $(id).app")
        let text = BundledRollScriptBuilder.render(plan: hostile).text
        #expect(text.contains("/usr/bin/ditto --norsrc --noextattr --noqtn --noacl '/Applications/it'\\''s $(id).app' "))
        let named = text.split(separator: "\n").filter { $0.contains("$(id).app") }
        #expect(named.count == 1 && named.first?.hasPrefix("/usr/bin/ditto ") == true)
    }

    // MARK: the record and tag checks, run for real

    /// A bundle fixture: Info.plist with `plistTag` (none when nil) and
    /// `payload.release` as `record` (none when nil).
    static func fixture(record: String?, plistTag: String? = "v0.1.9") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm-bundled-\(UUID().uuidString)/k3sm.app")
        let resources = base.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "io.k3sm.app", "CFBundleShortVersionString": "0.1.9"]
        if let plistTag { info[AppVersion.payloadTagKey] = plistTag }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: base.appending(path: BundledRollPlan.infoPlistPath))
        if let record { try Data(record.utf8).write(to: base.appending(path: BundledRollPlan.recordPath)) }
        return base
    }

    static func record(tag: String = "v0.1.9", tarball: String = BundledRollTests.tarball, manifest: String = BundledRollTests.manifest) -> String {
        "# k3sm payload release v1: the payload this bundle carries, from the k3sm publish seal\n"
            + "tag=\(tag)\ntarball_sha256=\(tarball)\npayload_manifest_sha256=\(manifest)\n"
    }

    /// Runs the record check on `bundle` against the app's `tag`, then
    /// prints the digest it read.
    static func check(_ bundle: URL, tag: String = "v0.1.9") throws -> (status: Int32, output: String) {
        let q = ShellQuote.quote
        let script = "set -eu\nbundle=\(q(bundle.path))\ntag=\(q(tag))\n" + BundledRollScriptBuilder.recordCheck
            + "printf 'digest=%s\\n' \"$digest\"\n"
        return try shell(["-c", script])
    }

    struct Refusal: CustomTestStringConvertible, Sendable {
        let name: String
        let record: String?
        let plistTag: String?
        let tag: String
        let status: Int32
        let message: String
        var testDescription: String { name }
    }

    static let refusals: [Refusal] = [
        Refusal(name: "no record", record: nil, plistTag: "v0.1.9", tag: "v0.1.9", status: 102, message: "missing"),
        Refusal(name: "a duplicate key", record: record() + "tag=v0.1.9\n", plistTag: "v0.1.9", tag: "v0.1.9", status: 102,
                message: "holds 2 tag lines"),
        Refusal(name: "a missing key", record: "tag=v0.1.9\ntarball_sha256=\(tarball)\n", plistTag: "v0.1.9", tag: "v0.1.9", status: 102,
                message: "holds 0 payload_manifest_sha256 lines"),
        Refusal(name: "a carriage return", record: record().replacingOccurrences(of: "\n", with: "\r\n"), plistTag: "v0.1.9", tag: "v0.1.9",
                status: 102, message: "carriage return"),
        Refusal(name: "a record over 1 KiB", record: record() + "#" + String(repeating: "x", count: 1024) + "\n", plistTag: "v0.1.9",
                tag: "v0.1.9", status: 102, message: "larger than 1024 bytes"),
        Refusal(name: "the record names another release", record: record(tag: "v0.1.8"), plistTag: "v0.1.9", tag: "v0.1.9", status: 103,
                message: "the payload record names another release"),
        Refusal(name: "K3smPayloadTag names another release", record: record(), plistTag: "v0.1.9-rc.1", tag: "v0.1.9", status: 103,
                message: "K3smPayloadTag"),
        Refusal(name: "no K3smPayloadTag", record: record(), plistTag: nil, tag: "v0.1.9", status: 103, message: "K3smPayloadTag"),
        Refusal(name: "the app passed another release", record: record(), plistTag: "v0.1.9", tag: "v0.1.8", status: 103,
                message: "the payload record names another release"),
        Refusal(name: "the same tag everywhere, outside the strict grammar", record: record(tag: "v0.1.9+x"), plistTag: "v0.1.9+x",
                tag: "v0.1.9+x", status: 103, message: "not a release tag"),
        Refusal(name: "an uppercase digest", record: record(tarball: tarball.uppercased()), plistTag: "v0.1.9", tag: "v0.1.9",
                status: 104, message: "not 64 lowercase hex digits"),
        Refusal(name: "a short digest", record: record(tarball: String(tarball.dropLast())), plistTag: "v0.1.9", tag: "v0.1.9",
                status: 104, message: "not 64 lowercase hex digits"),
        Refusal(name: "a digest with a trailing word", record: record(tarball: tarball + " x"), plistTag: "v0.1.9", tag: "v0.1.9",
                status: 104, message: "not 64 lowercase hex digits"),
    ]

    @Test("each record or tag refusal stops before the CLI with its own status", arguments: refusals)
    func recordRefusal(_ r: Refusal) throws {
        let bundle = try Self.fixture(record: r.record, plistTag: r.plistTag)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let result = try Self.check(bundle, tag: r.tag)
        #expect(result.status == r.status, "\(result.output)")
        #expect(result.output.contains(r.message), "\(result.output)")
        #expect(!result.output.contains("digest="))
    }

    @Test("a record the check cannot read exits 105, never the CLI's 1 or 2")
    func unreadableRecord() throws {
        let bundle = try Self.fixture(record: Self.record())
        let record = bundle.appending(path: BundledRollPlan.recordPath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: record.path)
            try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: record.path)
        let result = try Self.check(bundle)
        #expect(result.status == BundledRollExit.recordUnreadable, "\(result.output)")
        #expect(result.output.contains("could not be read"))
    }

    @Test("a symlinked record is refused, even one pointing at a valid record")
    func symlinkedRecord() throws {
        let bundle = try Self.fixture(record: nil)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let elsewhere = bundle.deletingLastPathComponent().appending(path: "elsewhere.release")
        try Data(Self.record().utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle.appending(path: BundledRollPlan.recordPath), withDestinationURL: elsewhere)
        let result = try Self.check(bundle)
        #expect(result.status == BundledRollExit.recordRefused)
        #expect(result.output.contains("a symlink"))
    }

    @Test("a matching record yields the tarball digest, never the manifest digest, for a final and an rc")
    func matchingRecord() throws {
        for tag in ["v0.1.9", "v0.2.0-rc.1"] {
            let bundle = try Self.fixture(record: Self.record(tag: tag), plistTag: tag)
            defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
            let result = try Self.check(bundle, tag: tag)
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.hasSuffix("digest=\(Self.tarball)\n"))
            #expect(!result.output.contains(Self.manifest))
        }
        // The manifest digest written where the tarball digest belongs is
        // what the CLI is handed, and the controller then refuses the
        // release (ReleasePinMismatch): the script reads only tarball_sha256.
        let swapped = try Self.fixture(record: Self.record(tarball: Self.manifest, manifest: Self.tarball))
        defer { try? FileManager.default.removeItem(at: swapped.deletingLastPathComponent()) }
        #expect(try Self.check(swapped).output.hasSuffix("digest=\(Self.manifest)\n"))
    }

    // MARK: outcomes

    @Test("every refusal of the root step has a sentence and starts nothing", arguments: [
        (Int32(64), "symlink"), (65, "unsafe file"), (75, "Another install or update"), (77, "not signed by the k3sm Developer ID"),
        (100, "is not owned by root"), (101, "installed k3sm is not signed"), (102, "missing or malformed"),
        (103, "does not name the release offered"), (104, "no valid digest"), (105, "could not read this app's record"),
    ])
    func refusalSentences(_ status: Int32, _ words: String) {
        let result = BundledRollDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: status)))
        guard case .ran(.notStarted, .failed(status), let text) = result else {
            Issue.record("exit \(status) read as \(result)")
            return
        }
        #expect(text.contains(words), "\(text)")
    }

    @Test("the CLI's own refusals start nothing, and its error text is shown cleaned")
    func cliRefusals() {
        let usage = BundledRollDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 2),
                                                             errorOutput: "k3sm update apply: --pin-sha256: the pinned sha256 is not 64 lowercase hex digits\n"))
        #expect(usage == .ran(.notStarted, .failed(exitStatus: 2),
                              "The installed k3sm did not accept an update bound to this app's release, so nothing was started. "
                                + "k3sm update apply: --pin-sha256: the pinned sha256 is not 64 lowercase hex digits"))
        let root = BundledRollDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 1),
                                                            errorOutput: "k3sm update apply: --pin-sha256 writes the server's release pin and must run as root"))
        guard case .ran(.notStarted, _, let text) = root else { Issue.record("\(root)"); return }
        #expect(text.hasPrefix("k3sm update apply --yes failed: "))
        let rolling = BundledRollDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 1),
                                                               errorOutput: "follow it with `k3sm update status --watch`"))
        guard case .ran(.alreadyRolling, _, _) = rolling else { Issue.record("\(rolling)"); return }
        #expect(BundledRollDriver.classify(PrivilegedRun(outcome: .cancelled)) == .ran(.notStarted, .cancelled, "Cancelled. Nothing was changed."))
        guard case .ran(.started, .succeeded, _) = BundledRollDriver.classify(PrivilegedRun(outcome: .succeeded)) else {
            Issue.record("a success did not start the roll")
            return
        }
    }

    // MARK: the driver

    static func report(release: String = "v0.1.8", kubelet: String = "v1.36.2+k3sm.0.1.8",
                       workers: [StatusWorker] = [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.8")]) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s",
                     rows: [StatusRow(name: "server", state: "running", detail: "d"),
                            StatusRow(name: "node", state: "ready", detail: "d", wide: ["node": "my-mac", "kubelet": kubelet])],
                     workers: workers, release: StatusRelease(text: release))
    }

    static func nodes(notReady: Set<String> = []) -> [ClusterNode] {
        ["my-mac", "node-b"].map { ClusterNode(name: $0, ready: !notReady.contains($0)) }
    }

    final class Reads: Sendable {
        let reports: StatusSequence
        private let nodeLists: Mutex<[[ClusterNode]?]>
        private let updates: Mutex<[UpdateStatus?]>
        private let cancels = Mutex(0)
        let cancelSucceeds: Bool

        init(_ reports: [StatusReport?], nodes: [[ClusterNode]?], updates: [UpdateStatus?] = [], cancelSucceeds: Bool = true) {
            self.reports = StatusSequence(reports)
            nodeLists = Mutex(nodes)
            self.updates = Mutex(updates)
            self.cancelSucceeds = cancelSucceeds
        }

        func nextNodes() -> [ClusterNode]? { nodeLists.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
        func nextUpdate() -> UpdateStatus? { updates.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
        func cancel() -> Bool {
            cancels.withLock { $0 += 1 }
            return cancelSucceeds
        }
        var cancelled: Int { cancels.withLock { $0 } }
    }

    static func driver(_ reads: Reads, runner: LANRunner, answer: Bool = true, asked: Questions? = nil,
                       bundlePath: String = "/Applications/k3sm.app") -> BundledRollDriver {
        BundledRollDriver(
            teamID: team, bundlePath: bundlePath,
            readStatus: { reads.reports.next() }, readNodes: { reads.nextNodes() },
            confirm: { c in
                asked?.append(c)
                return answer
            },
            runner: runner, readUpdate: { reads.nextUpdate() }, cancelUnprivileged: { reads.cancel() }, sleep: { _ in })
    }

    static func resolved(_ reason: String, status: String = "True", version: String = "v0.1.9") -> UpdateStatus {
        UpdateStatus(phase: .rolling, version: version, conditions: [UpdateCondition(type: "Resolved", status: status, reason: reason)])
    }

    static func cancelled(version: String = "v0.1.9") -> UpdateStatus {
        UpdateStatus(phase: .cancelled, version: version, finished: true)
    }

    static let rolling = UpdateStatus(phase: .rolling, version: "v0.1.9")

    @Test("the roll reads twice, asks once between, runs the pinned script, and confirms the pinned resolve")
    func pinnedRoll() async throws {
        // The first update read is the one taken just before the root step.
        let reads = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                          updates: [nil, nil, UpdateStatus(phase: .pending, version: "v0.1.9"), Self.resolved("ResolvedPinned")])
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, asked: asked).apply(tag: "v0.1.9")
        #expect(result == .ran(.started, .succeeded, BundledRollDriver.bound))
        #expect(reads.reports.reads == 2)
        #expect(reads.cancelled == 0)
        try #require(runner.scripts.count == 1)
        #expect(runner.scripts[0] == BundledRollScriptBuilder.render(plan: try Self.plan()))
        try #require(asked.all.count == 1)
        let q = asked.all[0]
        #expect(q.title == "Update the cluster to k3sm v0.1.9?" && !q.offersDowngrade && q.update == .defaults)
        #expect(q.message.contains("node-b first, one node at a time, then this server, my-mac, last."))
        for check in UpdatePolicy.serverChecks { #expect(q.message.contains(check)) }
    }

    @Test("a node that is not Ready refuses before the question, and on the second read after it")
    func notReady() async throws {
        let first = Reads([Self.report()], nodes: [Self.nodes(notReady: ["node-b"])])
        let runner = LANRunner()
        let asked = Questions()
        let refused = await Self.driver(first, runner: runner, asked: asked).apply(tag: "v0.1.9")
        #expect(refused == .refused(UpdateBlock.bundledNodeNotReady(["node-b"]).sentence + " Nothing was changed."))
        #expect(asked.all.isEmpty && runner.scripts.isEmpty)

        let second = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes(notReady: ["my-mac"])])
        let late = await Self.driver(second, runner: runner).apply(tag: "v0.1.9")
        #expect(late == .refused(UpdateBlock.bundledNodeNotReady(["my-mac"]).sentence + " Nothing was changed."))
        #expect(runner.scripts.isEmpty)

        let unknown = Reads([Self.report()], nodes: [nil])
        #expect(await Self.driver(unknown, runner: runner).apply(tag: "v0.1.9")
            == .refused(UpdateBlock.bundledNodesUnknownText + " Nothing was changed."))
    }

    @Test("the nodes that would move changing while the question is open refuses the run")
    func movedWhileAsking() async throws {
        let caughtUp = Self.report(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.9")])
        let reads = Reads([Self.report(), caughtUp], nodes: [Self.nodes(), Self.nodes()])
        let runner = LANRunner()
        let result = await Self.driver(reads, runner: runner).apply(tag: "v0.1.9")
        #expect(result == .refused("The nodes the update would move changed while the question was open. Nothing was changed."))
        #expect(runner.scripts.isEmpty)
    }

    @Test("an unpinned resolve is cancelled as the user, and said cancelled only once the Update reads Cancelled")
    func unpinnedCancelledUnprivileged() async throws {
        let reads = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                          updates: [nil, Self.resolved("Resolved"), Self.rolling, Self.cancelled()])
        let runner = LANRunner()
        let result = await Self.driver(reads, runner: runner).apply(tag: "v0.1.9")
        #expect(result == .ran(.started, .succeeded, BundledRollDriver.unboundCancelled))
        #expect(reads.cancelled == 1)
        #expect(runner.scripts.count == 1)
    }

    @Test("a user cancel that exits 0 while the Update still runs falls to the root cancel, and an unseen cancel is unconfirmed")
    func userCancelNotSeen() async throws {
        // The user's cancel exits 0, but the Update keeps rolling: the root
        // cancel runs, and its effect is seen.
        let stillRolling = Array(repeating: Optional(Self.rolling), count: BundledRollDriver.cancelConfirmReads)
        let seenAfterRoot = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                                  updates: [nil, Self.resolved("Resolved")] + stillRolling + [Self.cancelled()])
        let runner = LANRunner()
        #expect(await Self.driver(seenAfterRoot, runner: runner).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.unboundCancelled))
        #expect(seenAfterRoot.cancelled == 1)
        try #require(runner.scripts.count == 2)
        #expect(runner.scripts[1] == LifecycleScriptBuilder.render(.updateCancel, teamID: Self.team))

        // Neither cancel is seen to take effect: never "cancelled".
        let neverSeen = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                              updates: [nil, Self.resolved("Resolved")] + stillRolling + stillRolling)
        let result = await Self.driver(neverSeen, runner: LANRunner()).apply(tag: "v0.1.9")
        #expect(result == .ran(.started, .succeeded, BundledRollDriver.unboundCancelUnconfirmed))
        #expect(BundledRollDriver.unboundCancelUnconfirmed.contains("`sudo k3sm update status`"))

        // A Cancelled reading of another Update does not confirm this one.
        let other = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                          updates: [nil, Self.resolved("Resolved"), Self.cancelled(version: "v0.2.0")])
        #expect(await Self.driver(other, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.unboundCancelUnconfirmed))
    }

    @Test("an Update that finished Succeeded or Failed before the cancel landed is never said cancelled")
    func finishedBeforeCancel() async throws {
        for phase in [UpdatePhase.succeeded, .failed] {
            let ended = UpdateStatus(phase: phase, version: "v0.1.9", finished: true)
            let reads = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                              updates: [nil, Self.resolved("Resolved"), ended])
            let result = await Self.driver(reads, runner: LANRunner()).apply(tag: "v0.1.9")
            #expect(result == .ran(.started, .succeeded, BundledRollDriver.endedBeforeCancel(phase)))
            #expect(BundledRollDriver.endedBeforeCancel(phase) != BundledRollDriver.unboundCancelled)
            #expect(BundledRollDriver.endedBeforeCancel(phase).contains(phase == .succeeded ? "succeeded" : "failed"))
            #expect(BundledRollDriver.endedBeforeCancel(phase).contains("nodes may have been updated"))
        }
    }

    @Test("an unpinned resolve the user cannot cancel is cancelled as root")
    func unpinnedCancelledAsRoot() async throws {
        let reads = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()],
                          updates: [nil, Self.resolved("Resolved"), Self.cancelled()], cancelSucceeds: false)
        let runner = LANRunner()
        let result = await Self.driver(reads, runner: runner).apply(tag: "v0.1.9")
        #expect(result == .ran(.started, .succeeded, BundledRollDriver.unboundCancelled))
        try #require(runner.scripts.count == 2)
        #expect(runner.scripts[1] == LifecycleScriptBuilder.render(.updateCancel, teamID: Self.team))

        let refusing = Reads([], nodes: [], cancelSucceeds: false)
        let identity = BundledRollDriver.UpdateIdentity(tag: "v0.1.9")
        #expect(await Self.driver(refusing, runner: LANRunner(PrivilegedRun(outcome: .cancelled))).cancelUnbound(identity: identity, before: nil)
            == BundledRollDriver.unboundNotCancelled)
    }

    @Test("only readings of the created Update count: another name, another release, the replaced Update, or no reading")
    func watchIdentity() async throws {
        let base = [Self.report(), Self.report()]
        // Another Update's pinned resolve never says bound.
        let otherName = UpdateStatus(phase: .rolling, version: "v0.1.9",
                                     conditions: [UpdateCondition(type: "Resolved", status: "True", reason: "ResolvedPinned")], name: "other")
        let named = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [nil, otherName])
        #expect(await Self.driver(named, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.bindingUnconfirmed))
        let otherRelease = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [nil, Self.resolved("ResolvedPinned", version: "v0.2.0")])
        #expect(await Self.driver(otherRelease, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.bindingUnconfirmed))
        // ... and another Update's unpinned resolve cancels nothing.
        let unpinnedOther = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [nil, Self.resolved("Resolved", version: "v0.2.0")])
        _ = await Self.driver(unpinnedOther, runner: LANRunner()).apply(tag: "v0.1.9")
        #expect(unpinnedOther.cancelled == 0)
        // The finished Update read before the run, which the apply replaced,
        // is not the created one; the created one's reading still counts.
        var old = Self.resolved("ResolvedPinned")
        old = UpdateStatus(phase: .succeeded, version: "v0.1.9", conditions: old.conditions, finished: true)
        let replaced = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [old, old, Self.resolved("ResolvedPinned")])
        #expect(await Self.driver(replaced, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.bound))
        let onlyOld = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [old, old])
        #expect(await Self.driver(onlyOld, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.bindingUnconfirmed))
        // No reading at all: unconfirmed, never bound.
        let silent = Reads(base, nodes: [Self.nodes(), Self.nodes()])
        #expect(await Self.driver(silent, runner: LANRunner()).apply(tag: "v0.1.9")
            == .ran(.started, .succeeded, BundledRollDriver.bindingUnconfirmed))
        #expect(silent.cancelled == 0)
    }

    @Test("a pin mismatch and an end before the resolve")
    func watchOutcomes() async throws {
        let base = [Self.report(), Self.report()]
        let mismatch = Reads(base, nodes: [Self.nodes(), Self.nodes()], updates: [nil, Self.resolved("ReleasePinMismatch", status: "False")])
        #expect(await Self.driver(mismatch, runner: LANRunner()).apply(tag: "v0.1.9") == .ran(.started, .succeeded, BundledRollDriver.pinMismatch))
        #expect(mismatch.cancelled == 0)

        let ended = Reads(base, nodes: [Self.nodes(), Self.nodes()],
                          updates: [nil, UpdateStatus(phase: .failed, version: "v0.1.9", finished: true)])
        #expect(await Self.driver(ended, runner: LANRunner()).apply(tag: "v0.1.9") == .ran(.started, .succeeded, BundledRollDriver.endedUnresolved))
    }

    @Test("a refused or failed run is not watched")
    func noWatchWithoutStart() async throws {
        let reads = Reads([Self.report(), Self.report()], nodes: [Self.nodes(), Self.nodes()], updates: [nil, Self.resolved("Resolved")])
        let result = await Self.driver(reads, runner: LANRunner(PrivilegedRun(outcome: .failed(exitStatus: 103)))).apply(tag: "v0.1.9")
        #expect(result == .ran(.notStarted, .failed(exitStatus: 103), BundledRollOutcome.text(exitStatus: 103)!))
        #expect(reads.cancelled == 0)
    }

    @Test("a tag outside the strict grammar or an unusable bundle path is refused before anything is read")
    func refusedBeforeReading() async throws {
        let reads = Reads([Self.report()], nodes: [Self.nodes()])
        let asked = Questions()
        #expect(await Self.driver(reads, runner: LANRunner(), asked: asked).apply(tag: "v0.1.9+x") == .refused(UpdateDriver.invalidTagText))
        #expect(await Self.driver(reads, runner: LANRunner(), asked: asked, bundlePath: "k3sm.app").apply(tag: "v0.1.9")
            == .refused(BundledRollDriver.bundlePathText))
        #expect(reads.reports.reads == 0 && asked.all.isEmpty)
    }

    @Test("the precondition: the role, the release, the pin on both sides, the skew, a node ahead, nothing to move")
    func precondition() {
        let nodes = Self.nodes()
        #expect(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(), nodes: nodes)
            == .proceed(ReleaseTag("v0.1.9")!, nodes: ["node-b", "my-mac"], server: "my-mac"))
        #expect(UpdatePrecondition.bundled(tag: "v0.1.9-rc.1", live: Self.report(), nodes: nodes)
            == .proceed(ReleaseTag("v0.1.9-rc.1")!, nodes: ["node-b", "my-mac"], server: "my-mac"))
        func refused(_ r: UpdatePrecondition.CatchUpRelease, _ words: String) {
            guard case .refused(let why) = r else { Issue.record("\(r) proceeded"); return }
            #expect(why.contains(words), "\(why)")
        }
        refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: nil, nodes: nodes), "could not read the status")
        refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(release: "v0.1.7", kubelet: "v1.36.2+k3sm.0.1.7"), nodes: nodes),
                "cannot bind an update")
        refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(kubelet: "v1.36.2+k3sm.0.1.7"), nodes: nodes),
                "does not check a release pin")
        refused(UpdatePrecondition.bundled(tag: "v0.3.0", live: Self.report(), nodes: nodes), "more than one minor release")
        refused(UpdatePrecondition.bundled(tag: "v0.1.8", live: Self.report(), nodes: nodes), "nothing to update")
        refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(workers: [StatusWorker(name: "node-b", role: "agent",
                                                                                                 version: "v1.36.2+k3sm.0.2.0")]),
                                           nodes: nodes), "Update the server first")
        refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(release: "v0.1.8-dirty+x"), nodes: nodes), "reports no release")
        // Not an exact release tag: no pin, on either side.
        for text in ["v0.1.8-beta.1", "v0.1.8-3-gabcdef1", "dev"] {
            guard case .refused = UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(release: text), nodes: nodes) else {
                Issue.record("\(text) proceeded")
                continue
            }
        }
        for part in ["0.1.8.dirty", "0.1.8-3-gabcdef1", "garbage"] {
            refused(UpdatePrecondition.bundled(tag: "v0.1.9", live: Self.report(kubelet: "v1.36.2+k3sm.\(part)"), nodes: nodes),
                    "does not check a release pin")
        }
    }
}
