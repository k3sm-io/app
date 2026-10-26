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

/// LifecycleVerb is the closed set of actions the app runs as root through
/// the installed CLI: `k3sm stop`, `k3sm start` and `k3sm restart`, the
/// two LAN access verbs, `k3sm network lan on` and `k3sm network lan off`,
/// and the three managed update verbs, `k3sm update apply --yes`,
/// `k3sm update cancel` and `k3sm update abort`.
/// Nothing else, and no string from the user or the CLI, ever reaches the
/// root script: each verb's argv but the apply's is a compile-time constant
/// (`LifecycleScriptBuilder.arguments(for:)`, over `FixedVerb`), and the
/// apply's is only the fixed flags its `UpdateOptions` name and `--version`
/// with the release the user confirmed, a `ReleaseTag`
/// (`updateApplyArguments(options:release:)`), which it cannot be rendered
/// without.
public enum LifecycleVerb: String, CaseIterable, Hashable, Sendable {
    case stop
    case start
    case restart
    case lanOn = "lan-on"
    case lanOff = "lan-off"
    case updateApply = "update-apply"
    case updateCancel = "update-cancel"
    case updateAbort = "update-abort"

    /// The three lifecycle verbs, which act on the node daemon's state.
    public static let lifecycleVerbs: [LifecycleVerb] = [.stop, .start, .restart]
    /// The two LAN access verbs, which change where workload listeners answer.
    public static let lanVerbs: [LifecycleVerb] = [.lanOn, .lanOff]

    /// The three managed update verbs, which act on the cluster's roll.
    public static let updateVerbs: [LifecycleVerb] = [.updateApply, .updateCancel, .updateAbort]

    /// Whether this is one of the managed update verbs.
    public var isUpdate: Bool { Self.updateVerbs.contains(self) }

    /// Whether this is one of the LAN access verbs.
    public var isLAN: Bool { self == .lanOn || self == .lanOff }

    /// The CLI command the verb runs, as a user would type it after `k3sm`.
    public var command: String {
        switch self {
        case .stop, .start, .restart: return rawValue
        case .lanOn: return "network lan on"
        case .lanOff: return "network lan off"
        case .updateApply: return "update apply --yes"
        case .updateCancel: return "update cancel"
        case .updateAbort: return "update abort"
        }
    }

    /// The administrator prompt, which names the verb. Fixed text per verb.
    public var prompt: String {
        switch self {
        case .stop: return "k3sm wants to stop k3sm on this Mac."
        case .start: return "k3sm wants to start k3sm on this Mac."
        case .restart: return "k3sm wants to restart k3sm on this Mac."
        case .lanOn: return "k3sm wants to allow connections from other devices to the services k3sm runs on this Mac."
        case .lanOff: return "k3sm wants to stop allowing connections from other devices to the services k3sm runs on this Mac."
        case .updateApply: return "k3sm wants to update k3sm on every node of this cluster."
        case .updateCancel: return "k3sm wants to cancel the k3sm update."
        case .updateAbort: return "k3sm wants to abort the k3sm update and release every node."
        }
    }

    /// The button and menu title.
    public var title: String {
        switch self {
        case .stop: return "Stop k3sm"
        case .start: return "Start k3sm"
        case .restart: return "Restart k3sm"
        case .lanOn: return "Allow Connections"
        case .lanOff: return "Stop Allowing Connections"
        case .updateApply: return "Update k3sm"
        case .updateCancel: return "Cancel Update"
        case .updateAbort: return "Abort Update"
        }
    }

    /// The state the verb starts from. Stop and restart act on a running
    /// node; start acts on a stopped one. The LAN verbs act in either state
    /// (a stopped node applies the setting when it starts), so they have none.
    /// The update verbs act on the cluster's roll, which the CLI checks
    /// itself, so they have none either.
    public var requiredState: LifecycleState? {
        switch self {
        case .stop, .restart: return .running
        case .start: return .stopped
        case .lanOn, .lanOff, .updateApply, .updateCancel, .updateAbort: return nil
        }
    }
}

/// LifecycleExit names the exit statuses of a lifecycle run. The script's
/// own refusals (100 and up) sit above the CLI's range (0 to 4, and 33 to 95
/// for a stop that left something behind), so the two never collide.
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
    /// `k3sm network lan on|off` failed and could not restore the previous
    /// setting either.
    public static let lanRestoreFailed: Int32 = 4
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

    /// FixedVerb is every verb whose argv is a compile-time constant: all of
    /// them but the apply, which carries the release the user confirmed and
    /// is rendered only by `renderUpdateApply(teamID:options:release:)`. So no
    /// path can render an apply without its release.
    public enum FixedVerb: String, CaseIterable, Hashable, Sendable {
        case stop, start, restart
        case lanOn = "lan-on"
        case lanOff = "lan-off"
        case updateCancel = "update-cancel"
        case updateAbort = "update-abort"

        /// `verb` as a fixed verb, or nil for the apply.
        public init?(_ verb: LifecycleVerb) {
            self.init(rawValue: verb.rawValue)
        }

        /// The verb this is.
        public var verb: LifecycleVerb { LifecycleVerb(rawValue: rawValue)! }
    }

    /// The argv after the CLI path, the one definition of the command line.
    /// The golden tests pin it against `cmd/k3sm/lifecycle.go`.
    public static func arguments(for verb: FixedVerb) -> [String] {
        switch verb {
        case .stop: return ["stop", "--actor", "user", "--reason", reason]
        case .start: return ["start", "--actor", "user", "--reason", reason]
        case .restart: return ["restart", "--actor", "user", "--reason", reason]
        case .lanOn: return ["network", "lan", "on"]
        case .lanOff: return ["network", "lan", "off"]
        case .updateCancel: return K3smCLI.updateCancelArguments
        case .updateAbort: return K3smCLI.updateAbortArguments
        }
    }

    /// The apply's argv: its flags (`UpdateOptions.arguments`, a fixed
    /// vocabulary), then `--version` and the release the user confirmed, so
    /// the CLI moves to that release and does not resolve the latest one
    /// again at run time. The release is required.
    public static func updateApplyArguments(options: UpdateOptions, release: ReleaseTag) -> [String] {
        options.arguments + ["--version", release.value]
    }

    /// Every path the script checks before running the CLI: `/`, each
    /// directory above it, and the CLI itself.
    public static func checkedPaths(cliPath: String) -> [String] {
        InstalledCLIPreamble.checkedPaths(cliPath: cliPath)
    }

    /// Renders the script for a fixed verb's CLI at `K3smCLI.path`.
    public static func render(_ verb: FixedVerb, teamID: TeamID) -> RootScript {
        render(verb.verb, argv: arguments(for: verb), teamID: teamID, cliPath: K3smCLI.path)
    }

    /// Renders the apply's script, pinned to `release`, with `options`
    /// (the defaults add no flag). `UpdateDriver.apply` is its one caller.
    public static func renderUpdateApply(teamID: TeamID, options: UpdateOptions, release: ReleaseTag) -> RootScript {
        render(.updateApply, argv: updateApplyArguments(options: options, release: release), teamID: teamID, cliPath: K3smCLI.path)
    }

    /// Renders a fixed verb's script for a CLI at `cliPath`. Only the tests
    /// pass another path, to prove the refusals against real directories.
    static func render(_ verb: FixedVerb, teamID: TeamID, cliPath: String) -> RootScript {
        render(verb.verb, argv: arguments(for: verb), teamID: teamID, cliPath: cliPath)
    }

    /// ImageVerb is every `k3sm image` verb the Images tab runs as root: pull
    /// and prune talk to the root-owned runtimed socket, and untag and prune's
    /// registry half read the server's registry push credential under the
    /// control-plane state root. The two prune verbs are compile-time
    /// constants; untag carries only a `RegistryTag` and pull only an
    /// `ImageRef`, which they cannot be rendered without, so no free text
    /// reaches the script.
    public enum ImageVerb: Hashable, Sendable {
        /// `k3sm image prune`: the CLI's default dry run, a read.
        case pruneDryRun
        /// `k3sm image prune --force`.
        case prune
        /// `k3sm image untag <tag> --digest <digest>`.
        case untag(RegistryTag)
        /// `k3sm image pull <reference>`.
        case pull(ImageRef)

        /// The CLI command, as a user would type it after `k3sm`.
        public var command: String {
            switch self {
            case .pruneDryRun: return "image prune"
            case .prune: return "image prune --force"
            case .untag: return "image untag"
            case .pull: return "image pull"
            }
        }

        /// The administrator prompt, which names this Mac and, for untag
        /// and pull, the reference.
        public var prompt: String {
            switch self {
            case .pruneDryRun: return ImageStoreText.promptPruneDryRun
            case .prune: return ImageStoreText.promptPrune
            case .untag(let tag): return ImageStoreText.prompt(untag: tag)
            case .pull(let reference): return ImageStoreText.prompt(pull: reference)
            }
        }
    }

    /// An image verb's argv after the CLI path, from `K3smCLI`; the golden
    /// tests pin it against `cmd/k3sm/image.go`.
    public static func imageArguments(_ verb: ImageVerb) -> [String] {
        switch verb {
        case .pruneDryRun: return K3smCLI.imagePruneDryRunArguments
        case .prune: return K3smCLI.imagePruneArguments
        case .untag(let tag): return K3smCLI.imageUntagArguments(tag)
        case .pull(let reference): return K3smCLI.imagePullArguments(reference)
        }
    }

    /// Renders an image verb's script for the CLI at `K3smCLI.path`: the
    /// same checks as every lifecycle verb, then the one CLI line. It is the
    /// only script that asks for its standard output back (`capturesOutput`).
    public static func renderImage(_ verb: ImageVerb, teamID: TeamID) -> RootScript {
        renderImage(verb, teamID: teamID, cliPath: K3smCLI.path)
    }

    static func renderImage(_ verb: ImageVerb, teamID: TeamID, cliPath: String) -> RootScript {
        render(prompt: verb.prompt, argv: imageArguments(verb), teamID: teamID, cliPath: cliPath, capturesOutput: true)
    }

    private static func render(_ verb: LifecycleVerb, argv words: [String], teamID: TeamID, cliPath: String) -> RootScript {
        render(prompt: verb.prompt, argv: words, teamID: teamID, cliPath: cliPath)
    }

    private static func render(prompt: String, argv words: [String], teamID: TeamID, cliPath: String,
                               capturesOutput: Bool = false) -> RootScript {
        let argv = words.map(ShellQuote.quote).joined(separator: " ")
        let text = InstalledCLIPreamble.render(teamID: teamID, cliPath: cliPath) + "exec \"$k3sm\" \(argv)\n"
        return RootScript(text: text, prompt: prompt, readsInput: false, usesStagingLock: false, capturesOutput: capturesOutput)
    }
}

/// InstalledCLIPreamble is the one definition of the checks every root script
/// that runs the installed CLI makes first (the lifecycle verbs and the join
/// token mint): `set -eu`, `umask 077`, `cd /`; the CLI and every directory
/// above it root-owned, not group or other writable, not symlinks and with no
/// ACL; the CLI a regular file that passes `codesign --verify -R` against the
/// Developer ID requirement built from the compiled Team ID. It ends with
/// `$k3sm` set and checked, ready for the caller's one CLI line.
public enum InstalledCLIPreamble {
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

    /// The preamble text, ending in a newline.
    public static func render(teamID: TeamID, cliPath: String) -> String {
        let q = ShellQuote.quote
        let paths = checkedPaths(cliPath: cliPath).map(q).joined(separator: " ")
        let requirement = "-R=" + DesignatedRequirement.developerID(teamID: teamID)
        return #"""
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

            """#
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
            case .lanOn: return "Devices on the networks this Mac is on can now connect to its k3sm services."
            case .lanOff: return "Only this Mac and your cluster mesh can connect to its k3sm services now."
            case .updateApply: return "The update has started. Each node updates in turn, the server last."
            case .updateCancel: return "k3sm is cancelling the update."
            case .updateAbort: return "k3sm released every node from the update, and marked any unfinished update Cancelled. Nothing was rolled back: every node keeps the release it runs, and a node already installing may still finish."
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
                return "The installed k3sm did not accept `k3sm \(verb.command)`. Update k3sm, or run `sudo k3sm \(verb.command)` in Terminal."
            case LifecycleExit.lanRestoreFailed where verb.isLAN:
                return "The change failed, and k3sm could not put the previous setting back either. Run `sudo k3sm network lan status` in Terminal."
            case LifecycleExit.failed where verb.isLAN:
                return "k3sm could not change the setting and kept the previous one."
            default:
                if verb == .stop, let left = leftovers(exitStatus: status) {
                    return "k3sm stopped part of the way and left behind " + left.joined(separator: ", ")
                        + ". Stop it again to finish."
                }
                if verb == .restart, status == LifecycleExit.failed {
                    return "k3sm refused or failed to restart (exit 1). If it is stopped, use Start instead. The logs say why."
                }
                return "k3sm \(verb.command) failed with exit status \(status). The logs say why."
            }
        }
    }
}
