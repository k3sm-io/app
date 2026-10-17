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

/// PrivilegedOutcome is how one root step ended.
public enum PrivilegedOutcome: Equatable, Sendable {
    /// The script exited 0.
    case succeeded
    /// The user dismissed the administrator prompt.
    case cancelled
    /// The script ran and exited with this status (see `CopyOutExit`).
    case failed(exitStatus: Int32)
    /// The step could not be started at all.
    case couldNotStart
}

/// PrivilegedRunner runs a rendered root step with administrator rights. It
/// is the app's only path to root; the script text always comes from
/// `RootScriptBuilder`, and `input` carries the join token, which never
/// appears in the script or in any argv.
public protocol PrivilegedRunner: Sendable {
    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome
    /// Runs the step like `runAsRoot` and also returns what the step wrote
    /// to standard error when it failed, raw. Callers show it only through
    /// `StatusDisplay.errorText`.
    func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun
}

/// PrivilegedRun is a finished root step and, when it failed, its raw error
/// output (nil when there was none or the runner cannot read it); when it
/// succeeded and its script asked for it (`RootScript.capturesOutput`, the
/// image verbs alone), its raw standard output, cut at `maxOutputBytes`,
/// which a caller reads only through its parser or `StatusDisplay`.
public struct PrivilegedRun: Equatable, Sendable {
    public let outcome: PrivilegedOutcome
    public let errorOutput: String?
    public let output: String?
    /// Whether `output` was cut at `maxOutputBytes`.
    public let outputTruncated: Bool

    /// The most standard output a runner holds for a step.
    public static let maxOutputBytes = 256 * 1024

    public init(outcome: PrivilegedOutcome, errorOutput: String? = nil, output: String? = nil, outputTruncated: Bool = false) {
        self.outcome = outcome
        self.errorOutput = errorOutput
        self.output = output
        self.outputTruncated = outputTruncated
    }

    /// `text` cut to its first `maxOutputBytes` bytes of UTF-8, and whether
    /// it was cut. A scalar split by the cut decodes as a replacement character.
    public static func capped(_ text: String?) -> (text: String?, truncated: Bool) {
        guard let text else { return (nil, false) }
        let bytes = text.utf8
        guard bytes.count > maxOutputBytes else { return (text, false) }
        return (String(decoding: bytes.prefix(maxOutputBytes), as: UTF8.self), true)
    }
}

extension PrivilegedRunner {
    /// A runner that cannot read the error output reports none.
    public func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
        PrivilegedRun(outcome: await runAsRoot(script, input: input))
    }
}

/// PrivilegedAvailability is whether the window enables privileged actions,
/// and if not, the one-line reason it shows.
public enum PrivilegedAvailability: Equatable, Sendable {
    case enabled
    case disabled(reason: String)

    /// Decides availability. Privileged actions need a Team ID to pin, the
    /// app's own signature to satisfy the designated requirement, and a user
    /// in the admin group; the first failing check names the reason.
    public static func evaluate(teamID: TeamID?, signatureValid: Bool, userIsAdmin: Bool) -> PrivilegedAvailability {
        guard teamID != nil else {
            return .disabled(reason: "This build of k3sm is not Developer ID signed, so it cannot install or change k3sm.")
        }
        guard signatureValid else {
            return .disabled(reason: "This copy of k3sm failed its signature check. Download it again.")
        }
        guard userIsAdmin else {
            return .disabled(reason: "Installing or changing k3sm needs an administrator account.")
        }
        return .enabled
    }
}
