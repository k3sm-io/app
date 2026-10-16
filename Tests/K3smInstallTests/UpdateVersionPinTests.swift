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

/// The managed update applies the release the user confirmed: the apply's
/// root script carries `--version` and exactly that tag, so `k3sm update
/// apply` does not resolve the latest release again at run time.
@Suite("the managed update's pinned release")
struct UpdateVersionPinTests {
    static let team = ManagedUpdateTests.team

    /// The apply script for v0.1.8 with the default options, byte for byte.
    static let goldenApply = #"""
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
        exec "$k3sm" 'update' 'apply' '--yes' '--version' 'v0.1.8'

        """#

    /// The argv /bin/sh hands the CLI for a rendered script's exec line.
    static func shellArgv(_ script: RootScript) throws -> [String] {
        let lines = script.text.split(separator: "\n").filter { $0.hasPrefix("exec ") }
        try #require(lines.count == 1, "want exactly one exec line")
        let prefix = "exec \"$k3sm\" "
        try #require(lines[0].hasPrefix(prefix))
        let probe = "set -- " + lines[0].dropFirst(prefix.count) + "\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
        let result = try shell(["-c", probe])
        try #require(result.status == 0)
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test("the apply script for a confirmed release carries exactly that tag after --version")
    func updateApplyPinsConfirmedVersion() async throws {
        // The default options: the script, byte for byte.
        let reads = StatusSequence([ManagedUpdateTests.report(latest: "v0.1.8"), ManagedUpdateTests.report(latest: "v0.1.8")])
        let runner = LANRunner()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true).apply(tag: "v0.1.8")
        #expect(result == .ran(.started, .succeeded, "The update has started. Each node updates in turn, the server last."))
        try #require(runner.scripts.count == 1)
        #expect(runner.scripts[0].text == Self.goldenApply)
        let argv = try Self.shellArgv(runner.scripts[0])
        #expect(argv == ["update", "apply", "--yes", "--version", "v0.1.8"])

        // With every option on, the tag still follows --version, once.
        let mixed = StatusSequence([ManagedUpdateTests.mixed(latest: "v0.2.0-rc.1"), ManagedUpdateTests.mixed(latest: "v0.2.0-rc.1")])
        let optioned = LANRunner()
        _ = await ManagedUpdateTests.driver(mixed, runner: optioned, answer: true, downgrade: true)
            .apply(tag: "v0.2.0-rc.1", options: UpdateOptions(drain: true, allowDowngrade: false, signature: .required))
        try #require(optioned.scripts.count == 1)
        let full = try Self.shellArgv(optioned.scripts[0])
        #expect(full == ["update", "apply", "--yes", "--drain", "--allow-downgrade", "--signature", "required", "--version", "v0.2.0-rc.1"])
        #expect(full.filter { $0 == "--version" }.count == 1)
        #expect(full.firstIndex(of: "--version").map { full[$0 + 1] } == "v0.2.0-rc.1")
    }

    /// The shapes `version.ValidTag` accepts and refuses: its own table in
    /// pkg/version/release_test.go, and the hostile values a tag could carry.
    static let accepted = ["v0.1.7", "0.1.7", "v0.2.0-rc.1", "v1+meta_x", "V1.2.3", "a", "1",
                           String(repeating: "v", count: 128), "v0.1.7-", "v0.1.7.", "_x"]
    static let refused = ["", "-v1", "--version", "-", "v1/../x", "v1 2", " v1", "v1 ", "v1;rm", "v1$(x)", "$(id)", "`id`",
                          "v1'", "'v1'", "\"v1\"", "v1\"; rm -rf / #", "v1\n", "v1\t", "v1\r", "v1\u{0}", "v1&&x", "v1|x",
                          "v1>x", "v1*", "v1~", "v1@x", "v1:x", "v1=x", "v1,x", "v1\\x", "v1%x", "vü1", "v1\u{202E}",
                          String(repeating: "v", count: 129), String(repeating: "\u{0}", count: 129)]

    @Test("the app's tag check accepts what version.ValidTag accepts", arguments: accepted)
    func acceptedTags(_ tag: String) {
        #expect(ReleaseTag.isValid(tag))
        #expect(ReleaseTag(tag)?.value == tag)
    }

    @Test("the app's tag check refuses what version.ValidTag refuses", arguments: refused)
    func refusedTags(_ tag: String) {
        #expect(!ReleaseTag.isValid(tag))
        #expect(ReleaseTag(tag) == nil)
    }

    @Test("every printable ASCII character is accepted exactly when ValidTag's set holds it")
    func everyASCIICharacter() {
        let set = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.+_-")
        for code in 0..<128 {
            let c = Character(Unicode.Scalar(UInt8(code)))
            #expect(ReleaseTag.isValid("v" + String(c)) == set.contains(c), "byte \(code)")
        }
    }

    @Test("a tag that is not a release tag is refused before any read, question or root prompt",
          arguments: ["", "v0.1.8; id", "v0.1.8 --drain", "-v0.1.8", "v0.1.8$(id)", "v0.1.8'"])
    func invalidTagRefused(_ tag: String) async {
        let reads = StatusSequence([ManagedUpdateTests.report(latest: "v0.1.8"), ManagedUpdateTests.report(latest: "v0.1.8")])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked).apply(tag: tag)
        #expect(result == .refused(UpdateDriver.invalidTagText))
        #expect(reads.reads == 0 && asked.all.isEmpty && runner.scripts.isEmpty)
    }

    @Test("the apply's argv is its options, then --version and the release")
    func applyArguments() {
        let release = ReleaseTag("v0.1.8")!
        #expect(LifecycleScriptBuilder.updateApplyArguments(options: .defaults, release: release)
            == ["update", "apply", "--yes", "--version", "v0.1.8"])
        #expect(LifecycleScriptBuilder.updateApplyArguments(options: UpdateOptions(drain: true, allowDowngrade: false, signature: .ifSigned), release: release)
            == ["update", "apply", "--yes", "--drain", "--version", "v0.1.8"])
    }

    /// The row names v0.1.8; a tag of the same version written otherwise is
    /// not the release the row offers, so the apply asks nothing and runs
    /// nothing.
    @Test("a tag that is the row's version but not its text is refused before any question or prompt",
          arguments: ["0.1.8", "v0.1.8+x", "v0.1.8+build.5", "V0.1.8"])
    func otherSpellingRefused(_ tag: String) async {
        let reads = StatusSequence([ManagedUpdateTests.report(latest: "v0.1.8"), ManagedUpdateTests.report(latest: "v0.1.8")])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked).apply(tag: tag)
        #expect(result == .refused("k3sm no longer reports \(tag) as an update for this cluster. Nothing was changed."))
        #expect(asked.all.isEmpty && runner.scripts.isEmpty)
        #expect(UpdatePrecondition.check(tag: tag, live: ManagedUpdateTests.report(latest: "v0.1.8")) != .proceed)
    }

    @Test("a passed check pins the row's own text")
    func pinsTheRowText() async {
        let live = ManagedUpdateTests.report(latest: "v0.1.8")
        #expect(UpdatePrecondition.release(tag: "v0.1.8", live: live) == .proceed(ReleaseTag("v0.1.8")!))
        #expect(UpdatePrecondition.check(tag: "v0.1.8", live: live) == .proceed)
        // The row's text changing while the question is open, even to an equal version, runs nothing.
        let reads = StatusSequence([live, ManagedUpdateTests.report(latest: "0.1.8")])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked).apply(tag: "v0.1.8")
        #expect(result == .refused("k3sm no longer reports v0.1.8 as an update for this cluster. Nothing was changed."))
        #expect(asked.all.count == 1 && runner.scripts.isEmpty)
    }

    // MARK: the k3sm CLI contract

    static var releaseSource: String? {
        LifecycleScriptTests.cliDirectory.flatMap {
            try? String(contentsOf: $0.deletingLastPathComponent().deletingLastPathComponent().appending(path: "pkg/version/release.go"),
                        encoding: .utf8)
        }
    }

    /// Reads `version.ValidTag` itself, so a change to the CLI's rule reds
    /// here until the app's check follows it.
    @Test("the app's tag check is version.ValidTag's rule", .enabled(if: releaseSource?.contains("func ValidTag(") == true))
    func mirrorsValidTag() throws {
        let source = try #require(Self.releaseSource)
        let body = try #require(UpdateAbortTests.body(of: "ValidTag", in: "\n" + source), "no ValidTag in pkg/version/release.go")
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("tag string) bool { if tag == \"\" || len(tag) > \(ReleaseTag.maxLength) || strings.HasPrefix(tag, \"-\") { return false }"),
                "ValidTag's length or prefix rule moved: \(flat)")
        #expect(flat.contains("for _, c := range tag { switch { case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '.', c == '+', c == '_', c == '-': default: return false } } return true }"),
                "ValidTag's character set moved: \(flat)")
    }

    @Test("--version is a flag k3sm update apply declares, checked with ValidTag",
          .enabled(if: UpdateAbortTests.updateSource?.contains("func runUpdateApply(") == true))
    func versionFlagDeclared() throws {
        let update = try #require(UpdateAbortTests.updateSource)
        let apply = try #require(UpdateAbortTests.body(of: "runUpdateApply", in: update))
        #expect(apply.contains("tag := fsFlags.String(\"version\", \"\""))
        #expect(apply.contains("if *tag != \"\" && !version.ValidTag(*tag) {"))
        // A given tag is the target; only an empty one resolves the latest release.
        #expect(apply.contains("target := *tag\n\tif target == \"\" {\n\t\trel, err := update.Latest("))
    }
}
