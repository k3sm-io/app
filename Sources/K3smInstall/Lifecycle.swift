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

import K3smStatus

/// LifecycleVerb is the closed set of lifecycle actions the app runs as
/// root: `k3sm stop`, `k3sm start` and `k3sm restart`. Nothing else, and no
/// string from the user or the CLI, ever reaches the lifecycle root script.
public enum LifecycleVerb: String, CaseIterable, Hashable, Sendable {
    case stop
    case start
    case restart

    /// The administrator prompt, which names the verb. Fixed text per verb.
    public var prompt: String {
        switch self {
        case .stop: return "k3sm wants to stop k3sm on this Mac."
        case .start: return "k3sm wants to start k3sm on this Mac."
        case .restart: return "k3sm wants to restart k3sm on this Mac."
        }
    }

    /// The button and menu title.
    public var title: String {
        switch self {
        case .stop: return "Stop k3sm"
        case .start: return "Start k3sm"
        case .restart: return "Restart k3sm"
        }
    }

    /// The state the verb starts from. Stop and restart act on a running
    /// node; start acts on a stopped one.
    public var requiredState: LifecycleState {
        self == .start ? .stopped : .running
    }
}

/// LifecycleExit names the exit statuses of a lifecycle run. The script's
/// own refusals sit above the CLI's range (0 to 3, and 33 to 95 for a stop
/// that left something behind), so the two never collide.
public enum LifecycleExit {
    /// The CLI refused or failed before anything was stopped.
    public static let failed: Int32 = 1
    /// The CLI did not accept the arguments: an older or different CLI.
    public static let usage: Int32 = 2
    /// The CLI did not run as root; nothing was done.
    public static let needsRoot: Int32 = 3
    /// A stop that left something behind exits `stopLeftoverBase` plus one
    /// bit per class (see `LifecycleOutcome.leftovers`).
    public static let stopLeftoverBase: Int32 = 32
    /// `/Library/k3sm/k3sm` or an ancestor was a symlink, missing, not owned
    /// by root, writable by group or others, or carried an ACL (an ACL can
    /// grant write where the mode bits do not); or the binary is not a
    /// regular file. Nothing ran.
    public static let refusedBinary: Int32 = 100
    /// The installed binary failed the Developer ID requirement. Nothing ran.
    public static let signatureRejected: Int32 = 101
}

/// LifecycleScriptBuilder renders the root script behind a lifecycle verb.
/// It shares nothing with the copy-out (`RootScriptBuilder`): it stages
/// nothing, takes no staging lock, and runs only the installed CLI, after
/// re-checking that the CLI and every directory above it are root-owned, not
/// group or other writable, not symlinks and carry no ACL, and that the CLI satisfies the
/// Developer ID requirement built from the compiled Team ID. A developer
/// build has no Team ID, so it can render no lifecycle script at all.
public enum LifecycleScriptBuilder {
    /// The fixed reason every app-run verb records (`--reason`).
    public static let reason = "from the k3sm app"

    /// The argv after the CLI path, the one definition of the command line.
    /// The golden tests pin it against `cmd/k3sm/lifecycle.go`.
    public static func arguments(for verb: LifecycleVerb) -> [String] {
        [verb.rawValue, "--actor", "user", "--reason", reason]
    }

    /// Every path the script checks before running the CLI: `/`, each
    /// directory above it, and the CLI itself.
    public static func checkedPaths(cliPath: String) -> [String] {
        var paths = ["/"]
        var current = ""
        for component in cliPath.split(separator: "/") {
            current += "/" + component
            paths.append(current)
        }
        return paths
    }

    /// Renders the script for the installed CLI at `K3smCLI.path`.
    public static func render(_ verb: LifecycleVerb, teamID: TeamID) -> RootScript {
        render(verb, teamID: teamID, cliPath: K3smCLI.path)
    }

    /// Renders the script for a CLI at `cliPath`. Only the tests pass another
    /// path, to prove the refusals against real directories.
    static func render(_ verb: LifecycleVerb, teamID: TeamID, cliPath: String) -> RootScript {
        let q = ShellQuote.quote
        let paths = checkedPaths(cliPath: cliPath).map(q).joined(separator: " ")
        let requirement = "-R=" + DesignatedRequirement.developerID(teamID: teamID)
        let argv = arguments(for: verb).map(q).joined(separator: " ")
        let text = #"""
            set -eu
            umask 077
            cd /
            k3sm=\#(q(cliPath))
            refuse() {
            	echo "k3sm app: refused: $1" >&2
            	exit \#(LifecycleExit.refusedBinary)
            }
            nl='
            '
            acl_check() {
            	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
            	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
            	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
            }
            for p in \#(paths); do
            	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
            	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
            	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$p could not be checked"
            	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
            	acl_check "$p"
            done
            if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
            if ! /usr/bin/codesign --verify --strict \#(q(requirement)) "$k3sm"; then
            	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
            	exit \#(LifecycleExit.signatureRejected)
            fi
            exec "$k3sm" \#(argv)
            """#
        return RootScript(text: text + "\n", prompt: verb.prompt, readsInput: false, usesStagingLock: false)
    }
}

/// LifecycleOutcome turns a finished lifecycle run into the sentence the app
/// shows.
public enum LifecycleOutcome {
    /// What each bit of a partial stop's exit code (minus 32) left behind,
    /// as `k3sm stop --help` documents it.
    public static let leftoverClasses: [(bit: Int32, name: String)] = [
        (1, "the node daemon"),
        (2, "pods, vm helpers or control-plane processes"),
        (4, "the mesh"),
        (8, "lo0, interconnect or pf state"),
        (16, "netd"),
        (32, "the stop marker"),
    ]

    /// The classes a stop's exit status names, or nil when the status is not
    /// a partial-stop code (33 to 95).
    public static func leftovers(exitStatus: Int32) -> [String]? {
        let n = exitStatus - LifecycleExit.stopLeftoverBase
        guard (1...63).contains(n) else { return nil }
        return leftoverClasses.filter { n & $0.bit != 0 }.map(\.name)
    }

    public static func text(_ outcome: PrivilegedOutcome, verb: LifecycleVerb) -> String {
        switch outcome {
        case .succeeded:
            switch verb {
            case .stop: return "k3sm is stopped. It stays stopped, across restarts too, until you start it."
            case .start: return "k3sm is starting."
            case .restart: return "k3sm restarted. Pods kept running."
            }
        case .cancelled:
            return "Cancelled. Nothing was changed."
        case .couldNotStart:
            return "The administrator prompt could not be shown. Nothing was changed."
        case .failed(let status):
            switch status {
            case LifecycleExit.refusedBinary:
                return "The installed k3sm at \(K3smCLI.path), or a folder above it, is not owned by root or is writable by others, so nothing was run."
            case LifecycleExit.signatureRejected:
                return "The installed k3sm is not signed by the k3sm Developer ID, so nothing was run."
            case LifecycleExit.needsRoot:
                return "k3sm did not run as root, so nothing was done."
            case LifecycleExit.usage:
                return "The installed k3sm did not accept `k3sm \(verb.rawValue)`. Update k3sm, or run `sudo k3sm \(verb.rawValue)` in Terminal."
            default:
                if verb == .stop, let left = leftovers(exitStatus: status) {
                    return "k3sm stopped part of the way and left behind " + left.joined(separator: ", ")
                        + ". Stop it again to finish."
                }
                if verb == .restart, status == LifecycleExit.failed {
                    return "k3sm refused or failed to restart (exit 1). If it is stopped, use Start instead. The logs say why."
                }
                return "k3sm \(verb.rawValue) failed with exit status \(status). The logs say why."
            }
        }
    }
}
