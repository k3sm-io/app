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

extension K3smCLI {
    /// The streamed output format of `k3sm image ls`: one JSON object a
    /// line, flushed as the registry is read. The one place it is spelled.
    public static let imageListStreamFormat = "ndjson"
    /// `k3sm image ls -o ndjson`: a `start` line (schema version 1 and the
    /// registry), `progress` lines, one `image` line per image as it is
    /// read, and an `end` line, or an `error` line and a non-zero exit.
    public static let imageListStreamArguments = ["image", "ls", "-o", imageListStreamFormat]
}

/// RegistryImageProgress is a streamed image list's last `progress` line:
/// how many repositories and tags the CLI has found and read so far. The
/// tag total grows until every repository is read. A count that is missing
/// or not a whole, non-negative number is nil.
public struct RegistryImageProgress: Equatable, Sendable {
    public let repositories: Int?
    public let repositoriesRead: Int?
    public let tags: Int?
    public let tagsRead: Int?

    public init(repositories: Int?, repositoriesRead: Int?, tags: Int?, tagsRead: Int?) {
        self.repositories = repositories
        self.repositoriesRead = repositoriesRead
        self.tags = tags
        self.tagsRead = tagsRead
    }

    /// The bar's fill, `tagsRead / tags` clamped to 0...1; nil (an
    /// indeterminate bar) until a tag total above zero is known.
    public var fraction: Double? {
        guard let tags, tags > 0, let tagsRead else { return nil }
        return min(1, max(0, Double(tagsRead) / Double(tags)))
    }

    /// The line beside the bar: "Reading the registry: 340 of 1,153 images",
    /// or "Reading the registry…" before the total is known.
    public var text: String {
        guard let tags, tags > 0, let tagsRead else { return RegistryImageProgress.startText }
        return "Reading the registry: \(Self.grouped(min(tagsRead, tags))) of \(Self.grouped(tags)) images"
    }

    /// The line before any count is known.
    public static let startText = "Reading the registry…"

    /// A count with a comma every three digits, the same on every Mac.
    static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }
}

/// RegistryImageEvent is one line of `k3sm image ls -o ndjson`, decoded.
public enum RegistryImageEvent: Equatable, Sendable {
    /// The first line: the registry, at schema version 1.
    case start(name: String, reachable: Bool, error: String?)
    /// A `start` line at a schema version this app does not read.
    case unsupportedSchema(Int?)
    case progress(RegistryImageProgress)
    case image(RegistryImage)
    /// The last line of a finished list.
    case end(cachedOnIncomplete: [String], migration: RegistryMigration?)
    /// The CLI stopped; its text is cleaned with `StatusDisplay.errorText`.
    case error(String)
    /// A line of a `type` this app does not know, or an image without a
    /// reference: skipped, so a newer CLI can add lines.
    case ignored
    /// A line that is not a JSON object with a string `type`.
    case malformed
}

/// RegistryImageStream reads one `k3sm image ls -o ndjson` run as its
/// output arrives: lines are framed at `OutputLimit.imageLine` (the run's
/// total is capped by `OutputLimit.list`), a `start` line must come first
/// and carry schema version 1, unknown types and keys are ignored, and the
/// first `error` line, refused schema or overlong line ends the reading.
/// Images are kept as they arrive, one per key, and listed sorted by
/// reference.
public struct RegistryImageStream: Sendable {
    private var framer = WatchLineFramer(maxLine: OutputLimit.imageLine)
    /// Whether a `start` line at schema version 1 was read.
    public private(set) var started = false
    /// Whether the `end` line was read.
    public private(set) var ended = false
    /// Whether any line was a known event: a CLI that does not stream
    /// prints none.
    public private(set) var spoke = false
    /// Why the reading stopped early (an `error` line, a refused schema, an
    /// overlong line); nil while it reads.
    public private(set) var failure: String?
    public private(set) var progress: RegistryImageProgress?
    private var registryName = ""
    private var reachable = false
    private var registryError: String?
    private var images: [RegistryImage] = []
    private var seen = Set<String>()
    private var cachedOnIncomplete: [String] = []
    private var migration: RegistryMigration?

    public init() {}

    /// How many images have been read.
    public var count: Int { images.count }

    /// The list as read so far; nil before the `start` line.
    public var list: RegistryImageList? {
        guard started else { return nil }
        return RegistryImageList(
            registryName: registryName, reachable: reachable, error: registryError,
            images: RegistryImages.sorted(images), cachedOnIncomplete: cachedOnIncomplete, migration: migration)
    }

    /// Reads the lines `chunk` completes.
    public mutating func append(_ chunk: Data) {
        guard failure == nil else { return }
        for line in framer.append(chunk) { apply(Self.event(line)) }
        if framer.overflowed, failure == nil {
            failure = "a line of k3sm image ls is longer than \(OutputLimit.imageLine >> 10) KiB"
        }
    }

    /// Reads the unterminated tail once the run is over: a whole object is
    /// read, a cut-off one is skipped.
    public mutating func finish() {
        guard failure == nil, let tail = framer.finish() else { return }
        apply(Self.event(tail))
    }

    private mutating func apply(_ event: RegistryImageEvent) {
        guard failure == nil, !ended else { return }
        switch event {
        case .ignored, .malformed:
            return
        case .unsupportedSchema(let version):
            spoke = true
            failure = RegistryImages.unsupportedText(version)
        case .error(let text):
            spoke = true
            failure = text
        case .start(let name, let reachable, let error):
            spoke = true
            guard !started else { return }
            started = true
            registryName = name
            self.reachable = reachable
            registryError = error
        case .progress(let p):
            spoke = true
            if started { progress = p }
        case .image(let image):
            spoke = true
            guard started, seen.insert(image.key).inserted else { return }
            images.append(image)
        case .end(let incomplete, let migration):
            spoke = true
            guard started else { return }
            ended = true
            cachedOnIncomplete = incomplete
            self.migration = migration
        }
    }

    /// One line, decoded.
    public static func event(_ line: Data) -> RegistryImageEvent {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return .malformed }
        switch type {
        case "start":
            let version = RegistryImages.number(object["schemaVersion"])
            guard version == Int64(RegistryImages.schemaVersion) else {
                return .unsupportedSchema(version.flatMap { Int(exactly: $0) })
            }
            guard let registry = object["registry"] as? [String: Any] else { return .malformed }
            return .start(
                name: StatusDisplay.clip(registry["name"] as? String ?? ""),
                reachable: registry["reachable"] as? Bool ?? false,
                error: (registry["error"] as? String).flatMap { $0.isEmpty ? nil : StatusDisplay.errorText($0) })
        case "progress":
            func count(_ key: String) -> Int? {
                RegistryImages.number(object[key]).flatMap { $0 >= 0 ? Int(exactly: $0) : nil }
            }
            return .progress(RegistryImageProgress(
                repositories: count("repositories"), repositoriesRead: count("repositoriesRead"),
                tags: count("tags"), tagsRead: count("tagsRead")))
        case "image":
            return RegistryImages.image(object).map(RegistryImageEvent.image) ?? .ignored
        case "end":
            return .end(cachedOnIncomplete: RegistryImages.nodes(object["cachedOnIncomplete"]),
                        migration: RegistryImages.migration(object["migration"]))
        case "error":
            let text = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "k3sm image ls stopped with no reason given"
            return .error(StatusDisplay.errorText(text))
        default:
            return .ignored
        }
    }

    /// Whether a run that ended so came from a CLI that does not stream: it
    /// exited non-zero without printing one line of the stream (a usage
    /// error for the unknown `-o` value).
    public func needsFallback(_ end: ImageListRunEnd) -> Bool {
        if case .exited(let status, _) = end { return status != 0 && !spoke }
        return false
    }

    /// The run as a tab result, once it is over and `finish` was called.
    public func result(_ end: ImageListRunEnd) -> TabResult<RegistryImageList> {
        switch end {
        case .missing, .failedToLaunch, .refused, .killed, .truncated:
            return RegistryImages.runResult(end) ?? .failed("the k3sm CLI did not answer")
        case .exited(let status, _):
            if let failure { return .failed(failure) }
            guard status == 0 else { return .failed("k3sm image ls exited \(status)") }
            guard let list, ended else {
                return .failed(started ? "k3sm image ls stopped before the end of the list" : "the registry's image list could not be read")
            }
            return .value(list)
        }
    }
}

/// ImageListRunEnd is how one `k3sm image ls` run ended: the app's
/// `CLIOutcome`, in the terms the Images read needs.
public enum ImageListRunEnd: Sendable {
    case missing
    case failedToLaunch
    case refused(String)
    /// Killed at `PollSchedule.imageListDeadline`.
    case killed
    /// Past `OutputLimit.list`.
    case truncated
    case exited(Int32, Data)
}

/// ImageListRun is one `k3sm image ls` run: the arguments, and a sink for
/// each chunk of output as it is read (nil for the one-shot JSON read). The
/// app's run is `CLIProcess` with `PollSchedule.imageListDeadline`.
public typealias ImageListRun = @Sendable (_ arguments: [String], _ onOutput: (@Sendable (Data) -> Void)?) async -> ImageListRunEnd

extension RegistryImages {
    /// The line for a read killed at its deadline.
    public static var deadlineText: String {
        let seconds = PollSchedule.imageListDeadline.components.seconds
        let limit = seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
        return "k3sm image ls did not finish within \(limit)"
    }

    /// The line when a read's rows stop short.
    public static func partialText(_ count: Int) -> String {
        count == 1
            ? "Showing the 1 image read before the list stopped."
            : "Showing the \(RegistryImageProgress.grouped(count)) images read before the list stopped."
    }

    /// The result of a run that did not exit, or nil when it did.
    static func runResult(_ end: ImageListRunEnd) -> TabResult<RegistryImageList>? {
        switch end {
        case .missing: return .unavailable(TabLoad.notInstalled)
        case .failedToLaunch, .refused: return .failed("the k3sm CLI did not answer")
        case .killed: return .failed(deadlineText)
        case .truncated: return .failed("the registry image list is larger than \(OutputLimit.list >> 20) MiB")
        case .exited: return nil
        }
    }
}

/// RegistryImageReader is the Images tab's read, the `TabReader`'s read
/// function: one `k3sm image ls -o ndjson` run, whose rows and progress are
/// in `current` as they arrive, or, once a CLI has refused the streamed
/// format, `-o json` for the rest of the session. `TabReader` keeps the
/// runs serial; a run's chunks that land after a newer run began are
/// dropped.
@MainActor
public final class RegistryImageReader {
    /// The run in flight, or the last one; nil before the first, and after a
    /// fallback to `-o json`.
    public private(set) var current: RegistryImageStream?
    /// Whether the CLI streams; false once it refused `-o ndjson`.
    public private(set) var streams = true
    /// Called before `current` or `streams` changes.
    public var changed: (@MainActor () -> Void)?
    private let run: ImageListRun
    private var generation = 0

    public init(run: @escaping ImageListRun) {
        self.run = run
    }

    /// One read.
    public func read() async -> TabResult<RegistryImageList> {
        guard streams else { return await readJSON() }
        generation += 1
        let mine = generation
        changed?()
        current = RegistryImageStream()
        let end = await run(K3smCLI.imageListStreamArguments) { [weak self] chunk in
            // The main queue keeps the chunks in order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.feed(chunk, generation: mine) } }
        }
        // Let the chunks already queued land before the run is judged.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        guard mine == generation, var stream = current else { return .failed("the k3sm CLI did not answer") }
        changed?()
        stream.finish()
        if stream.needsFallback(end) {
            streams = false
            current = nil
            return await readJSON()
        }
        current = stream
        return stream.result(end)
    }

    private func feed(_ chunk: Data, generation: Int) {
        guard generation == self.generation, current != nil else { return }
        changed?()
        current?.append(chunk)
    }

    private func readJSON() async -> TabResult<RegistryImageList> {
        let end = await run(K3smCLI.imageListArguments, nil)
        if let result = RegistryImages.runResult(end) { return result }
        guard case .exited(let status, let stdout) = end else { return .failed("the k3sm CLI did not answer") }
        return RegistryImages.tabResult(exitCode: status, stdout: stdout)
    }
}

/// RegistryImagesShown is what the Images tab draws from its read: the
/// rows, the progress bar while a streamed run reads, and whether the rows
/// are what a failed run read before it stopped.
public struct RegistryImagesShown: Equatable, Sendable {
    /// The rows' list; nil when there is none to show.
    public let list: RegistryImageList?
    /// The progress line and bar; nil when no streamed run is reading.
    public let progress: RegistryImageProgress?
    /// Whether a run is reading (the bar shows, indeterminate without `progress`).
    public let reading: Bool
    /// Whether `list` is the part a failed run read.
    public let partial: Bool

    /// The tab's state. A first read shows rows as they arrive; a refresh
    /// keeps the rows it has until the new run ends, then the reader
    /// replaces them, so the list never empties between runs. A failed run
    /// keeps the images it read, marked partial, under its error.
    public static func of(value: RegistryImageList?, load: TabLoad, stream: RegistryImageStream?) -> RegistryImagesShown {
        if load.inFlight {
            let reading = !(stream?.ended ?? false)
            return RegistryImagesShown(
                list: value ?? stream?.list, progress: reading ? stream?.progress : nil, reading: reading, partial: false)
        }
        if case .failed = load, value == nil, let list = stream?.list, !list.images.isEmpty {
            return RegistryImagesShown(list: list, progress: nil, reading: false, partial: true)
        }
        return RegistryImagesShown(list: value, progress: nil, reading: false, partial: false)
    }
}
