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

/// CopyJoinCommand is the server menu's Copy Join Command: its visibility
/// and enablement from the live status, and the words around it.
public enum CopyJoinCommand {
    /// The menu title.
    public static let title = "Copy Join Command…"

    /// The note under the menu item.
    public static var menuNote: String {
        "A fresh token, expires in \(JoinTokenMint.ttlMinutes) minutes. Copied concealed, this Mac only, cleared after \(Int(ConcealedClipboard.lifetime)) s."
    }

    /// The first sentence about the token's lifetime.
    public static var lifetimeNote: String {
        "The token in it expires in \(JoinTokenMint.ttlMinutes) minutes."
    }

    /// The result note after a copy: what was copied, how it is held, and
    /// where the token can still end up.
    public static var copiedNote: String {
        "Paste it into Terminal on the Mac that should join. " + lifetimeNote
            + " It was copied as a concealed item that stays on this Mac and is cleared after "
            + "\(Int(ConcealedClipboard.lifetime)) seconds, though some clipboard managers may still keep it."
            + " The pasted command leaves the token in that Mac's shell history until it expires."
            + " If k3sm quits unexpectedly before the 60 seconds are up, the item stays until k3sm next starts or something else is copied."
    }

    /// State is what the menu shows for the item.
    public enum State: Equatable, Sendable {
        /// Not a server (or no report): no item.
        case hidden
        /// Shown but disabled; the tooltip carries the reason.
        case disabled(String)
        /// Enabled; the copied command names this address.
        case enabled(ServerAddress)
    }

    /// Decides the item from a status report: shown only on a server; enabled
    /// only when the server's node daemon runs, privileged actions are
    /// available, no other change is running, and exactly one join address
    /// resolves. The first failing check names the reason.
    public static func evaluate(
        report: StatusReport?, availability: PrivilegedAvailability, busy: Bool, addresses: JoinAddressResolution
    ) -> State {
        guard let report, NodeRole.detect(in: report) == .server else { return .hidden }
        if busy {
            return .disabled("Another change is running.")
        }
        if case .disabled(let reason) = availability {
            return .disabled(reason)
        }
        guard report.nodeDaemonRunning else {
            return .disabled("k3sm is not running on this Mac, so it cannot create a join token.")
        }
        guard case .one(let server) = addresses else {
            return .disabled(addresses.disabledReason ?? "No join address.")
        }
        return .enabled(server)
    }
}

/// JoinCommandDriver runs one Copy Join Command from click to pasteboard:
/// a live status read and a fresh check (a Mac that is no longer a running
/// server refuses before any prompt), a fresh join address, the
/// administrator prompt that mints a new token, the grammar check, then the
/// concealed write. Nothing is cached between clicks. The token lives only
/// in this function's locals: it is never logged, never in a result, and
/// the reference is dropped when `perform` returns.
///
/// The driver is single-flight: `perform` claims it synchronously on the
/// main actor before its first suspension, and a call that finds it claimed
/// is busy, which `CopyJoinCommand.evaluate` turns into a refusal before any
/// prompt. Two rapid clicks therefore mint once.
@MainActor
public final class JoinCommandDriver {
    public enum Result: Equatable, Sendable {
        /// Refused before any prompt; the sentence says why.
        case refused(String)
        /// The user dismissed the administrator prompt.
        case cancelled
        /// The mint or the copy failed; the sentence says why. Nothing was copied.
        case failed(String)
        /// The command is on the pasteboard; the sentence is the result note.
        case copied(String)
    }

    let teamID: TeamID
    let readStatus: @MainActor @Sendable () async -> StatusReport?
    let availability: @MainActor @Sendable () -> PrivilegedAvailability
    let addresses: any JoinAddressSource
    let runner: any PrivilegedRunner
    let clipboard: ConcealedClipboard
    let log: @MainActor @Sendable (String) -> Void
    /// Whether a copy is in flight (claimed, not yet finished).
    public private(set) var inFlight = false

    public init(
        teamID: TeamID,
        readStatus: @escaping @MainActor @Sendable () async -> StatusReport?,
        availability: @escaping @MainActor @Sendable () -> PrivilegedAvailability,
        addresses: any JoinAddressSource,
        runner: any PrivilegedRunner,
        clipboard: ConcealedClipboard,
        log: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.teamID = teamID
        self.readStatus = readStatus
        self.availability = availability
        self.addresses = addresses
        self.runner = runner
        self.clipboard = clipboard
        self.log = log
    }

    /// The sentence for output that is not a join token.
    public static let notAToken = "k3sm did not print a join token, so nothing was copied."

    public func perform() async -> Result {
        // Claim before the first await, so a second call sees it.
        let busy = inFlight
        if !busy { inFlight = true }
        defer { if !busy { inFlight = false } }
        let live = await readStatus()
        let state = CopyJoinCommand.evaluate(
            report: live, availability: availability(), busy: busy, addresses: JoinAddress.resolve(addresses))
        let server: ServerAddress
        switch state {
        case .hidden:
            log("join command: refused, not a server")
            return .refused("This Mac is not running a k3sm server now, so it cannot create a join token. Nothing was copied.")
        case .disabled(let why):
            log("join command: refused before the prompt")
            return .refused(why + " Nothing was copied.")
        case .enabled(let s):
            server = s
        }
        log("join command: minting")
        switch await runner.runAsRootCapturingOutput(JoinTokenMint.render(.workerToken, teamID: teamID)) {
        case .failure(.notSucceeded(let run)):
            log("join command: mint did not succeed")
            if run.outcome == .cancelled { return .cancelled }
            return .failed(Self.failureText(run))
        case .failure(.outputRefused):
            log("join command: mint output refused")
            return .failed(Self.notAToken)
        case .failure(.notCapturable), .failure(.secretNotRunnable):
            log("join command: mint script refused by the runner")
            return .failed(Self.failureText(PrivilegedRun(outcome: .couldNotStart)))
        case .success(let output):
            guard let token = JoinToken(output: output),
                  let text = JoinCommandText.render(token: token, server: server)
            else {
                log("join command: mint output refused")
                return .failed(Self.notAToken)
            }
            clipboard.copy(text)
            log("join command: copied")
            return .copied("The join command for \(server.argument) is copied. " + CopyJoinCommand.copiedNote)
        }
    }

    /// One sentence for a mint that did not exit 0. The CLI's own error text
    /// is cleaned, truncated and has anything token-shaped removed.
    static func failureText(_ run: PrivilegedRun) -> String {
        var text: String
        switch run.outcome {
        case .succeeded, .cancelled:
            text = "Nothing was copied."
        case .couldNotStart:
            text = "The administrator prompt could not be shown. Nothing was copied."
        case .failed(let status):
            switch status {
            case LifecycleExit.refusedBinary:
                text = "The installed k3sm at \(K3smCLI.path), or a folder above it, is not owned by root or is writable by others, so nothing was run."
            case LifecycleExit.signatureRejected:
                text = "The installed k3sm is not signed by the k3sm Developer ID, so nothing was run."
            default:
                text = "k3sm could not create a join token (exit status \(status)). Nothing was copied."
            }
        }
        if case .failed = run.outcome {
            let said = StatusDisplay.errorText(JoinToken.redact(run.errorOutput ?? ""))
            if !said.isEmpty {
                text += " k3sm said: " + said
            }
        }
        return text
    }
}

/// JoinCommandText renders the command the server's Copy Join Command puts on
/// the pasteboard: the documented two-step join (`docs/user/multi-node.md`)
/// as one line to paste into Terminal on the joining Mac. The token goes into
/// a root-only file through stdin, then the agent install reads that file.
public enum JoinCommandText {
    /// The root-only file the documented join puts the token in.
    public static let tokenFile = "/var/root/k3sm-join-token"

    /// The documented first step, which stores the token from stdin.
    public static let storeStep = "sudo sh -c 'umask 077; cat > \(tokenFile)'"

    /// The install argv after `k3sm`; `server` is the bare host (the CLI
    /// adds the join port).
    public static func installArguments(server: String) -> [String] {
        ["install", "--agent", "--server", server, "--token-file", tokenFile]
    }

    /// Reports whether `text` is exactly a line this app copies: a token
    /// that passes the grammar and an IPv4 server, in the `render` form.
    /// The launch-time sweep clears only such a line.
    public static func isJoinCommand(_ text: String) -> Bool {
        let head = "printf '%s' '"
        let middle = "' | \(storeStep) && sudo k3sm install --agent --server "
        let tail = " --token-file \(tokenFile)"
        guard text.hasPrefix(head), text.hasSuffix(tail) else { return false }
        let body = text.dropFirst(head.count).dropLast(tail.count)
        guard let m = body.range(of: middle) else { return false }
        guard let token = JoinToken(validating: String(body[..<m.lowerBound])),
              let server = try? ServerAddress(parsing: String(body[m.upperBound...])),
              case .ipv4 = server.host
        else { return false }
        return render(token: token, server: server) == text
    }

    /// The copied line, or nil for a server that is not an IPv4 address (the
    /// join address source yields only those). The token is one shell word.
    public static func render(token: JoinToken, server: ServerAddress) -> String? {
        guard case .ipv4(let host) = server.host else { return nil }
        return "printf '%s' \(ShellQuote.quote(token.value)) | \(storeStep)"
            + " && sudo k3sm " + installArguments(server: host).joined(separator: " ")
    }
}
