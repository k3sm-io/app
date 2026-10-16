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

/// The bug report is a static Terminal `.command`. These tests read its text
/// and run its redaction program; they never run the collector itself.
@Suite("bug report collector")
struct BugReportTests {
    static let text = BugReport.commandText

    @Test("the script is valid sh and the same on every run")
    func valid() throws {
        #expect(try shell(["-n", "-c", Self.text]).status == 0)
        #expect(BugReport.commandText == Self.text)
        #expect(Self.text.hasPrefix("#!/bin/sh\n"))
    }

    @Test("it reads only the allowlist")
    func allowlist() {
        for forbidden in [".kube", "kubeconfig", "KUBECONFIG", "kubectl", "printenv", "/usr/bin/env\n", " set\n", "export",
                          "token create", "secret", "get pods", "manifest", "curl", "nc ", "scp", "http", "/var/lib/k3sm",
                          "sudo", "osascript", "$HOME"] {
            #expect(!Self.text.lowercased().contains(forbidden.lowercased()) || Self.allowedMention(forbidden), "the collector mentions \(forbidden)")
        }
        for wanted in ["umask 077", "/usr/bin/sw_vers", "\"$k3sm\" version", "\"$k3sm\" status -o json",
                       "/bin/launchctl print \"system/$label\"", "/usr/bin/tail -n 400", "| redact > \"$out\"",
                       "/bin/chmod 0600 \"$out\"", "/usr/bin/open -t \"$out\""] {
            #expect(Self.text.contains(wanted), "the collector lacks \(wanted)")
        }
    }

    /// The header comment states what is never read, and the redaction
    /// program names what it scrubs; those mentions are fine.
    static func allowedMention(_ word: String) -> Bool {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("redact() {") }
            .joined(separator: "\n").lowercased()
        return !body.contains(word.lowercased())
    }

    @Test("the CLI runs under an empty environment with no home, so no kubeconfig is found")
    func cliEnvironment() {
        let lines = Self.text.split(separator: "\n").filter { $0.contains("\"$k3sm\"") }
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.contains("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty \"$k3sm\""))
        }
    }

    @Test("launchd output keeps only the state lines")
    func launchdFilter() throws {
        let sample = "\tstate = running\n\tenvironment = {\n\t\tK3SM_TOKEN => abc\n\t}\n\tpid = 12\n\tlast exit code = 0\n\tprogram = /x\n"
        let r = try shell(["-c", "printf '%s' " + ShellQuote.quote(sample) + " | /usr/bin/grep -E " + ShellQuote.quote(BugReport.launchdFields)])
        #expect(r.output == "\tstate = running\n\tpid = 12\n\tlast exit code = 0\n")
    }

    @Test("every log it tails is one of k3sm's fixed logs")
    func logs() {
        #expect(BugReport.logs == K3smLogs.paths(for: nil))
        for log in BugReport.logs {
            #expect(Self.text.contains(ShellQuote.quote(log)))
        }
    }

    static func redact(_ input: String) throws -> String {
        let program = BugReport.redactions.map { "-e " + ShellQuote.quote($0) }.joined(separator: " ")
        return try shell(["-c", "printf '%s' " + ShellQuote.quote(input) + " | /usr/bin/sed -E " + program]).output
    }

    @Test("the redaction pass", arguments: [
        ("join K10abcdef0123456789::server:s3cr3tvalue now", "join K10<redacted> now"),
        ("Authorization: Bearer abc.def-ghi", "Authorization: Bearer <redacted>"),
        ("jwt eyJhbGciOi.eyJzdWIiOi.sig_abc ok", "jwt <redacted-jwt> ok"),
        (#""token": "hunter2", password=pw1 Secret: shh API_KEY=xyz"#,
         #""token": "<redacted>", password=<redacted> Secret: <redacted> API_KEY=<redacted>"#),
        ("a\n-----BEGIN PRIVATE KEY-----\nMIIEv\nAAAA\n-----END PRIVATE KEY-----\nb", "a\n<redacted PEM block>\nb"),
        ("key ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq= end", "key <redacted-key> end"),
        ("node my-mac pid 1292 runs 3", "node my-mac pid 1292 runs 3"),
    ])
    func redaction(_ input: String, _ want: String) throws {
        #expect(try Self.redact(input + "\n") == want + "\n")
    }

    @Test("a CLI that failed its trust check is left out, never run")
    func untrustedCLI() throws {
        let text = BugReport.commandText(cliTrusted: false)
        #expect(try shell(["-n", "-c", text]).status == 0)
        #expect(!text.contains("\"$k3sm\" version"))
        #expect(!text.contains("\"$k3sm\" status"))
        #expect(text.components(separatedBy: "echo " + ShellQuote.quote(BugReport.skippedCLI)).count == 3)
        // Everything else is the same collector.
        #expect(text.contains("/usr/bin/tail -n 400"))
        #expect(BugReport.commandText == BugReport.commandText(cliTrusted: true))
    }

    @Test("the report and its script are named, never typed")
    func names() {
        #expect(BugReport.reportName == "k3sm-bug-report.txt")
        #expect(BugReport.commandName.hasSuffix(".command"))
        #expect(Self.text.contains("out=\"$PWD\"/'k3sm-bug-report.txt'"))
    }
}

@Suite("live status commands")
struct StatusCommandTests {
    /// The golden script for one live view, for a CLI at `cli` (already
    /// shell-quoted) running `arguments`.
    static func golden(header: String, title: String, hint: String, cli: String, arguments: String, name: String) -> String {
        """
        #!/bin/sh
        # \(header), opened from the k3sm app. It redraws in place until Control-C.
        printf '\\033]0;%s\\007' '\(title) (live)'
        echo '\(hint)'
        trap : INT
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \(cli) \(arguments)
        code=$?
        trap - INT
        printf '\\033]0;%s\\007' '\(title) (stopped)'
        if [ "$code" -eq 0 ] || [ "$code" -eq 130 ]; then
        \techo '\(name) stopped. Close this window, or open it again from the k3sm menu.'
        \texit 0
        fi
        echo "\(name) stopped: k3sm exited with status $code."
        exit "$code"

        """
    }

    static let statusHint = "k3sm status, live: refreshes every 2 s. Control-C to stop."
    static let topHint = "k3sm top, live: refreshes every 2 s. Control-C to stop."

    @Test("both live views run the installed CLI's watch, titled, with a hint and a stopped line")
    func statusCommandRunsWatch() throws {
        let status = Self.golden(header: "k3sm status, live", title: "k3sm status", hint: Self.statusHint,
                                 cli: "'/Library/k3sm/k3sm'", arguments: "status -o wide --watch=2s", name: "k3sm status")
        let top = Self.golden(header: "k3sm top, live", title: "k3sm top", hint: Self.topHint,
                              cli: "'/Library/k3sm/k3sm'", arguments: "status top --watch=2s", name: "k3sm top")
        #expect(StatusCommand.commandText == status)
        #expect(TopCommand.commandText == top)
        #expect(StatusCommand.commandName == "k3sm-status.command")
        #expect(TopCommand.commandName == "k3sm-top.command")
        // A CLI path with a space or a quote stays one shell word.
        #expect(StatusCommand.commandText(cliPath: "/Volumes/My Disk/k3sm's/k3sm") == Self.golden(
            header: "k3sm status, live", title: "k3sm status", hint: Self.statusHint,
            cli: #"'/Volumes/My Disk/k3sm'\''s/k3sm'"#, arguments: "status -o wide --watch=2s", name: "k3sm status"))
        #expect(TopCommand.commandText(cliPath: "/Volumes/My Disk/k3sm") == Self.golden(
            header: "k3sm top, live", title: "k3sm top", hint: Self.topHint,
            cli: "'/Volumes/My Disk/k3sm'", arguments: "status top --watch=2s", name: "k3sm top"))
        for text in [StatusCommand.commandText, TopCommand.commandText] {
            #expect(try shell(["-n", "-c", text]).status == 0)
        }
    }

    /// Runs one command against a stand-in CLI at a path with a space, which
    /// prints its arguments and exits with `code`.
    static func run(_ command: (String) -> String, code: Int32) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm live \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appending(path: "k3sm").path
        try "#!/bin/sh\necho \"args: $*\"\nexit \(code)\n".write(toFile: cli, atomically: true, encoding: .utf8)
        #expect(chmod(cli, 0o755) == 0)
        return try shell(["-c", command(cli)]).output
    }

    @Test("the stand-in CLI gets the watch arguments, and the view says when it stopped")
    func runsAndStops() throws {
        let interrupted = try Self.run({ StatusCommand.commandText(cliPath: $0) }, code: 130)
        #expect(interrupted == "\u{1B}]0;k3sm status (live)\u{07}" + Self.statusHint + "\nargs: status -o wide --watch=2s\n"
            + "\u{1B}]0;k3sm status (stopped)\u{07}k3sm status stopped. Close this window, or open it again from the k3sm menu.\n")
        let failed = try Self.run({ TopCommand.commandText(cliPath: $0) }, code: 2)
        #expect(failed.hasSuffix("args: status top --watch=2s\n\u{1B}]0;k3sm top (stopped)\u{07}k3sm top stopped: k3sm exited with status 2.\n"))
    }
}

@Suite("command files")
struct CommandFileTests {
    static func base() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm-cmdfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("a fresh 0700 directory and a 0700 file holding exactly the text")
    func write() throws {
        let base = try Self.base()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = try CommandFile.write(BugReport.commandText, named: BugReport.commandName, under: base)
        let dir = (path as NSString).deletingLastPathComponent
        #expect((path as NSString).lastPathComponent == BugReport.commandName)
        #expect((dir as NSString).deletingLastPathComponent == base)
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: dir)[.posixPermissions] as? Int) == 0o700)
        #expect((try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o700)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == BugReport.commandText)
        #expect(try fm.contentsOfDirectory(atPath: dir) == [BugReport.commandName])
    }

    @Test("each write gets its own directory")
    func fresh() throws {
        let base = try Self.base()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let a = try CommandFile.write("a", named: "x.command", under: base)
        let b = try CommandFile.write("b", named: "x.command", under: base)
        #expect(a != b)
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "a")
    }

    @Test("a missing base fails without writing")
    func missingBase() {
        #expect(throws: CommandFile.WriteError.self) {
            try CommandFile.write("a", named: "x.command", under: "/nonexistent-k3sm-base")
        }
    }
}
