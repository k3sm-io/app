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
    /// Runs a step that reads no stdin and returns what it wrote to standard
    /// output when it exited 0, as the runner's in-process result: never a
    /// file, never argv. Only a script that asks for a secret result
    /// (`RootScript.returnsSecret`) is run; any other is refused with
    /// `PrivilegedFailure.notCapturable` before anything runs. The retained
    /// output is bounded (`capturedOutputLimit`); a longer one is dropped.
    /// The bound limits what is kept, not what is received: the runner gets
    /// the whole result string before the check applies. A
    /// failed step returns no standard output at all, only its error output.
    /// The join token mint is the one caller, so the result is a secret:
    /// hold it briefly, never log it. A runner implements it through
    /// `PrivilegedCapture.capture`.
    func runAsRootCapturingOutput(_ script: RootScript) async -> Result<String, PrivilegedFailure>
}

/// The most standard output a capturing run keeps. A join token is about
/// a hundred bytes. It bounds what is retained, not what is received: the
/// runner gets the whole result string before this check drops it.
public let capturedOutputLimit = 4096

/// PrivilegedFailure is why a capturing run returned no output.
public enum PrivilegedFailure: Error, Equatable, Sendable {
    /// The step did not exit 0 (cancelled, could not start, or failed), with
    /// its raw error output when the runner can read it.
    case notSucceeded(PrivilegedRun)
    /// The step exited 0 but its output was missing, not text, or longer than
    /// `capturedOutputLimit`; it was dropped unread.
    case outputRefused
    /// The script does not ask for a secret result
    /// (`RootScript.returnsSecret`), so the capturing call refused it and
    /// nothing ran.
    case notCapturable
    /// The script asks for a secret result (`RootScript.returnsSecret`) but
    /// was handed to a non-capturing entry point, which would discard it, so
    /// it was refused and nothing ran.
    case secretNotRunnable
}

/// PrivilegedCapture decides what a runner keeps of a root step's standard
/// output, so every runner keeps the same and the decision is tested
/// without a prompt. The contract runs both ways: only a `.secret` script
/// may use the capturing call, and a `.secret` script may use only it. A
/// runner receives the output as one whole string (`do shell script`
/// returns it before any cap applies); this is where it is dropped, capped
/// or set aside, so every cap bounds what is retained, not what is received.
public enum PrivilegedCapture {
    /// Why a non-capturing entry point (`runAsRoot`,
    /// `runAsRootReportingError`) must not run `script`, or nil when it may.
    /// A `.secret` script is refused: run there, the mint would create a
    /// token as root and drop it.
    public static func refusal(forRunning script: RootScript) -> PrivilegedFailure? {
        script.returnsSecret ? .secretNotRunnable : nil
    }

    /// The non-capturing run: refuses a `.secret` script before `execute` is
    /// called (the run reports `couldNotStart`, since nothing ran), and
    /// otherwise returns `execute`'s run.
    public static func run(_ script: RootScript, execute: (RootScript) -> PrivilegedRun) -> PrivilegedRun {
        guard refusal(forRunning: script) == nil else { return PrivilegedRun(outcome: .couldNotStart) }
        return execute(script)
    }

    /// A step that exited 0 with standard output `result`: the run, which
    /// carries the output (capped at `PrivilegedRun.maxOutputBytes`, a bound
    /// on what is retained, since `result` already arrived whole) only for a
    /// `.kept` script, and the secret,
    /// which is the raw output only for a `.secret` script. A `.discarded`
    /// script keeps neither.
    public static func succeeded(_ script: RootScript, result: String?) -> (run: PrivilegedRun, secret: String?) {
        switch script.result {
        case .discarded:
            return (PrivilegedRun(outcome: .succeeded), nil)
        case .kept:
            let kept = PrivilegedRun.capped(result)
            return (PrivilegedRun(outcome: .succeeded, output: kept.text, outputTruncated: kept.truncated), nil)
        case .secret:
            return (PrivilegedRun(outcome: .succeeded), result)
        }
    }

    /// The capturing call: refuses a script that does not ask for a secret
    /// result before `execute` is called, then returns the secret only when
    /// the step exited 0 and the secret is at most `capturedOutputLimit`
    /// bytes. The limit bounds what is retained: a longer secret has already
    /// been received whole and is dropped here. `execute` runs the step with
    /// no stdin.
    public static func capture(_ script: RootScript,
                               execute: (RootScript) -> (run: PrivilegedRun, secret: String?)) -> Result<String, PrivilegedFailure> {
        guard script.returnsSecret else { return .failure(.notCapturable) }
        let (run, secret) = execute(script)
        guard run.outcome == .succeeded else { return .failure(.notSucceeded(run)) }
        guard let secret, secret.utf8.count <= capturedOutputLimit else { return .failure(.outputRefused) }
        return .success(secret)
    }
}

/// PrivilegedRun is a finished root step and, when it failed, its raw error
/// output (nil when there was none or the runner cannot read it); when it
/// succeeded and its script asked for it (`RootScript.capturesOutput`, the
/// image verbs alone; never a `.secret` script's), its raw standard output, cut at `maxOutputBytes`,
/// which a caller reads only through its parser or `StatusDisplay`.
public struct PrivilegedRun: Equatable, Sendable {
    public let outcome: PrivilegedOutcome
    public let errorOutput: String?
    public let output: String?
    /// Whether `output` was cut at `maxOutputBytes`.
    public let outputTruncated: Bool

    /// The most standard output a runner holds for a step. It bounds what is
    /// retained, not what is received: the runner gets the whole result
    /// string first and cuts it here.
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
    /// A runner that cannot read the error output reports none. A `.secret`
    /// script is refused before `runAsRoot` is called.
    public func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
        guard PrivilegedCapture.refusal(forRunning: script) == nil else { return PrivilegedRun(outcome: .couldNotStart) }
        return PrivilegedRun(outcome: await runAsRoot(script, input: input))
    }

    /// A runner that cannot capture output runs nothing and returns no
    /// output; a script that does not ask for a secret result is refused as
    /// every runner refuses it.
    public func runAsRootCapturingOutput(_ script: RootScript) async -> Result<String, PrivilegedFailure> {
        PrivilegedCapture.capture(script) { _ in (PrivilegedRun(outcome: .couldNotStart), nil) }
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
