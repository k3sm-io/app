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
import K3smStatus

/// BugReport is the unprivileged bug-report collector: a static Terminal
/// `.command` that writes a fixed list of facts into one user-owned file
/// beside itself, then opens that file for the user to read. Nothing is
/// uploaded. It reads only an allowlist: the k3sm and macOS versions, the
/// status JSON, launchd's state lines for the k3sm daemons, and the tails of
/// k3sm's logs, all through a redaction pass. It never reads a kubeconfig, a
/// token, a Secret, the environment or pod manifests: the CLI runs under
/// `env -i` with HOME=/var/empty, and no kubectl call is made.
public enum BugReport {
    /// The report's file name, beside the `.command`.
    public static let reportName = "k3sm-bug-report.txt"
    /// The `.command` file name.
    public static let commandName = "k3sm-bug-report.command"
    /// The lines each log contributes.
    public static let logLines = 400
    /// The daemons whose launchd state is collected.
    public static let labels = ["io.k3sm.server", "io.k3sm.agent", "io.k3sm.netd"]
    /// The launchd fields kept from `launchctl print`; every other line,
    /// the job's environment included, is dropped.
    public static let launchdFields = #"^[[:space:]]*(state|pid|runs|last exit code|last terminating signal) = "#

    /// The redaction pass, as `sed -E` expressions applied to everything the
    /// report collects: k3s-style join tokens, bearer and JSON Web Tokens,
    /// `token=`, `password:` and `secret` style assignments, PEM blocks, and
    /// base64 keys of the WireGuard length.
    public static let redactions: [String] = [
        #"s/K10[0-9a-fA-F]{8,}::[^[:space:]"',]+/K10<redacted>/g"#,
        #"s/[Bb]earer [A-Za-z0-9._~+/=-]+/Bearer <redacted>/g"#,
        #"s/eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+/<redacted-jwt>/g"#,
        #"s/(token|password|passwd|secret|api[-_]?key)(["']?[[:space:]]*[:=][[:space:]]*["']?)[^[:space:]"',}]+/\1\2<redacted>/gI"#,
        #"/-----BEGIN [A-Z0-9 ]+-----/,/-----END [A-Z0-9 ]+-----/{/-----END/!d;s/.*/<redacted PEM block>/;}"#,
        #"s/[A-Za-z0-9+/]{43}=/<redacted-key>/g"#,
    ]

    /// The logs the report tails, in order.
    public static var logs: [String] {
        K3smLogs.paths(for: nil)
    }

    /// The `.command` text, for an installed CLI that passed its trust check.
    public static var commandText: String { commandText(cliTrusted: true) }

    /// The line a collector for an untrusted CLI writes instead of running it.
    public static let skippedCLI = "(not run: the installed k3sm failed the app's ownership or signature check)"

    /// The `.command` text. The app checks the installed CLI's trust just
    /// before writing it; for a CLI that failed, the two CLI calls become a
    /// fixed line and the CLI is never run. Either variant is the same on
    /// every Mac and for every user: nothing is interpolated from the app,
    /// the CLI or the user.
    public static func commandText(cliTrusted: Bool) -> String {
        let q = ShellQuote.quote
        let sed = redactions.map { "-e " + q($0) }.joined(separator: " ")
        let run = "/usr/bin/env -i PATH=\(K3smCLI.systemPath) HOME=/var/empty \"$k3sm\""
        let version = cliTrusted ? run + " version" : "echo " + q(skippedCLI)
        let status = cliTrusted ? run + " status -o json" : "echo " + q(skippedCLI)
        return #"""
            #!/bin/sh
            # k3sm bug report. Collects a fixed list of facts about k3sm on this
            # Mac into one file beside this script, for you to read before you
            # share it. Nothing is uploaded, and no kubeconfig, token, Secret,
            # environment or pod manifest is read.
            set -u
            umask 077
            cd "$(/usr/bin/dirname "$0")" || exit 1
            out="$PWD"/\#(q(reportName))
            k3sm=\#(q(K3smCLI.path))
            redact() { /usr/bin/sed -E \#(sed); }
            section() { printf '\n== %s\n' "$1"; }
            {
            	section 'macOS'
            	/usr/bin/sw_vers
            	section 'k3sm version'
            	\#(version)
            	section 'k3sm status -o json'
            	\#(status)
            	section 'launchd'
            	for label in \#(labels.map(q).joined(separator: " ")); do
            		printf -- '-- %s\n' "$label"
            		/bin/launchctl print "system/$label" 2>&1 | /usr/bin/grep -E \#(q(launchdFields))
            	done
            	/bin/launchctl print-disabled system 2>&1 | /usr/bin/grep -F 'io.k3sm.'
            	section 'logs'
            	for f in \#(logs.map(q).joined(separator: " ")); do
            		printf -- '-- %s (last \#(logLines) lines)\n' "$f"
            		if [ -r "$f" ]; then /usr/bin/tail -n \#(logLines) "$f"; else echo '(absent or not readable)'; fi
            	done
            } 2>&1 | redact > "$out"
            /bin/chmod 0600 "$out"
            echo "Wrote $out"
            echo 'Read it before you share it. It was not sent anywhere.'
            /usr/bin/open -t "$out"
            """# + "\n"
    }
}

/// StatusCommand is the Terminal `.command` behind "Open Status": the full
/// `k3sm status`, run as the user with the CLI's usual environment.
public enum StatusCommand {
    public static let commandName = "k3sm-status.command"

    public static var commandText: String {
        #"""
            #!/bin/sh
            # k3sm status, opened from the k3sm app.
            exec /usr/bin/env -i PATH=\#(K3smCLI.systemPath) HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \#(ShellQuote.quote(K3smCLI.path)) status
            """# + "\n"
    }
}

/// CommandFile writes a `.command` into a fresh 0700 directory of its own,
/// created with `mkdtemp` under `base`, as a new 0700 file (never following
/// or replacing an existing one), and returns its path.
public enum CommandFile {
    public enum WriteError: Error, Equatable {
        case directory(Int32)
        case file(Int32)
    }

    public static func write(_ text: String, named name: String, under base: String) throws(WriteError) -> String {
        precondition(!name.contains("/") && !name.isEmpty, "a fixed file name")
        var template = Array((base + "/k3sm-app.XXXXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw .directory(errno) }
        let directory = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard chmod(directory, 0o700) == 0 else { throw .directory(errno) }
        let path = directory + "/" + name
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
        guard fd >= 0 else { throw .file(errno) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw .file(errno) }
            offset += n
        }
        guard fchmod(fd, 0o700) == 0 else { throw .file(errno) }
        return path
    }
}
