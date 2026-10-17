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

/// TerminalScript is the `.command` file a build with no Team ID pin opens in
/// Terminal so a user can install k3sm without the administrator step the
/// app cannot run: `#!/bin/sh`, `set -e`, the script's own private directory
/// removed on exit, each fixed command printed and then run, and a closing
/// line printed only after every command succeeded. Terminal asks for the
/// password through `sudo`; the app itself runs nothing as root.
///
/// The script is built only from constants, the release the app carries, the
/// app's own payload path (already shell-quoted by the app) and, for a join,
/// the server host after the address grammar checked it. A join token never
/// enters it: the script reads the token in Terminal with echo off and hands
/// it on a pipe to one root shell, which writes it to a file only root can
/// read, runs the agent install from it and removes it on its own exit.
///
/// | build | start | join |
/// |---|---|---|
/// | carries a payload | `sudo <payload>/k3sm install` | `<payload>/k3sm install --agent --server <host> --token-file <file>` in the token's root shell |
/// | no payload | the install script, downloaded to the script's directory, then run | the script's download-only mode, then `./k3sm install --agent …` in the token's root shell |
public enum TerminalScript {
    /// The k3sm CLI inside the app's payload, as one shell word. The app
    /// builds it from a path inside its own bundle (`payloadCLIPath`) and
    /// quotes it with the root step's quoting.
    public struct Payload: Equatable, Sendable {
        public let quotedCLI: String
        public init(quotedCLI: String) { self.quotedCLI = quotedCLI }
    }

    /// The file the script is written to, in a fresh private directory.
    public static let fileName = "k3sm-install.command"
    /// The script's last line after an install.
    public static let doneLine = "k3sm is installed; you can close this window and return to k3sm.app."
    /// The script's last line after a join.
    public static let joinedLine = "This Mac joined the cluster; you can close this window and return to k3sm.app."
    /// What the join script asks before it reads the token.
    public static let tokenPrompt = "Paste the join token, then press Return. It is not shown."
    /// The prefix of the private directory `CommandFile` makes; the exit
    /// trap removes the script's directory only when its name has it.
    public static let directoryPrefix = "k3sm-app."

    /// The one command an install runs, as shown: the payload's own install
    /// when the app carries one, else the install script pinned to `version`.
    public static func installCommand(version: SemanticVersion?, payload: Payload?) -> String {
        guard let payload else { return GuidedSteps.installScriptCommand(version: version) }
        return "sudo \(payload.quotedCLI) install"
    }

    /// The install script: the payload's install, or the install script
    /// downloaded beside this one (a failed download stops it, where a pipe
    /// into `sh` would hide it) and then run.
    public static func install(version: SemanticVersion?, payload: Payload?) -> String {
        var lines = prologue(join: false)
        if let payload {
            let command = "sudo \(payload.quotedCLI) install"
            lines += [echo("Running: " + command), command]
        } else {
            let download = "curl -fsSL \(GuidedSteps.installScriptURL) -o install.sh"
            let pin = GuidedSteps.releasePin(version).map { "K3SM_INSTALL_VERSION=v\($0) " } ?? ""
            let run = "\(pin)sh install.sh"
            lines += [echo("Running: " + download), download, echo("Running: " + run), run]
        }
        lines.append(echo(doneLine))
        return render(lines)
    }

    /// The root shell a join's token goes to on its stdin: it writes the
    /// token to a file only root can read, removes it on any exit (an
    /// interrupt included), and runs the agent install from it. The CLI and
    /// the host arrive as `$1` and `$2`; the token is never an argument.
    static var tokenRootShell: String {
        let file = FirstRunFlow.joinTokenFile
        return #"umask 077; trap "rm -f \#(file)" EXIT; trap "exit 130" INT TERM HUP; "#
            + #"cat > \#(file); "$1" install --agent --server "$2" --token-file \#(file)"#
    }

    /// The join as commands a user can also paste into Terminal: the
    /// release fetched where the app carries none, the token read with echo
    /// off, and one `sudo` that stores it, installs the agent and removes it.
    /// Nil for a host that is missing or holds a character outside the
    /// address grammar.
    public static func joinCommands(serverArgument: String?, payload: Payload?, version: SemanticVersion?) -> [String]? {
        guard let parts = joinParts(serverArgument: serverArgument, payload: payload, version: version) else { return nil }
        return parts.fetch + [
            "printf 'Join token: '; read -rs token; echo",
            parts.join + "; unset token",
        ]
    }

    /// The join script: the release fetched where the app carries none, the
    /// token read in Terminal with echo off, and the one root shell that
    /// stores it, installs the agent and removes it. Nil where
    /// `joinCommands` is.
    public static func join(serverArgument: String?, payload: Payload?, version: SemanticVersion?) -> String? {
        guard let parts = joinParts(serverArgument: serverArgument, payload: payload, version: version) else { return nil }
        var lines = prologue(join: true)
        for command in parts.fetch {
            lines += [echo("Running: " + command), command]
        }
        lines += [
            echo(tokenPrompt),
            "stty -echo",
            "IFS= read -r token",
            "stty echo",
            "echo",
            echo("Running: " + parts.join),
            parts.join,
            "token=",
            echo(joinedLine),
        ]
        return render(lines)
    }

    /// The payload's CLI path when the payload directory resolves inside the
    /// running bundle and holds a regular `k3sm` file; nil otherwise. Both
    /// paths are already resolved (symlinks, `..`) by the caller.
    public static func payloadCLIPath(payloadDirectory: String, bundle: String, cliIsRegularFile: Bool) -> String? {
        guard cliIsRegularFile, bundle.hasPrefix("/"), bundle.count > 1,
              payloadDirectory.hasPrefix(bundle.hasSuffix("/") ? bundle : bundle + "/"),
              !payloadDirectory.split(separator: "/").contains("..") else { return nil }
        return payloadDirectory + "/k3sm"
    }

    /// The script's first lines: stop on the first failure, work in the
    /// script's own private directory, and remove that directory (the
    /// script, a download and anything unpacked) on exit, restoring the
    /// terminal's echo first for a join. The removal needs the directory's
    /// own name to carry `directoryPrefix` and the directory to hold the
    /// running script, so no other folder is ever removed.
    static func prologue(join: Bool) -> [String] {
        let restore = join ? "stty echo 2>/dev/null || true; " : ""
        return [
            "set -e",
            #"dir=$(cd "$(dirname "$0")" && pwd)"#,
            #"trap '\#(restore)case "${dir##*/}" in \#(directoryPrefix)*) if [ -f "$dir/$(basename "$0")" ]; then rm -rf "$dir"; fi ;; esac' EXIT"#,
            #"cd "$dir""#,
        ]
    }

    /// A join's fetch commands and its root-shell line (the token only ever
    /// as `$token`, expanded by the user's shell into the pipe).
    private static func joinParts(serverArgument: String?, payload: Payload?, version: SemanticVersion?)
        -> (fetch: [String], join: String)? {
        guard let host = serverArgument, !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.utf8.allSatisfy(JoinCommandParser.isAddressByte),
              !host.contains("["), !host.contains("]") else { return nil }
        var fetch: [String] = []
        let cli: String
        if let payload {
            cli = payload.quotedCLI
        } else {
            let version = GuidedSteps.releasePin(version)
            let pin = version.map { "K3SM_INSTALL_VERSION=v\($0) " } ?? ""
            let archive = version.map { "k3sm_\($0)_darwin_arm64.tar.gz" } ?? "k3sm_*_darwin_arm64.tar.gz"
            fetch = [
                "curl -fsSL \(GuidedSteps.installScriptURL) | \(pin)K3SM_INSTALL_DOWNLOAD_ONLY=1 sh",
                "tar -xzf \(archive)",
            ]
            cli = "./k3sm"
        }
        let line = #"printf '%s\n' "$token" | sudo sh -c '\#(tokenRootShell)' sh \#(cli) \#(host)"#
        return (fetch, line)
    }

    /// Prints fixed text as one single-quoted word, through `printf '%s\n'`
    /// so a backslash in it is shown as written (`/bin/sh`'s `echo`
    /// expands one).
    static func echo(_ text: String) -> String {
        #"printf '%s\n' '"# + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func render(_ lines: [String]) -> String {
        "#!/bin/sh\n" + lines.joined(separator: "\n") + "\n"
    }
}
