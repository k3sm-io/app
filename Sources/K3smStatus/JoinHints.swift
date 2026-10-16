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

/// JoinHints holds every join command the app shows or suggests. A command
/// is either runnable as written in Terminal (its flags are the ones
/// `k3sm install` declares: `--token-file`, never `--token`) or is text to
/// paste into k3sm.app's Join step, and says so. `joinCommandHintIsRunnable`
/// holds this file and the messages that quote commands to that rule.
public enum JoinHints {
    /// How a suggested command is meant to be used.
    public enum Use: Equatable, Sendable {
        /// Run in Terminal as written.
        case terminal
        /// Paste into the Join step of k3sm.app; not a Terminal command.
        case pasteIntoApp
    }

    /// One suggested command and how to use it.
    public struct Suggestion: Equatable, Sendable {
        public let text: String
        public let use: Use
        /// How the suggestion is labelled when shown; a paste suggestion always carries `pasteLabel`.
        public let label: String
    }

    /// The label every paste-into-the-app suggestion carries.
    public static let pasteLabel = "to paste into this window, not Terminal"

    /// A Terminal join on a Mac without the app, with the token in a file
    /// that only root can read (`k3sm install` has no `--token` flag).
    public static let terminalJoin = "sudo k3sm install --agent --server <host> --token-file <path>"

    /// What to paste into the Join step, with its label.
    public static let pasteExample = "(for example `studio.local K10…`, \(pasteLabel))"

    /// Every command suggestion the app can show.
    public static let suggestions: [Suggestion] = [
        Suggestion(text: terminalJoin, use: .terminal, label: ""),
        Suggestion(text: "sudo k3sm token create", use: .terminal, label: ""),
        Suggestion(text: "studio.local K10…", use: .pasteIntoApp, label: pasteLabel),
    ]

    /// The line above the join field.
    public static let prompt = "On the server Mac, run `sudo k3sm token create`, then paste the server's address and the token it prints here."
}

