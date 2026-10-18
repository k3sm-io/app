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

/// StatusStreamPolicy is the status stream's contract with the k3sm CLI, one
/// place for each word and number it reads.
public enum StatusStreamPolicy {
    /// The one-shot report's `capabilities` word that says the stream is there.
    public static let capability = "watch-json"
    /// The stream's exit when the apiserver refused the credential.
    public static let authExitStatus: Int32 = 7
    /// A `closing` frame from a process younger than this is not a rotation
    /// (the CLI's lifetime is about 30 minutes) but an end like any other:
    /// it backs off, so a stream that closes at once cannot spin.
    public static let shortestRotation: Duration = WatchPolicy.healthyLifetime
}

/// StatusStreamCode is an `error` frame's `code` this build acts on.
public enum StatusStreamCode: String, Equatable, Sendable {
    /// The apiserver refused the credential; the CLI exits 7 right after.
    case authRefused = "auth-refused"
    /// The node and Pod watch cannot reach the apiserver; reports keep coming.
    case apiserverUnreachable = "apiserver-unreachable"
    /// The credential may not list or watch nodes or Pods; reports keep coming.
    case watchForbidden = "watch-forbidden"
    /// There is no kubeconfig to watch with; reports keep coming.
    case noCredentials = "no-credentials"
    /// A report did not fit in a line; the app reads it once by itself.
    case frameTooLarge = "frame-too-large"
}

/// StatusFrame is one line of `k3sm status --watch -o json` read.
public enum StatusFrame: Equatable, Sendable {
    /// A full report, decoded by `StatusReport.decode`.
    case report(StatusReport)
    /// An error frame with a code this build knows; `message` is the CLI's
    /// sentence for a person, untrusted, passed through `StatusDisplay.errorText`.
    case error(StatusStreamCode, message: String)
    /// The stream reached its lifetime and is about to exit 0.
    case closing
    /// A frame of a kind or code this build does not know, or a line that is
    /// not a frame at all: ignored, as the contract asks.
    case ignored
    /// A report frame whose report this build cannot read (not a report, or
    /// another schema version).
    case unreadableReport

    private struct Head: Decodable {
        let kind: String?
        let code: String?
        let message: String?
    }

    private struct Envelope: Decodable {
        let report: StatusReport
    }

    /// Reads one line.
    public static func parse(_ line: Data) -> StatusFrame {
        guard let head = try? JSONDecoder().decode(Head.self, from: line) else { return .ignored }
        switch head.kind {
        case "report":
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
                  envelope.report.schemaVersion == StatusReport.supportedSchemaVersion else {
                return .unreadableReport
            }
            return .report(envelope.report)
        case "error":
            guard let code = head.code.flatMap(StatusStreamCode.init(rawValue:)) else { return .ignored }
            return .error(code, message: StatusDisplay.errorText(head.message ?? ""))
        case "closing":
            return .closing
        default:
            return .ignored
        }
    }
}

/// StatusStreamState is the status stream as the app sees it.
public enum StatusStreamState: Equatable, Sendable {
    /// Not started, or stopped.
    case idle
    /// Started, waiting for the first one-shot report to say whether the
    /// installed k3sm offers the stream.
    case detecting
    /// The installed k3sm does not offer it: the timed reads stay, for the
    /// rest of the app's run (the permanent degraded profile).
    case unsupported
    /// A process is held and no report has come from this start yet.
    case connecting
    /// Reports are coming: the timed report reads stand down.
    case live
    /// The process ended without a `closing` frame; a new one waits on its
    /// backoff and the timed reads stand in until it sends a report.
    case retrying
    /// A report this build cannot read: the timed reads stand in until the
    /// next start, since the same binary would print the same frame again.
    case degraded
    /// The apiserver refused the credential (an `auth-refused` frame, or
    /// exit 7): never retried; the timed reads stand in. The text is the
    /// CLI's sentence through `StatusDisplay.errorText`.
    case authFailed(String)
}

/// StatusStream holds the one `k3sm status --watch -o json` the app runs,
/// when the installed k3sm offers it, and hands each report frame to the
/// status item and the window. The capability is read once per app run,
/// from the first one-shot report that decodes (`noteCapabilities`): a k3sm
/// without `watch-json` never gets a stream, and the timed reads it already
/// has are its permanent profile. While the stream is `live`, the console's
/// report trigger stands down (`replacesTimedReads`).
///
/// A `closing` frame is the CLI's bounded lifetime (about 30 minutes): a new
/// process is started at once, with no backoff, and the stream stays live. An
/// exit without one is a crash or a kill: it backs off (full jitter under a
/// ceiling of 1 s doubling to 60 s, `WatchPolicy.retryWait`; a process that
/// lived 30 s resets it) and the timed reads stand in until a new process
/// sends a report. `auth-refused` and exit 7 are `authFailed`, never retried,
/// until a later one-shot report shows the `kubeconfig` row `ok` after it
/// was `refused` (`noteCredential`). `apiserver-unreachable`,
/// `watch-forbidden` and `no-credentials` keep the stream (the CLI keeps
/// collecting every 30 s) and set `problem`, cleared when a new process
/// starts. `frame-too-large` asks for one one-shot read (`onOneShot`). A
/// frame of a kind or code this build does not know is ignored. Processes and
/// time are seams (`WatchLauncher`, `WatchClock`), as for `WatchStream`, whose
/// framer (`CLIStream`'s `WatchLineFramer`, 2 MiB a line), backoff and
/// jitter it reuses.
@MainActor
public final class StatusStream {
    public private(set) var state: StatusStreamState = .idle {
        didSet { if state != oldValue { onState?() } }
    }
    /// Whether the installed k3sm offers the stream; nil until a one-shot
    /// report decoded.
    public private(set) var capable: Bool?
    /// The last error code that leaves the stream running, until a new
    /// process starts.
    public private(set) var problem: StatusStreamCode? {
        didSet { if problem != oldValue { onState?() } }
    }
    /// Called with each report frame.
    public var onReport: (@MainActor (StatusReport) -> Void)?
    /// Called when a report did not fit in a frame: read one by itself.
    public var onOneShot: (@MainActor () -> Void)?
    /// Called after `state` or `problem` changes.
    public var onState: (@MainActor () -> Void)?

    private let launcher: any WatchLauncher
    private let clock: any WatchClock
    private let jitter: @MainActor () -> Double

    private struct Generation {
        let id: Int
        let process: any WatchProcess
        let startedAt: Duration
    }

    private var wanted = false
    private var current: Generation?
    private var nextID = 0
    private var failures = 0
    private var backoffTimer: (any WatchTimer)?
    private var credential: WatchCredential = .unknown

    public init(launcher: any WatchLauncher, clock: any WatchClock,
                jitter: @escaping @MainActor () -> Double = { PollJitter.draw() }) {
        self.launcher = launcher
        self.clock = clock
        self.jitter = jitter
    }

    /// Whether the console's timed report reads stand down: only while
    /// reports are coming. A rotation keeps it; a crash, an auth failure or
    /// a degradation gives the reads back.
    public var replacesTimedReads: Bool { state == .live }

    /// Whether the console's report trigger (`ReportTrigger`, the record
    /// watches and their timer) runs: while the console is on screen and the
    /// stream does not replace it.
    public static func reportTriggerRuns(consoleShown: Bool, stream: StatusStreamState) -> Bool {
        consoleShown && stream != .live
    }

    /// The line the status view shows under the report while the stream
    /// has something to say; nil otherwise.
    public var line: String? {
        switch state {
        case .authFailed(let text):
            return WatchAuth.refusedLine(text)
        case .live, .connecting:
            return problem.flatMap(Self.problemLine)
        case .idle, .detecting, .unsupported, .retrying, .degraded:
            return nil
        }
    }

    /// The line for a code that leaves the stream running.
    public static func problemLine(_ code: StatusStreamCode) -> String? {
        switch code {
        case .apiserverUnreachable:
            return "Live status cannot reach the API server; it re-checks every 30 seconds (apiserver-unreachable)."
        case .watchForbidden:
            return "Live status may not watch nodes or pods; it re-checks every 30 seconds (watch-forbidden)."
        case .noCredentials:
            return "Live status has no kubeconfig to watch with; it re-checks every 30 seconds (no-credentials)."
        case .authRefused, .frameTooLarge:
            return nil
        }
    }

    /// Wants the stream: it starts at once when the installed k3sm is known
    /// to offer it, waits for `noteCapabilities` while that is unknown, and
    /// stays `unsupported` otherwise. A stream already wanted is left alone;
    /// one stopped by an auth failure or a degradation is tried again.
    public func start() {
        if wanted, state != .degraded, !isAuthFailed { return }
        wanted = true
        failures = 0
        switch capable {
        case nil: state = .detecting
        case .some(false): state = .unsupported
        case .some(true):
            state = .connecting
            spawn()
        }
    }

    /// Stops the stream: the process is killed and the retry cancelled. The
    /// capability is kept.
    public func stop() {
        wanted = false
        halt()
        problem = nil
        state = .idle
    }

    /// Takes a one-shot report's `capabilities`. Only the first report that
    /// decoded decides, once per app run; a wanted stream starts then.
    public func noteCapabilities(_ report: StatusReport) {
        guard capable == nil else { return }
        let offered = report.capabilities.contains(StatusStreamPolicy.capability)
        capable = offered
        guard wanted, state == .detecting else { return }
        if offered {
            state = .connecting
            spawn()
        } else {
            state = .unsupported
        }
    }

    /// Takes the latest one-shot report's word on the kubeconfig: a stream
    /// stopped by a refusal starts again once a report shows the row `ok`
    /// after showing it `refused`.
    public func noteCredential(_ next: WatchCredential) {
        let previous = credential
        credential = next
        guard case .refused = previous, next == .accepted, isAuthFailed, wanted else { return }
        state = .connecting
        failures = 0
        spawn()
    }

    /// After a system wake: a held process is replaced once, since its
    /// connection may be half-open after sleep.
    public func wake() {
        switch state {
        case .connecting, .live, .retrying:
            failures = 0
            spawn()
        case .idle, .detecting, .unsupported, .degraded, .authFailed:
            break
        }
    }

    private var isAuthFailed: Bool {
        if case .authFailed = state { return true }
        return false
    }

    // MARK: processes

    private func spawn() {
        killCurrent()
        backoffTimer?.cancel()
        backoffTimer = nil
        problem = nil
        nextID += 1
        let id = nextID
        let events = WatchEvents(
            lines: { [weak self] lines in self?.received(lines, generation: id) },
            // Standard error decides nothing: every outcome is a frame or the
            // exit status.
            errors: { _ in },
            exit: { [weak self] exit in self?.exited(exit, generation: id) })
        let process = launcher.launch(arguments: K3smCLI.statusStreamArguments, events: events)
        current = Generation(id: id, process: process, startedAt: clock.now)
    }

    private func killCurrent() {
        current?.process.kill()
        current = nil
    }

    private func halt() {
        killCurrent()
        backoffTimer?.cancel()
        backoffTimer = nil
    }

    // MARK: input

    private func received(_ lines: [Data], generation: Int) {
        for line in lines {
            guard current?.id == generation else { return }
            frame(StatusFrame.parse(line), generation: generation)
        }
    }

    private func frame(_ frame: StatusFrame, generation: Int) {
        switch frame {
        case .report(let report):
            backoffTimer?.cancel()
            backoffTimer = nil
            state = .live
            onReport?(report)
        case .error(.authRefused, let message):
            refuse(message)
        case .error(.frameTooLarge, _):
            onOneShot?()
        case .error(let code, _):
            problem = code
        case .closing:
            rotate(generation: generation)
        case .ignored:
            break
        case .unreadableReport:
            halt()
            state = .degraded
        }
    }

    private func exited(_ exit: WatchExit, generation: Int) {
        guard current?.id == generation else { return }
        if case .exited(let status, _) = exit, status == StatusStreamPolicy.authExitStatus {
            return refuse("")
        }
        ended(generation: generation)
    }

    /// The CLI's lifetime came: a new process at once, no backoff, still
    /// live. A process that closes too young ends like a crash instead.
    private func rotate(generation: Int) {
        guard let current, current.id == generation else { return }
        guard clock.now - current.startedAt >= StatusStreamPolicy.shortestRotation else {
            return ended(generation: generation)
        }
        failures = 0
        spawn()
    }

    /// The process ended without a rotation: the timed reads stand in, and a
    /// new process starts after the backoff.
    private func ended(generation: Int) {
        guard let current, current.id == generation else { return }
        if clock.now - current.startedAt >= WatchPolicy.healthyLifetime { failures = 0 }
        killCurrent()
        state = .retrying
        let wait = WatchPolicy.retryWait(failures: failures, unit: jitter())
        failures += 1
        backoffTimer?.cancel()
        backoffTimer = clock.schedule(at: clock.now + wait) { [weak self] in
            guard let self else { return }
            self.backoffTimer = nil
            guard self.wanted, self.state == .retrying else { return }
            self.spawn()
        }
    }

    private func refuse(_ message: String) {
        halt()
        state = .authFailed(StatusDisplay.errorText(message))
    }
}
