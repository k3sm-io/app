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

/// WatchPolicy is the held watch's bounds, one place for each number.
public enum WatchPolicy {
    /// The longest line the framer accepts: 2 MiB, room for any one object.
    public static let maxLineBytes = 2 << 20
    /// The fold's ceiling: past 20,000 objects or 64 MiB the kind goes back
    /// to its list poll.
    public static let maxObjects = 20_000
    public static let maxFoldBytes = 64 << 20
    /// The reconcile: a fresh process replays the whole kind about every
    /// 5 minutes (spread by `PollJitter`) and on any exit of the stream.
    public static let relistInterval: Duration = .seconds(5 * 60)
    /// kubectl's own bound on one watch, spread by `PollJitter`: the relist
    /// normally ends a process long before it.
    public static let requestTimeout: Duration = .seconds(30 * 60)
    /// A replay has settled once no frame came for 250 ms, or 3 s after its
    /// first frame, whichever is first.
    public static let settleQuiet: Duration = .milliseconds(250)
    public static let settleCap: Duration = .seconds(3)
    /// A replay with no frame at all by 5 s settles on the one-shot list
    /// (the kind is empty, or the server slow).
    public static let firstFrameCap: Duration = .seconds(5)
    /// A change is shown at most 250 ms after it arrives, and the list is
    /// redrawn at most twice a second.
    public static let publishDelay: Duration = .milliseconds(250)
    public static let publishGap: Duration = .milliseconds(500)
    /// The wait before a stream that failed is started again: a full-jitter
    /// draw under a ceiling of 1 s doubling to 60 s, never under
    /// `backoffFloor`. A process that lived `healthyLifetime` resets it.
    public static let backoffBase: Duration = .seconds(1)
    public static let backoffMax: Duration = .seconds(60)
    public static let backoffFloor: Duration = .milliseconds(500)
    public static let healthyLifetime: Duration = .seconds(30)
    /// 20 undecodable lines within 10 s degrade the stream.
    public static let undecodableBurst = 20
    public static let undecodableWindow: Duration = .seconds(10)
    /// Two streams' relists are kept at least this far apart.
    public static let relistSpacing: Duration = .seconds(5)
    /// The most of a watch's standard error kept: its last 4 KiB.
    public static let errorTail = 4 << 10
    /// The longest a read waits for a stream's first settle before it falls
    /// back to the list poll.
    public static let settleWait: Duration = .seconds(8)

    /// The doubling ceiling after `failures` failed starts, capped at
    /// `backoffMax`.
    public static func backoff(failures: Int) -> Duration {
        let exponent = min(max(failures, 0), 16)
        return min(backoffBase * (1 << exponent), backoffMax)
    }

    /// The wait before the next start: full jitter, `unit` (0...1, clamped;
    /// not a number is 0) of the ceiling, so streams that failed together
    /// do not return together, and never under `backoffFloor`, so a draw
    /// near zero cannot turn a stream that dies at once into a spin.
    public static func retryWait(failures: Int, unit: Double) -> Duration {
        let ceiling = backoff(failures: failures)
        let clamped = unit.isNaN ? 0 : min(max(unit, 0), 1)
        return min(max(ceiling * clamped, backoffFloor), ceiling)
    }
}

/// WatchExit is how a watch process ended.
public enum WatchExit: Equatable, Sendable {
    /// It exited; `errors` is its standard error's tail, already passed
    /// through `StatusDisplay.errorText`.
    case exited(status: Int32, errors: String)
    /// It could not be started.
    case failedToLaunch
    /// The CLI is not at its absolute path.
    case missing
    /// A line passed `WatchPolicy.maxLineBytes`; the process was killed.
    case lineTooLong
}

/// WatchDegradation is why a stream gave up until it is started again; the
/// kind is read by its list poll meanwhile.
public enum WatchDegradation: Equatable, Sendable {
    case lineTooLong
    case tooLarge
    case undecodable
    case missing
}

/// WatchState is a stream as the readers see it.
public enum WatchState: Equatable, Sendable {
    /// Not started, or stopped.
    case idle
    /// Started, before its first settle: the tab shows its loading state.
    case loading
    /// Settled: `WatchStream.list` is current.
    case live
    /// The process ended, or its replay could not settle, and a new one
    /// waits on its backoff: the list poll stands in until the stream is
    /// re-established.
    case retrying
    /// Given up until the next start: the list poll stands in.
    case degraded(WatchDegradation)
    /// The cluster refused the kubeconfig (a rotated admin token), as an
    /// ERROR event's Status says (401, 403), or as the status report's
    /// `kubeconfig` row says when a watch fails to start: never retried;
    /// the text is the Status message, or the row's remedy, through
    /// `StatusDisplay.errorText`.
    case authFailed(String)
}

/// WatchAuth is the refused-kubeconfig line, and whether a watch's exit
/// text says its resource version is gone. An auth failure is never read
/// from text: it is the ERROR event's Status (`WatchFrame.refused`), or a
/// failed start while the status report's `kubeconfig` row is `refused`
/// (`WatchCredential`).
public enum WatchAuth {
    /// True when the watch ended because its resource version is too old.
    public static func isGone(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("too old resource version") || lower.contains("(gone)") { return true }
        return lower.split { !$0.isLetter && !$0.isNumber }.contains("410")
    }

    /// The text an `authFailed` read from the status report carries: the
    /// `kubeconfig` row's remedy, as "run <remedy>", or "" when it names none.
    public static func remedyText(_ remedy: String) -> String {
        let command = StatusDisplay.clip(remedy)
        return command.isEmpty ? "" : "run " + command
    }

    /// The tab's line while the kubeconfig is refused.
    public static func refusedLine(_ text: String) -> String {
        let detail = StatusDisplay.errorText(text)
        return detail.isEmpty ? "the cluster refused the admin kubeconfig" : "the cluster refused the admin kubeconfig: \(detail)"
    }
}

/// WatchCredential is what the latest full status report says of the
/// kubeconfig the watches run with: its `kubeconfig` row, where k3sm proves
/// the credential with one authenticated request and reports a 401 as
/// `refused`. kubectl exits 1 for every error, so a watch that fails to
/// start names no cause of its own; this row is what tells a refused
/// credential apart. A 403 leaves the row `ok` (the credential
/// authenticated), so it is never read as a refusal here.
public enum WatchCredential: Equatable, Sendable {
    /// The row is `ok`.
    case accepted
    /// The row is `refused`; `remedy` is the row's remedy, as printed
    /// (untrusted: shown only through `WatchAuth.remedyText`).
    case refused(remedy: String)
    /// No report, no row, or any other state: says nothing either way.
    case unknown

    /// The status row that carries it.
    public static let rowName = "kubeconfig"

    /// The credential as `report` says it.
    public static func of(_ report: StatusReport?) -> WatchCredential {
        guard let row = report?.row(named: rowName) else { return .unknown }
        switch row.rowState {
        case .healthy("ok"): return .accepted
        case .reported(RowState.refusedWord): return .refused(remedy: row.remedy)
        default: return .unknown
        }
    }
}

/// WatchProcess is one launched watch: the stream kills it on a relist, a
/// failure or a stop.
@MainActor
public protocol WatchProcess: AnyObject {
    func kill()
}

/// WatchEvents is where a launcher delivers a watch's output, on the main
/// actor, in order: line batches, the standard error's tail as it grows,
/// and, last, the exit.
public struct WatchEvents: Sendable {
    public let lines: @MainActor @Sendable ([Data]) -> Void
    public let errors: @MainActor @Sendable (String) -> Void
    public let exit: @MainActor @Sendable (WatchExit) -> Void

    public init(lines: @escaping @MainActor @Sendable ([Data]) -> Void,
                errors: @escaping @MainActor @Sendable (String) -> Void,
                exit: @escaping @MainActor @Sendable (WatchExit) -> Void) {
        self.lines = lines
        self.errors = errors
        self.exit = exit
    }
}

/// WatchLauncher is the stream's one seam to processes: `CLIStream` in the
/// app, a fake in the tests.
@MainActor
public protocol WatchLauncher: AnyObject {
    /// Starts a held watch with `arguments`.
    func launch(arguments: [String], events: WatchEvents) -> any WatchProcess
    /// Runs a one-shot list; `completion` gets its exit status (nil when it
    /// did not run to an exit) and standard output.
    func list(arguments: [String], completion: @escaping @MainActor @Sendable (Int32?, Data) -> Void)
}

/// WatchChildren is the set of held watch processes the app started and
/// still owns, which `CLIStream.killAll()` ends as the app terminates. It
/// keeps each child's handle (the `Process` and its kill control), never a
/// bare pid: a slot is reserved before the process is launched, the child
/// is recorded once it runs, and the slot is released when the child is
/// reaped. A child reaped before it was recorded (one that exits at once)
/// is never recorded, so no entry outlives its process and a pid the
/// kernel has since handed to another process is never signalled from here.
public final class WatchChildren<Child: AnyObject & Sendable>: @unchecked Sendable {
    public typealias Slot = UInt64

    // Guarded by `lock`.
    private let lock = NSLock()
    private var nextSlot: Slot = 0
    private var reserved: Set<Slot> = []
    private var held: [Slot: Child] = [:]

    public init() {}

    /// A slot for a child about to be launched.
    public func reserve() -> Slot {
        lock.withLock {
            nextSlot += 1
            reserved.insert(nextSlot)
            return nextSlot
        }
    }

    /// Records the launched child, only while its slot is still reserved
    /// (it has not been reaped yet).
    public func launched(_ slot: Slot, child: Child) {
        lock.withLock {
            guard reserved.contains(slot) else { return }
            held[slot] = child
        }
    }

    /// The child was reaped, or never launched: its slot is released.
    public func reaped(_ slot: Slot) {
        lock.withLock {
            reserved.remove(slot)
            held[slot] = nil
        }
    }

    /// The children still held.
    public var count: Int { lock.withLock { held.count } }

    /// Calls `kill` for every child still held, under the lock, so a reap
    /// cannot release a slot halfway through.
    public func killAll(_ kill: (Child) -> Void) {
        lock.withLock {
            for child in held.values { kill(child) }
        }
    }
}

/// WatchTimer is a scheduled callback that can be cancelled.
@MainActor
public protocol WatchTimer: AnyObject {
    func cancel()
}

/// WatchClock is the stream's time: monotonic, as a duration since an
/// origin, so the tests run on a virtual clock.
@MainActor
public protocol WatchClock: AnyObject {
    var now: Duration { get }
    func schedule(at time: Duration, _ fire: @escaping @MainActor () -> Void) -> any WatchTimer
}

/// WatchSystemClock is the app's `WatchClock`: the continuous clock, so a
/// timer due during sleep fires on wake.
@MainActor
public final class WatchSystemClock: WatchClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - origin }

    public func schedule(at time: Duration, _ fire: @escaping @MainActor () -> Void) -> any WatchTimer {
        let deadline = origin + time
        return TaskTimer(Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            fire()
        })
    }

    private final class TaskTimer: WatchTimer {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}

/// WatchRelistSpacer keeps the streams' relists apart: each stream reserves
/// its next relist here, pushed later until it is `relistSpacing` from every
/// other stream's, so two kinds never re-establish in the same tick.
@MainActor
public final class WatchRelistSpacer {
    private var reserved: [ObjectIdentifier: Duration] = [:]
    public let spacing: Duration

    public init(spacing: Duration = WatchPolicy.relistSpacing) {
        self.spacing = spacing
    }

    /// The first time at or after `time` that is `spacing` from every other
    /// owner's reservation, now reserved for `owner`.
    func reserve(_ owner: ObjectIdentifier, at time: Duration) -> Duration {
        reserved[owner] = nil
        var candidate = time
        while let clash = reserved.values.first(where: { abs(($0 - candidate).inSeconds) < spacing.inSeconds }) {
            candidate = clash + spacing
        }
        reserved[owner] = candidate
        return candidate
    }

    func release(_ owner: ObjectIdentifier) {
        reserved[owner] = nil
    }
}

extension Duration {
    /// The duration in seconds, as a double.
    var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// WatchStream holds one kind's kubectl watch while the console is on
/// screen and keeps its list current: the replay of each process is folded
/// into a shadow map that replaces the shown one at once when it settles,
/// later events change the shown map and are published coalesced, and the
/// whole kind is relisted by a fresh process about every 5 minutes and on
/// any exit. A failure backs off (full jitter under 1 s to 60 s); 410 Gone
/// relists at once; an auth failure, an overlong line, an oversized fold or
/// a burst of undecodable lines stops it until the next start, and the
/// readers fall back to the list poll. Every input arrives on the main actor, through
/// `WatchLauncher` and `WatchClock`, so the whole machine runs in tests
/// without a process.
@MainActor
public final class WatchStream {
    public let kind: WatchKind
    public private(set) var state: WatchState = .idle {
        didSet {
            guard state != oldValue else { return }
            if state != .loading { resumeWaiters() }
            onState?()
        }
    }
    /// The shown list (the kind's typed list), once a replay has settled.
    public private(set) var list: Data?
    /// Called after `list` changes.
    public var onPublish: (@MainActor () -> Void)?
    /// Called after `state` changes.
    public var onState: (@MainActor () -> Void)?

    private let launcher: any WatchLauncher
    private let clock: any WatchClock
    private let jitter: @MainActor () -> Double
    private let spacer: WatchRelistSpacer?
    private let maxObjects: Int
    private let maxBytes: Int

    private struct Generation {
        let id: Int
        let process: any WatchProcess
        let startedAt: Duration
        var firstFrameAt: Duration?
        var lastFrameAt: Duration?
        /// The replay's map, until it settles and replaces `shown`.
        var shadow: WatchFold?
        var listing = false
    }

    private var current: Generation?
    private var nextID = 0
    private var shown: WatchFold
    private var failures = 0
    private var lastWasGone = false
    private var undecodable: [Duration] = []
    private var lastPublish: Duration?
    /// The latest full report's word on the kubeconfig (`noteCredential`).
    private var credential: WatchCredential = .unknown

    private var settleTimer: (any WatchTimer)?
    private var firstFrameTimer: (any WatchTimer)?
    private var relistTimer: (any WatchTimer)?
    private var backoffTimer: (any WatchTimer)?
    private var publishTimer: (any WatchTimer)?

    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    public init(kind: WatchKind, launcher: any WatchLauncher, clock: any WatchClock,
                spacer: WatchRelistSpacer? = nil, jitter: @escaping @MainActor () -> Double = { PollJitter.draw() },
                maxObjects: Int = WatchPolicy.maxObjects, maxBytes: Int = WatchPolicy.maxFoldBytes) {
        self.kind = kind
        self.launcher = launcher
        self.clock = clock
        self.spacer = spacer
        self.jitter = jitter
        self.maxObjects = maxObjects
        self.maxBytes = maxBytes
        shown = WatchFold(maxObjects: maxObjects, maxBytes: maxBytes)
    }

    /// Whether the stream holds or is re-establishing a process.
    public var running: Bool {
        switch state {
        case .loading, .live, .retrying: return true
        case .idle, .degraded, .authFailed: return false
        }
    }

    /// The list when the stream is live; nil otherwise (the caller polls).
    public var liveList: Data? { state == .live ? list : nil }

    /// Starts the stream; a second start is a no-op. A degraded or refused
    /// stream is tried again from scratch.
    public func start() {
        guard !running else { return }
        failures = 0
        lastWasGone = false
        undecodable = []
        // Loading until this start's first settle, even with a list kept
        // from an earlier start: the reads wait for it instead of polling.
        state = .loading
        spawn()
    }

    /// Stops the stream: the process is killed and every timer cancelled.
    /// The shown list is kept for the next start.
    public func stop() {
        halt()
        state = .idle
    }

    /// After a system wake: a running stream is restarted exactly once,
    /// since its connection may be half-open after sleep.
    public func wake() {
        guard running else { return }
        backoffTimer?.cancel()
        backoffTimer = nil
        killCurrent()
        failures = 0
        spawn()
    }

    /// Takes the latest full status report's word on the kubeconfig. While
    /// it is `refused`, a watch that fails to start is an auth failure
    /// (`authFailed`, not retried) rather than a backed-off failure; when a
    /// later report shows the row `ok` again, a stream stopped by a refusal
    /// is started again.
    public func noteCredential(_ next: WatchCredential) {
        let previous = credential
        credential = next
        guard case .refused = previous, next == .accepted, case .authFailed = state else { return }
        start()
    }

    /// The list a tab read uses: after the first settle (or
    /// `WatchPolicy.settleWait`), the live list, or nil when the stream is
    /// not live and the read falls back to its list poll.
    public func currentList() async -> Data? {
        await waitForSettle()
        return liveList
    }

    /// Waits until the stream is no longer loading, or `WatchPolicy.settleWait`.
    public func waitForSettle() async {
        guard state == .loading else { return }
        let id = nextWaiter
        nextWaiter += 1
        let timer = clock.schedule(at: clock.now + WatchPolicy.settleWait) { [weak self] in self?.resume(id) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if state == .loading {
                    waiters[id] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
        timer.cancel()
    }

    // MARK: processes

    private func spawn() {
        nextID += 1
        let id = nextID
        let timeout = PollJitter.spread(WatchPolicy.requestTimeout, unit: jitter())
        // A fresh generation supersedes any retry still waiting.
        backoffTimer?.cancel()
        backoffTimer = nil
        let events = WatchEvents(
            lines: { [weak self] lines in self?.received(lines, generation: id) },
            // Standard error is not read for a decision while the process
            // runs: an auth failure is the ERROR event's Status, never text.
            errors: { _ in },
            exit: { [weak self] exit in self?.exited(exit, generation: id) })
        let process = launcher.launch(arguments: K3smCLI.watchArguments(kind: kind, requestTimeout: timeout), events: events)
        current = Generation(id: id, process: process, startedAt: clock.now,
                             shadow: WatchFold(maxObjects: maxObjects, maxBytes: maxBytes))
        firstFrameTimer = clock.schedule(at: clock.now + WatchPolicy.firstFrameCap) { [weak self] in
            self?.noFirstFrame(generation: id)
        }
    }

    private func killCurrent() {
        settleTimer?.cancel()
        settleTimer = nil
        firstFrameTimer?.cancel()
        firstFrameTimer = nil
        current?.process.kill()
        current = nil
    }

    private func halt() {
        killCurrent()
        for timer in [relistTimer, backoffTimer, publishTimer] { timer?.cancel() }
        relistTimer = nil
        backoffTimer = nil
        publishTimer = nil
        spacer?.release(ObjectIdentifier(self))
    }

    // MARK: input

    private func received(_ lines: [Data], generation: Int) {
        for line in lines {
            guard current?.id == generation else { return }
            frame(WatchFrame.parse(line, kind: kind))
        }
    }

    private func frame(_ frame: WatchFrame) {
        guard let id = current?.id else { return }
        switch frame {
        case .upsert, .delete:
            // The fold is changed in place (`current?.shadow?`), never
            // through a copy, so a replay costs one write per object.
            if current?.shadow != nil {
                if current?.shadow?.apply(frame) == .overCap { return degrade(.tooLarge) }
                let now = clock.now
                if current?.firstFrameAt == nil {
                    current?.firstFrameAt = now
                    firstFrameTimer?.cancel()
                    firstFrameTimer = nil
                }
                current?.lastFrameAt = now
                if settleTimer == nil { scheduleSettle(generation: id) }
            } else {
                switch shown.apply(frame) {
                case .overCap: degrade(.tooLarge)
                case .changed: schedulePublish()
                case .unchanged: break
                }
            }
        case .ignored:
            break
        case .gone:
            ended(gone: true, generation: id)
        case .refused(let message):
            refuse(message)
        case .failure:
            ended(gone: false, generation: id)
        case .undecodable:
            let now = clock.now
            undecodable = undecodable.filter { now - $0 < WatchPolicy.undecodableWindow } + [now]
            if undecodable.count >= WatchPolicy.undecodableBurst { degrade(.undecodable) }
        }
    }

    private func exited(_ exit: WatchExit, generation: Int) {
        guard current?.id == generation else { return }
        switch exit {
        case .missing:
            degrade(.missing)
        case .lineTooLong:
            degrade(.lineTooLong)
        case .failedToLaunch:
            ended(gone: false, generation: generation)
        case .exited(let status, let errors):
            // kubectl exits 1 for every error, a refused credential at
            // connect included, so neither the exit status nor the text
            // names an auth failure. A failed start (a nonzero exit before
            // any frame) while the status report's `kubeconfig` row is
            // `refused` is one; any other exit is an ordinary end, backed
            // off unless the process was healthy.
            if status != 0, current?.firstFrameAt == nil, case .refused(let remedy) = credential {
                return refuse(WatchAuth.remedyText(remedy))
            }
            ended(gone: WatchAuth.isGone(errors), generation: generation)
        }
    }

    // MARK: settling

    /// When the replay settles: 250 ms after its last frame, or the cap
    /// after its first, whichever is first.
    private func settleDue() -> Duration? {
        guard let first = current?.firstFrameAt, let last = current?.lastFrameAt else { return nil }
        return min(last + WatchPolicy.settleQuiet, first + WatchPolicy.settleCap)
    }

    /// One settle timer per replay, moved on when frames kept coming.
    private func scheduleSettle(generation id: Int) {
        guard let due = settleDue() else { return }
        settleTimer = clock.schedule(at: due) { [weak self] in self?.settle(generation: id) }
    }

    private func settle(generation id: Int) {
        guard current?.id == id, current?.shadow != nil, let due = settleDue() else { return }
        settleTimer = nil
        if clock.now < due { return scheduleSettle(generation: id) }
        guard let shadow = current?.shadow else { return }
        current?.shadow = nil
        swap(in: shadow)
    }

    /// A replay with no frame by `firstFrameCap`: the one-shot list decides
    /// (an empty kind settles empty). A failed list leaves the watch running
    /// and arms a retry, so a watch that never settles is replaced after its
    /// backoff rather than left `retrying` with nothing scheduled; a frame
    /// that settles it first cancels the retry.
    private func noFirstFrame(generation id: Int) {
        guard current?.id == id, current?.shadow != nil, current?.firstFrameAt == nil,
              current?.listing == false else { return }
        firstFrameTimer = nil
        current?.listing = true
        let kind = kind
        let maxObjects = maxObjects
        let maxBytes = maxBytes
        launcher.list(arguments: kind.listArguments) { [weak self] status, data in
            guard let self, self.current?.id == id, self.current?.shadow != nil,
                  self.current?.firstFrameAt == nil else { return }
            guard status == 0, let fold = WatchFold.fromList(data, kind: kind, maxObjects: maxObjects, maxBytes: maxBytes) else {
                // The watch keeps running; the reads poll until it settles.
                if self.state == .loading { self.state = .retrying }
                self.scheduleRetry()
                return
            }
            self.current?.shadow = nil
            self.swap(in: fold)
        }
    }

    private func swap(in fold: WatchFold) {
        // Settled: a retry armed while the replay was stuck is not needed.
        backoffTimer?.cancel()
        backoffTimer = nil
        shown = fold
        lastWasGone = false
        publishTimer?.cancel()
        publishTimer = nil
        publish()
        state = .live
        scheduleRelist()
    }

    private func scheduleRelist() {
        relistTimer?.cancel()
        var at = clock.now + PollJitter.spread(WatchPolicy.relistInterval, unit: jitter())
        if let spacer { at = spacer.reserve(ObjectIdentifier(self), at: at) }
        relistTimer = clock.schedule(at: at) { [weak self] in self?.relist() }
    }

    /// The reconcile: the process that has lived through a relist interval
    /// is healthy, so the backoff resets; a fresh one replays the kind into a
    /// shadow map while the shown list stays on screen.
    private func relist() {
        relistTimer = nil
        guard running else { return }
        failures = 0
        killCurrent()
        spawn()
    }

    // MARK: publishing

    private func schedulePublish() {
        guard publishTimer == nil else { return }
        let now = clock.now
        var at = now + WatchPolicy.publishDelay
        if let lastPublish { at = max(at, lastPublish + WatchPolicy.publishGap) }
        publishTimer = clock.schedule(at: at) { [weak self] in
            self?.publishTimer = nil
            self?.publish()
        }
    }

    private func publish() {
        list = shown.list(kind: kind)
        lastPublish = clock.now
        onPublish?()
    }

    // MARK: endings

    /// The process ended (or was ended for a Gone or an error frame): a
    /// process that lived `healthyLifetime`, or a first Gone, is replaced at
    /// once; anything else waits its backoff, so a stream that dies at once
    /// is started a bounded number of times.
    private func ended(gone: Bool, generation id: Int) {
        guard let generation = current, generation.id == id else { return }
        let lived = clock.now - generation.startedAt
        killCurrent()
        if lived >= WatchPolicy.healthyLifetime {
            failures = 0
            lastWasGone = false
            return spawn()
        }
        if gone && !lastWasGone {
            lastWasGone = true
            return spawn()
        }
        lastWasGone = gone
        state = .retrying
        scheduleRetry()
    }

    /// Arms the one retry: after `WatchPolicy.retryWait`, the process still
    /// held (a replay that never settled) is killed and a fresh one started.
    /// A retry already waiting is kept, never doubled; `spawn` and a settle
    /// cancel it, so when it fires nothing better has happened since.
    private func scheduleRetry() {
        guard backoffTimer == nil else { return }
        let wait = WatchPolicy.retryWait(failures: failures, unit: jitter())
        failures += 1
        backoffTimer = clock.schedule(at: clock.now + wait) { [weak self] in
            guard let self else { return }
            self.backoffTimer = nil
            guard self.running else { return }
            self.killCurrent()
            self.spawn()
        }
    }

    // After a degradation the stream stays stopped until the next `start`
    // (the window or tab opening again); after an auth failure it also
    // restarts when a later full report shows the kubeconfig row `ok` again
    // (`noteCredential`). Meanwhile the tab's list poll keeps it current. A
    // refused credential, or an object the framer or fold cannot hold, gets
    // no retry loop.
    private func degrade(_ why: WatchDegradation) {
        halt()
        state = .degraded(why)
    }

    private func refuse(_ text: String) {
        halt()
        state = .authFailed(StatusDisplay.errorText(text))
    }

    private func resume(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func resumeWaiters() {
        let all = waiters
        waiters = [:]
        for continuation in all.values { continuation.resume() }
    }
}

/// WatchRead is how a tab read treats its stream's state when it falls back
/// to the list poll: while the kubeconfig is refused, a failed poll says so
/// rather than showing kubectl's exit status.
public enum WatchRead {
    /// A tab read over a stream: the stream's list, decoded, while it is
    /// live (no process is run); the list poll otherwise, through `fallback`.
    public static func read<Value>(
        stream: WatchStream, decode: @Sendable (Data) -> TabResult<Value>,
        poll: @Sendable () async -> TabResult<Value>
    ) async -> TabResult<Value> {
        if let list = await stream.currentList() { return decode(list) }
        let result = await poll()
        return fallback(result, state: await stream.state)
    }

    public static func fallback<Value>(_ result: TabResult<Value>, state: WatchState) -> TabResult<Value> {
        guard case .authFailed(let text) = state, case .failed = result else { return result }
        return .failed(WatchAuth.refusedLine(text))
    }
}
