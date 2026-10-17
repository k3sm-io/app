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
/// app cannot run: `#!/bin/sh`, `set -e`, each fixed command echoed and then
/// run, and a closing line. Terminal asks for the password through `sudo`;
/// the app itself runs nothing as root.
///
/// The script is built only from constants, the release the app carries, the
/// app's own payload path (already shell-quoted by the app) and, for a join,
/// the server host after the address grammar checked it. A join token never
/// enters it: the script reads the token in Terminal with echo off and hands
/// it to `sudo` on a pipe, into a file only root can read, removed when the
/// script exits.
///
/// | build | start | join |
/// |---|---|---|
/// | carries a payload | `sudo <payload>/k3sm install` | `sudo <payload>/k3sm install --agent --server <host> --token-file <file>` |
/// | no payload | the install script (`GuidedSteps.installScriptCommand`) | the script's download-only mode, then `sudo ./k3sm install --agent …` from the download |
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

    /// The one command an install runs: the payload's own install when the
    /// app carries one, else the install script pinned to `version`.
    public static func installCommand(version: SemanticVersion?, payload: Payload?) -> String {
        guard let payload else { return GuidedSteps.installScriptCommand(version: version) }
        return "sudo \(payload.quotedCLI) install"
    }

    /// The install script: `installCommand` and nothing else.
    public static func install(version: SemanticVersion?, payload: Payload?) -> String {
        let command = installCommand(version: version, payload: payload)
        return render(["set -e", echo("Running: " + command), command, echo(doneLine)])
    }

    /// The join as commands a user can also paste into Terminal (the token
    /// typed into `cat`, then Control-D). Nil for a host that is missing or
    /// holds a character outside the address grammar.
    public static func joinCommands(serverArgument: String?, payload: Payload?, version: SemanticVersion?) -> [String]? {
        guard let parts = joinParts(serverArgument: serverArgument, payload: payload, version: version) else { return nil }
        return parts.fetch + ["sudo sh -c 'umask 077; cat > \(FirstRunFlow.joinTokenFile)'", parts.install]
    }

    /// The join script: the release fetched where the app carries none, the
    /// token read in Terminal with echo off into a root-only file, the agent
    /// install, and the file removed on exit. Nil where `joinCommands` is.
    public static func join(serverArgument: String?, payload: Payload?, version: SemanticVersion?) -> String? {
        guard let parts = joinParts(serverArgument: serverArgument, payload: payload, version: version) else { return nil }
        let file = FirstRunFlow.joinTokenFile
        let store = "sudo sh -c 'umask 077; cat > \(file)'"
        var lines = ["set -e"]
        if payload == nil {
            // The download lands beside this script, in its own private directory.
            lines.append(#"cd "$(dirname "$0")""#)
        }
        for command in parts.fetch {
            lines += [echo("Running: " + command), command]
        }
        lines += [
            "trap 'stty echo 2>/dev/null; sudo -n rm -f \(file) 2>/dev/null' EXIT",
            echo(tokenPrompt),
            "stty -echo",
            "IFS= read -r token",
            "stty echo",
            "echo",
            echo("Running: " + store),
            #"printf '%s\n' "$token" | "# + store,
            "token=",
            echo("Running: " + parts.install),
            parts.install,
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

    private static func joinParts(serverArgument: String?, payload: Payload?, version: SemanticVersion?)
        -> (fetch: [String], install: String)? {
        guard let host = serverArgument, !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.utf8.allSatisfy(JoinCommandParser.isAddressByte),
              !host.contains("["), !host.contains("]") else { return nil }
        let agent = "install --agent --server \(host) --token-file \(FirstRunFlow.joinTokenFile)"
        if let payload {
            return ([], "sudo \(payload.quotedCLI) \(agent)")
        }
        let version = GuidedSteps.releasePin(version)
        let pin = version.map { "K3SM_INSTALL_VERSION=v\($0) " } ?? ""
        let archive = version.map { "k3sm_\($0)_darwin_arm64.tar.gz" } ?? "k3sm_*_darwin_arm64.tar.gz"
        return ([
            "curl -fsSL \(GuidedSteps.installScriptURL) | \(pin)K3SM_INSTALL_DOWNLOAD_ONLY=1 sh",
            "tar -xzf \(archive)",
        ], "sudo ./k3sm \(agent)")
    }

    /// `echo` of fixed text as one single-quoted word.
    static func echo(_ text: String) -> String {
        "echo '" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func render(_ lines: [String]) -> String {
        "#!/bin/sh\n" + lines.joined(separator: "\n") + "\n"
    }
}
