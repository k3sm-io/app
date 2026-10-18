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

/// RecordWatchPolicy is what the console's report read watches, and how a
/// burst of changes is folded into one read. The numbers are the held
/// watch's (`WatchPolicy`): a read follows a change once 250 ms pass with no
/// other, or 3 s after the burst's first, whichever is first.
public enum RecordWatchPolicy {
    /// The data root's status records, which k3sm writes by temp file and
    /// rename, so a watch on the directory sees each one.
    public static let statusDirectory = "/var/lib/k3sm/status"
    /// The launchd plists install, upgrade and uninstall write or remove.
    public static let launchDaemons = "/Library/LaunchDaemons"
    /// Every watched directory. Only directories are watched, never a record
    /// file, and the app reads nothing from them: a change only triggers the
    /// one read the app makes, `k3sm status -o json`.
    public static let paths = [statusDirectory, launchDaemons]

    public static let quiet: Duration = WatchPolicy.settleQuiet
    public static let ceiling: Duration = WatchPolicy.settleCap

    /// When the read for a burst that began at `firstAt` runs, as of a
    /// change at `now`: `quiet` after the latest change, never later than
    /// `ceiling` after the first.
    public static func readAt(firstAt: Duration, now: Duration) -> Duration {
        min(now + quiet, firstAt + ceiling)
    }
}

/// RecordChange is what a `ChangeSource` reports.
public enum RecordChange: Equatable, Sendable {
    /// Something in a watched directory changed, or a watched directory
    /// appeared, went away or was replaced.
    case changed
    /// Whether every path is held by a live watch on the path itself; false
    /// while one is missing (watched through an ancestor) or cannot be
    /// opened. Reported at start and on every change of the answer.
    case held(Bool)
}

/// ChangeSource is the report trigger's one seam to the file system:
/// `DirectoryChangeSource` in the app, a fake in the tests.
public protocol ChangeSource: AnyObject, Sendable {
    /// Starts watching; the stream ends at `stop()`. A second start replaces
    /// the first.
    func start() -> AsyncStream<RecordChange>
    /// Re-checks each path: a watched path whose identity (device and inode)
    /// changed without an event, or a path that was missing or unopenable,
    /// is armed again.
    func recheck()
    /// Stops watching and ends the stream.
    func stop()
}

/// ReportTrigger runs the console's full report read: on a change from its
/// `ChangeSource`, debounced by `RecordWatchPolicy`, and on a timer, which
/// is a heartbeat (`PollSchedule.consoleHeartbeatInterval`, 5 min under
/// Normal) only while every watch is held and the previous cadence
/// (`consoleReportInterval`, 30 s) otherwise, so the report is never left on
/// the slow timer with no live watch. Each tick re-checks the watched paths
/// first. Reads are one at a time (`PollGate`): a read asked for while one
/// runs becomes one more read after it. The heartbeat also bounds how stale
/// the rows k3sm reads from the API server get, until the report is itself
/// a stream. Every input arrives on the main actor through the source's
/// stream and `WatchClock`, so the loop runs in tests on a virtual clock.
@MainActor
public final class ReportTrigger {
    /// Whether every watch is held, as the source last said.
    public private(set) var held = false

    private let source: any ChangeSource
    private let clock: any WatchClock
    private let heartbeat: @MainActor () -> Duration
    private let fallback: @MainActor () -> Duration
    private let jitter: @MainActor () -> Double
    private let read: @MainActor () async -> Void

    private var running = false
    private var gate = PollGate()
    private var listener: Task<Void, Never>?
    private var tickTimer: (any WatchTimer)?
    private var debounceTimer: (any WatchTimer)?
    private var burstStart: Duration?

    public init(source: any ChangeSource, clock: any WatchClock,
                heartbeat: @escaping @MainActor () -> Duration = { PollSchedule.consoleHeartbeatInterval },
                fallback: @escaping @MainActor () -> Duration = { PollSchedule.consoleReportInterval },
                jitter: @escaping @MainActor () -> Double = { PollJitter.draw() },
                read: @escaping @MainActor () async -> Void) {
        self.source = source
        self.clock = clock
        self.heartbeat = heartbeat
        self.fallback = fallback
        self.jitter = jitter
        self.read = read
    }

    /// The timer's wait before jitter: the heartbeat while held, else the
    /// fallback cadence.
    public var cadence: Duration { held ? heartbeat() : fallback() }

    /// Starts the watch and the timer; the first timed read waits one
    /// cadence, since showing the window already reads. A second start is a
    /// no-op.
    public func start() {
        guard !running else { return }
        running = true
        held = false
        let stream = source.start()
        scheduleTick()
        listener = Task { @MainActor [weak self] in
            for await change in stream {
                guard let self, self.running else { return }
                self.receive(change)
            }
        }
    }

    /// Stops the watch and the timer; a read in flight finishes.
    public func stop() {
        guard running else { return }
        running = false
        source.stop()
        listener?.cancel()
        listener = nil
        tickTimer?.cancel()
        tickTimer = nil
        debounceTimer?.cancel()
        debounceTimer = nil
        burstStart = nil
        held = false
    }

    private func receive(_ change: RecordChange) {
        switch change {
        case .changed:
            let now = clock.now
            let first = burstStart ?? now
            burstStart = first
            debounceTimer?.cancel()
            debounceTimer = clock.schedule(at: RecordWatchPolicy.readAt(firstAt: first, now: now)) { [weak self] in
                guard let self, self.running else { return }
                self.burstStart = nil
                self.debounceTimer = nil
                self.requestRead()
            }
        case .held(let now):
            guard now != held else { return }
            held = now
            // The cadence changed: a lost watch puts the 30 s timer back
            // from now rather than after what is left of a heartbeat.
            scheduleTick()
        }
    }

    private func scheduleTick() {
        tickTimer?.cancel()
        let wait = PollJitter.spread(cadence, unit: jitter())
        tickTimer = clock.schedule(at: clock.now + wait) { [weak self] in
            guard let self, self.running else { return }
            self.source.recheck()
            self.requestRead()
            self.scheduleTick()
        }
    }

    private func requestRead() {
        guard gate.begin() else { return }
        Task { @MainActor [weak self] in
            while let self {
                if self.running { await self.read() }
                if !self.gate.finish() { return }
            }
        }
    }
}

/// DirectoryChangeSource watches directories with kqueue (a `DispatchSource`
/// per directory, each opened `O_EVTONLY` without following a symlink). A
/// path's ancestors are resolved first (`/var` is `/private/var`); the path
/// itself must be a real directory. Each path is in one of three states:
/// watched (an entry written, renamed or removed is a change; the
/// directory itself removed, renamed or revoked arms it again), waiting on
/// its nearest existing ancestor until it appears (a late directory, a data
/// volume mounted over the mountpoint, an uninstall that removed it), or
/// unheld (it cannot be opened: a symlink, a file, no permission). Every
/// re-arm cancels the old source, which closes its descriptor. `recheck()`
/// re-arms a watched path whose device and inode changed without an event,
/// and every path not watched.
public final class DirectoryChangeSource: ChangeSource, @unchecked Sendable {
    private let paths: [String]
    private let queue = DispatchQueue(label: "io.k3sm.app.record-watch")

    // Everything below is guarded by `queue`: touched only on it.
    private var watches: [PathWatch] = []
    private var continuation: AsyncStream<RecordChange>.Continuation?
    private var lastHeld: Bool?

    private final class PathWatch {
        enum State {
            case unheld
            case watching(DispatchSourceFileSystemObject, Identity)
            case waiting(DispatchSourceFileSystemObject)
        }
        let path: String
        var state: State = .unheld
        /// Bumped on every arm, so an event from a cancelled source is dropped.
        var generation = 0
        init(path: String) { self.path = path }

        var watching: Bool {
            if case .watching = state { return true }
            return false
        }
    }

    struct Identity: Equatable {
        let device: Int64
        let inode: UInt64
    }

    public init(paths: [String] = RecordWatchPolicy.paths) {
        self.paths = paths
    }

    deinit {
        for watch in watches { Self.cancel(watch) }
    }

    public func start() -> AsyncStream<RecordChange> {
        let (stream, continuation) = AsyncStream<RecordChange>.makeStream(bufferingPolicy: .unbounded)
        queue.sync {
            stopOnQueue()
            self.continuation = continuation
            watches = paths.map(PathWatch.init(path:))
            for watch in watches { arm(watch, announce: false) }
            publishHeld()
        }
        return stream
    }

    public func recheck() {
        queue.async { [self] in
            guard continuation != nil else { return }
            for watch in watches {
                switch watch.state {
                case .watching(_, let identity):
                    if Self.identity(of: Self.resolve(watch.path)) != identity { arm(watch, announce: true) }
                case .waiting, .unheld:
                    arm(watch, announce: true)
                }
            }
            publishHeld()
        }
    }

    public func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        for watch in watches { Self.cancel(watch) }
        watches = []
        continuation?.finish()
        continuation = nil
        lastHeld = nil
    }

    /// Opens the path, or failing that its nearest existing ancestor, and
    /// watches it. With `announce`, a change is reported when the path is
    /// now watched or was watched before (it appeared, went or was replaced).
    private func arm(_ watch: PathWatch, announce: Bool) {
        let wasWatching = watch.watching
        Self.cancel(watch)
        watch.generation += 1
        let generation = watch.generation
        let resolved = Self.resolve(watch.path)
        let fd = open(resolved, O_EVTONLY | O_NOFOLLOW | O_DIRECTORY)
        if fd >= 0 {
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                close(fd)
                watch.state = .unheld
                return
            }
            let source = makeSource(fd: fd, mask: [.write, .delete, .rename, .revoke]) { [weak self, weak watch] events in
                guard let self, let watch, watch.generation == generation else { return }
                if events.isDisjoint(with: [.delete, .rename, .revoke]) {
                    self.continuation?.yield(.changed)
                } else {
                    self.arm(watch, announce: true)
                    self.publishHeld()
                }
            }
            watch.state = .watching(source, Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)))
            if announce { continuation?.yield(.changed) }
            return
        }
        guard errno == ENOENT, let ancestor = Self.nearestAncestor(of: resolved) else {
            watch.state = .unheld
            if announce, wasWatching { continuation?.yield(.changed) }
            return
        }
        let parentFD = open(ancestor, O_EVTONLY | O_NOFOLLOW | O_DIRECTORY)
        guard parentFD >= 0 else {
            watch.state = .unheld
            if announce, wasWatching { continuation?.yield(.changed) }
            return
        }
        // Any event on the ancestor may be the path, or a nearer ancestor,
        // appearing: arm again and see.
        let source = makeSource(fd: parentFD, mask: [.write, .link, .delete, .rename, .revoke]) { [weak self, weak watch] _ in
            guard let self, let watch, watch.generation == generation else { return }
            self.arm(watch, announce: true)
            self.publishHeld()
        }
        watch.state = .waiting(source)
        if announce, wasWatching { continuation?.yield(.changed) }
    }

    private func makeSource(fd: Int32, mask: DispatchSource.FileSystemEvent,
                            handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func publishHeld() {
        let held = !watches.isEmpty && watches.allSatisfy(\.watching)
        guard held != lastHeld else { return }
        lastHeld = held
        continuation?.yield(.held(held))
    }

    private static func cancel(_ watch: PathWatch) {
        switch watch.state {
        case .watching(let source, _), .waiting(let source): source.cancel()
        case .unheld: break
        }
        watch.state = .unheld
    }

    /// `path` with its ancestors' symlinks resolved, its last component kept
    /// as written (it is opened without following a symlink).
    static func resolve(_ path: String) -> String {
        guard path.hasPrefix("/"), path != "/" else { return path }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let base = realPath(parent) ?? resolve(parent)
        return base == "/" ? "/" + name : base + "/" + name
    }

    /// The nearest ancestor of an absolute path that is a directory now.
    static func nearestAncestor(of path: String) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        while true {
            var info = stat()
            if lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return current }
            if current == "/" || current.isEmpty { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
