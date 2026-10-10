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

/// CopyOutExit names the exit statuses the root step chooses itself. Any
/// other non-zero status is the failing command's own (codesign, ditto, or
/// the staged `k3sm`), and its message is in the log.
public enum CopyOutExit {
    /// A fixed path (the log or the staging root) was a symlink.
    public static let refusedPath: Int32 = 64
    /// The copied tree held a symlink, a special file, a setuid or setgid
    /// file, or a group- or other-writable entry.
    public static let refusedTree: Int32 = 65
    /// A join ran but no token arrived on stdin.
    public static let missingToken: Int32 = 66
    /// Another copy-out holds the lock (lockf's EX_TEMPFAIL).
    public static let busy: Int32 = 75
    /// The staged copy failed the designated requirement.
    public static let signatureRejected: Int32 = 77
}

/// RootScript is a rendered root step: the script text, the prompt the
/// administrator dialog shows, and whether the script reads stdin.
public struct RootScript: Hashable, Sendable {
    /// The POSIX shell script root runs. Every interpolated value in it is a
    /// single-quoted shell word.
    public let text: String
    /// The administrator prompt for this action.
    public let prompt: String
    /// Whether the script reads the join token from stdin.
    public let readsInput: Bool

    /// The one command line the privileged runner executes: a scrubbed
    /// environment, the copy-out lock (failing at once if held), and the
    /// script as a single `sh -c` word, with stdin from `inputPath`
    /// (`/dev/null` when the script reads nothing).
    public func command(inputPath: String) -> String {
        "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin"
            + " /usr/bin/lockf -k -t 0 \(ShellQuote.quote(CopyOutPlan.lockPath))"
            + " /bin/sh -c \(ShellQuote.quote(text))"
            + " < \(ShellQuote.quote(inputPath))"
    }
}

/// RootScriptBuilder renders the root shell script for a copy-out plan:
/// set up the log, sweep stale staging entries, copy the bundle with no
/// extended attributes, refuse unsafe entries, chown to root, verify the
/// signature, run the staged CLI, and remove the staging directory on every
/// exit path, ending the log with `copy-out: exit <status>`.
public enum RootScriptBuilder {
    public static func render(_ plan: CopyOutPlan) -> RootScript {
        let q = ShellQuote.quote
        let staged = "\"$stage\"/\(q(CopyOutPlan.stagedBundleName))"
        let text = #"""
            set -eu
            umask 077
            cd /
            logdir=\#(q(CopyOutPlan.logDirectory))
            log=\#(q(CopyOutPlan.logPath))
            if [ -L "$logdir" ] || [ -L "$log" ]; then
            	echo 'copy-out: refused: the log path is a symlink' >&2
            	exit \#(CopyOutExit.refusedPath)
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
            root=\#(q(CopyOutPlan.stagingRoot))
            if [ -L "$root" ]; then
            	echo 'copy-out: refused: the staging root is a symlink'
            	exit \#(CopyOutExit.refusedPath)
            fi
            /bin/mkdir -p "$root"
            /usr/sbin/chown root:wheel "$root"
            /bin/chmod 0700 "$root"
            echo 'copy-out: sweeping stale staging entries'
            /usr/bin/find "$root" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
            stage=$(/usr/bin/mktemp -d \#(q(plan.stagingTemplate)))
            /usr/sbin/chown root:wheel "$stage"
            /bin/chmod 0700 "$stage"
            echo 'copy-out: copying the app bundle'
            /usr/bin/ditto --norsrc --noextattr --noqtn --noacl \#(q(plan.bundlePath)) \#(staged)
            bad=$(/usr/bin/find \#(staged) \( ! \( -type f -o -type d \) -o -perm +6022 \) -print | /usr/bin/head -n 1)
            if [ -n "$bad" ]; then
            	echo "copy-out: refused: $bad is a symlink, a special file, setuid or setgid, or writable by group or others"
            	exit \#(CopyOutExit.refusedTree)
            fi
            /usr/sbin/chown -R root:wheel \#(staged)
            echo 'copy-out: verifying the signature'
            if ! /usr/bin/codesign --verify --strict --deep \#(q("-R=" + plan.designatedRequirement)) \#(staged); then
            	echo 'copy-out: refused: the app is not signed by the k3sm Developer ID'
            	exit \#(CopyOutExit.signatureRejected)
            fi
            k3sm=\#(staged)/\#(q(CopyOutPlan.payloadCLI))
            \#(actionLines(plan, q: q))
            """#
        return RootScript(text: text + "\n", prompt: plan.action.prompt, readsInput: plan.action.readsToken)
    }

    private static func actionLines(_ plan: CopyOutPlan, q: (String) -> String) -> String {
        let token = "\"$stage\"/\(q(CopyOutPlan.tokenFileName))"
        switch plan.action {
        case .startServer:
            return #"""
                echo 'copy-out: running k3sm install'
                "$k3sm" install --from-staging "$stage"
                """#
        case .join(let server):
            return #"""
                ( umask 077 && /bin/cat > \#(token) )
                if [ ! -s \#(token) ]; then
                	echo 'copy-out: no join token arrived'
                	exit \#(CopyOutExit.missingToken)
                fi
                echo 'copy-out: running k3sm install --agent'
                "$k3sm" install --from-staging "$stage" --agent --server \#(q(server.argument)) --token-file \#(token)
                """#
        case .update:
            return #"""
                echo 'copy-out: running k3sm install (update)'
                "$k3sm" install --from-staging "$stage"
                """#
        case .uninstall(let purge):
            return #"""
                echo 'copy-out: running k3sm uninstall'
                "$k3sm" uninstall --yes\#(purge ? " --purge" : "")
                """#
        }
    }
}

/// CopyOutOutcome is what the copy-out log says about its run.
public enum CopyOutOutcome: Equatable, Sendable {
    /// No final status line yet: the run is in progress, or died without one.
    case unfinished
    case succeeded
    case failed(Int32)

    /// Reads the outcome from the log text: the last non-empty line, when it
    /// is `copy-out: exit <status>`.
    public init(log: String) {
        let last = log.split(separator: "\n").last { !$0.allSatisfy(\.isWhitespace) }
        let prefix = "copy-out: exit "
        guard let last, last.hasPrefix(prefix), let status = Int32(last.dropFirst(prefix.count)) else {
            self = .unfinished
            return
        }
        self = status == 0 ? .succeeded : .failed(status)
    }
}
