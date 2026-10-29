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
import Synchronization
import Testing
@testable import K3smStatus

/// FakeImageCLI stands in for the app's `k3sm image ls` run: each call takes
/// the next scripted run, hands its chunks to the sink one at a time
/// (pausing before the chunk indexes in `pauses`, so a test can look at the
/// tab mid-run), and returns its end. It records every argument list.
final class FakeImageCLI: Sendable {
    struct Run: Sendable {
        var chunks: [Data] = []
        var pauses: Set<Int> = []
        var end: ImageListRunEnd
    }

    private let state: Mutex<(runs: [Run], calls: [[String]])>
    private let pause: @Sendable (Int) async -> Void

    init(_ runs: [Run], pause: @escaping @Sendable (Int) async -> Void = { _ in }) {
        state = Mutex((runs, []))
        self.pause = pause
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    var run: ImageListRun {
        { arguments, onOutput in
            let next = self.state.withLock { s -> Run in
                s.calls.append(arguments)
                return s.runs.isEmpty ? Run(end: .failedToLaunch) : s.runs.removeFirst()
            }
            for (i, chunk) in next.chunks.enumerated() {
                if next.pauses.contains(i) { await self.pause(i) }
                onOutput?(chunk)
            }
            return next.end
        }
    }
}

/// Lets every block already on the main queue run, as the reader's chunks
/// are delivered there.
func drainMainQueue() async {
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
}

/// What a test saw at a pause, read on the main actor.
final class Seen: Sendable {
    private let state = Mutex<[Int: RegistryImagesShown]>([:])
    func record(_ index: Int, _ shown: RegistryImagesShown) { state.withLock { $0[index] = shown } }
    subscript(_ index: Int) -> RegistryImagesShown? { state.withLock { $0[index] } }
}

/// Holds the reader and the tab the fake's pause reads on the main actor.
@MainActor
final class TabUnderTest {
    var reader: RegistryImageReader?
    var tab: TabReader<RegistryImageList>?
    var shown: RegistryImagesShown {
        RegistryImagesShown.of(value: tab?.value, load: tab?.load ?? .idle, stream: reader?.current)
    }
}

@MainActor
@Suite("the Images tab's streamed registry read")
struct RegistryImageStreamTests {
    nonisolated static func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    static func lines(of name: String = "image_ls_stream.ndjson") throws -> [Data] {
        let text = try #require(String(data: try fixture(name), encoding: .utf8))
        return text.split(separator: "\n").map { line(String($0)) }
    }

    nonisolated static let startLine = #"{"type":"start","schemaVersion":1,"registry":{"name":"registry-k3sm:6450","reachable":true}}"#
    nonisolated static func imageLine(_ ref: String) -> String {
        #"{"type":"image","repository":"app","tag":"t","reference":"registry-k3sm:6450/"# + ref + #""}"#
    }
    nonisolated static let endLine = #"{"type":"end","images":0,"cachedOnIncomplete":[],"migration":null}"#

    /// A tab reading through `reader`, polled only when the test refreshes it.
    static func tab(_ reader: RegistryImageReader) -> TabReader<RegistryImageList> {
        TabReader(read: { await reader.read() }, interval: { _ in .seconds(3600) })
    }

    // MARK: Decoding

    @Test("each line type decodes, unknown types and keys are ignored, and anything else is malformed",
          arguments: [
            (startLine, RegistryImageEvent.start(name: "registry-k3sm:6450", reachable: true, error: nil)),
            (#"{"type":"start","schemaVersion":1,"registry":{"name":"r","reachable":false,"error":"dial tcp: refused"},"extra":1}"#,
             .start(name: "r", reachable: false, error: "dial tcp: refused")),
            (#"{"type":"start","schemaVersion":2,"registry":{}}"#, .unsupportedSchema(2)),
            (#"{"type":"start","registry":{}}"#, .unsupportedSchema(nil)),
            (#"{"type":"start","schemaVersion":"1","registry":{}}"#, .unsupportedSchema(nil)),
            (#"{"type":"start","schemaVersion":1}"#, .malformed),
            (#"{"type":"progress","repositories":4,"repositoriesRead":1,"tags":1153,"tagsRead":340,"rate":9}"#,
             .progress(RegistryImageProgress(repositories: 4, repositoriesRead: 1, tags: 1153, tagsRead: 340))),
            (#"{"type":"progress","tags":-1,"tagsRead":true}"#,
             .progress(RegistryImageProgress(repositories: nil, repositoriesRead: nil, tags: nil, tagsRead: nil))),
            (#"{"type":"image","tag":"v1"}"#, .ignored),
            (#"{"type":"end","images":3,"cachedOnIncomplete":["node-full","Bad Name"],"migration":{"held":2}}"#,
             .end(cachedOnIncomplete: ["node-full"], migration: RegistryMigration(held: 2))),
            (#"{"type":"error","error":"registry unreachable"}"#, .error("registry unreachable")),
            (#"{"type":"error"}"#, .error("k3sm image ls stopped with no reason given")),
            (#"{"type":"heartbeat","at":"now"}"#, .ignored),
            (#"{"schemaVersion":1}"#, .malformed),
            (#"{"type":"image","refer"#, .malformed),
            ("Error: unknown output format \"ndjson\"", .malformed),
          ])
    func lineDecodes(_ text: String, _ expected: RegistryImageEvent) {
        #expect(RegistryImageStream.event(Data(text.utf8)) == expected)
    }

    @Test("an image line decodes like an element of images[], unknown keys ignored")
    func imageLineMatchesJSONElement() throws {
        let json = try RegistryImages.decode(fixture("image_ls.golden.json"))
        var stream = RegistryImageStream()
        for line in try Self.lines() { stream.append(line) }
        stream.finish()
        #expect(stream.ended)
        #expect(stream.list == json)
    }

    @Test("the fixture reads to the JSON golden's list, sorted by reference whatever the arrival order")
    func fixtureReadsToList() throws {
        var stream = RegistryImageStream()
        for line in try Self.lines() { stream.append(line) }
        stream.finish()
        guard case .value(let list) = stream.result(.exited(0, Data())) else {
            Issue.record("the stream did not read")
            return
        }
        #expect(list.images.map(\.reference) == [
            "registry-k3sm:6450/app:v1", "registry-k3sm:6450/app:v2", "registry-k3sm:6450/tools/multi:v1",
        ])
        #expect(list.cachedOnIncomplete == ["node-full"])
        #expect(stream.progress?.fraction == 1)
    }

    /// Reads a fixture through a stream in 64 KiB chunks, as the pipe delivers it.
    static func streamed(_ name: String) throws -> RegistryImageStream {
        let data = try fixture(name)
        var stream = RegistryImageStream()
        var i = data.startIndex
        while i < data.endIndex {
            let next = data.index(i, offsetBy: 64 << 10, limitedBy: data.endIndex) ?? data.endIndex
            stream.append(data[i..<next])
            i = next
        }
        stream.finish()
        return stream
    }

    @Test("the live registry's sample reads: two images, its incomplete nodes, a first progress line at zero")
    func liveSampleReads() throws {
        // image_ls_ndjson_sample.golden.ndjson is six lines of a real run with
        // the repository and node names replaced; its end line counts the
        // whole registry, the sample keeps two of its images.
        let stream = try Self.streamed("image_ls_ndjson_sample.golden.ndjson")
        #expect(stream.started)
        #expect(stream.ended)
        #expect(stream.failure == nil)
        #expect(stream.count == 2)
        #expect(stream.progress == RegistryImageProgress(repositories: 28, repositoriesRead: 1, tags: 1, tagsRead: 0))
        guard case .value(let list) = stream.result(.exited(0, Data())) else {
            Issue.record("the sample did not read")
            return
        }
        #expect(list.registryName == "registry-k3sm:6450")
        #expect(list.reachable)
        #expect(list.cachedOnIncomplete == ["node-a", "node-b"])
        #expect(list.images.map(\.tag) == ["r1-1789002349", "r3-1789002350"])
        #expect(list.images.allSatisfy { $0.platforms == ["darwin/arm64/v8"] && $0.sizeBytes == 409 && $0.pods == 0 })
    }

    @Test("a first progress line with every count at zero leaves the bar indeterminate")
    func zeroProgressIsIndeterminate() throws {
        let first = try #require(try Self.lines(of: "image_ls_ndjson_sample.golden.ndjson").dropFirst().first)
        guard case .progress(let progress) = RegistryImageStream.event(first) else {
            Issue.record("the second line is not a progress line")
            return
        }
        #expect(progress == RegistryImageProgress(repositories: 28, repositoriesRead: 0, tags: 0, tagsRead: 0))
        #expect(progress.fraction == nil)
        #expect(progress.text == RegistryImageProgress.startText)
    }

    @Test("the live registry's whole run reads all 1,153 images with no error")
    func liveFullRunReads() throws {
        // image_ls_ndjson_full.golden.ndjson is a whole real run (1,153
        // images, 235 progress lines) with the names replaced.
        let stream = try Self.streamed("image_ls_ndjson_full.golden.ndjson")
        #expect(stream.failure == nil)
        #expect(stream.ended)
        #expect(stream.count == 1153)
        #expect(stream.progress?.fraction == 1)
        #expect(stream.progress?.text == "Reading the registry: 1,153 of 1,153 images")
        guard case .value(let list) = stream.result(.exited(0, Data())) else {
            Issue.record("the whole run did not read")
            return
        }
        #expect(list.images.count == 1153)
        #expect(list.images.map(\.reference) == list.images.map(\.reference).sorted())
        #expect(list.cachedOnIncomplete == ["node-a", "node-b"])
    }

    @Test("an unreachable registry's run ends with exit 0 and reads as the unreachable line")
    func unreachableEndsCleanly() {
        var stream = RegistryImageStream()
        stream.append(Self.line(#"{"type":"start","schemaVersion":1,"registry":{"name":"registry-k3sm:6450","reachable":false,"error":"dial tcp: connect: connection refused"}}"#))
        stream.append(Self.line(#"{"type":"end","images":0,"cachedOnIncomplete":[],"migration":null}"#))
        stream.finish()
        guard case .value(let list) = stream.result(.exited(0, Data())) else {
            Issue.record("an unreachable registry's run did not read")
            return
        }
        #expect(!list.reachable)
        #expect(list.images.isEmpty)
        #expect(RegistryImages.unreachableText(list)
            == "The registry registry-k3sm:6450 could not be reached: dial tcp: connect: connection refused.")
    }

    @Test("a chunk boundary inside a line still frames whole lines")
    func chunkBoundary() throws {
        let all = try Self.lines().reduce(Data(), +)
        var stream = RegistryImageStream()
        var i = all.startIndex
        while i < all.endIndex {
            let next = all.index(i, offsetBy: 7, limitedBy: all.endIndex) ?? all.endIndex
            stream.append(all[i..<next])
            i = next
        }
        stream.finish()
        #expect(stream.ended)
        #expect(stream.count == 3)
    }

    @Test("a schema version other than 1 refuses the run and ignores what follows")
    func badSchemaRefused() {
        var stream = RegistryImageStream()
        stream.append(Self.line(#"{"type":"start","schemaVersion":2,"registry":{"name":"r","reachable":true}}"#))
        stream.append(Self.line(Self.imageLine("a:1")))
        stream.append(Self.line(Self.endLine))
        stream.finish()
        #expect(stream.count == 0)
        #expect(stream.result(.exited(0, Data())) == .failed(RegistryImages.unsupportedText(2)))
    }

    @Test("a cut-off last line is skipped, and a run without its end line fails keeping the rows read")
    func truncatedLastLine() {
        var stream = RegistryImageStream()
        stream.append(Self.line(Self.startLine))
        stream.append(Self.line(Self.imageLine("a:1")))
        stream.append(Data(#"{"type":"image","reference":"registry-k3"#.utf8))
        stream.finish()
        #expect(stream.count == 1)
        #expect(stream.result(.exited(0, Data())) == .failed("k3sm image ls stopped before the end of the list"))
    }

    @Test("a whole last line without its newline is read")
    func unterminatedEndLine() {
        var stream = RegistryImageStream()
        stream.append(Self.line(Self.startLine))
        stream.append(Data(Self.endLine.utf8))
        stream.finish()
        #expect(stream.ended)
    }

    @Test("an error line fails the run with its text and keeps the rows read before it")
    func errorLine() {
        var stream = RegistryImageStream()
        stream.append(Self.line(Self.startLine))
        stream.append(Self.line(Self.imageLine("a:1")))
        stream.append(Self.line(#"{"type":"error","error":"registry: 503 Service Unavailable"}"#))
        stream.finish()
        #expect(stream.count == 1)
        #expect(!stream.needsFallback(.exited(1, Data())))
        #expect(stream.result(.exited(1, Data())) == .failed("registry: 503 Service Unavailable"))
    }

    @Test("a line past the line limit stops the read")
    func overlongLine() {
        var stream = RegistryImageStream()
        stream.append(Self.line(Self.startLine))
        stream.append(Data(repeating: 0x61, count: OutputLimit.imageLine + 1))
        stream.append(Self.line(Self.endLine))
        #expect(stream.result(.exited(0, Data())) == .failed("a line of k3sm image ls is longer than 64 KiB"))
    }

    // MARK: Progress

    @Test("the bar fills tagsRead of tags and says so; indeterminate until a total is known",
          arguments: [
            (RegistryImageProgress(repositories: 4, repositoriesRead: 1, tags: 1153, tagsRead: 340),
             Optional(340.0 / 1153.0), "Reading the registry: 340 of 1,153 images"),
            (RegistryImageProgress(repositories: 4, repositoriesRead: 0, tags: nil, tagsRead: nil), nil, "Reading the registry…"),
            (RegistryImageProgress(repositories: 4, repositoriesRead: 0, tags: 0, tagsRead: 0), nil, "Reading the registry…"),
            (RegistryImageProgress(repositories: 1, repositoriesRead: 1, tags: 3, tagsRead: 5), 1.0, "Reading the registry: 3 of 3 images"),
            (RegistryImageProgress(repositories: 9, repositoriesRead: 9, tags: 1_234_567, tagsRead: 1000), 1000.0 / 1_234_567.0,
             "Reading the registry: 1,000 of 1,234,567 images"),
          ])
    func progress(_ progress: RegistryImageProgress, _ fraction: Double?, _ text: String) {
        #expect(progress.fraction == fraction)
        #expect(progress.text == text)
    }

    // MARK: The deadline

    @Test("the image list has its own two-minute deadline, and a kill says so")
    func deadline() {
        #expect(PollSchedule.imageListDeadline == .seconds(120))
        #expect(PollSchedule.imageListDeadline > PollSchedule.listDeadline)
        #expect(RegistryImages.deadlineText == "k3sm image ls did not finish within 2 minutes")
    }

    @Test("a run killed at its deadline is a visible error over the rows it read, marked partial")
    func killShownAsError() async throws {
        let cli = FakeImageCLI([.init(chunks: [Self.line(Self.startLine), Self.line(Self.imageLine("a:1"))], end: .killed)])
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        await tab.refresh()
        #expect(tab.load == .failed("k3sm image ls did not finish within 2 minutes"))
        let shown = RegistryImagesShown.of(value: tab.value, load: tab.load, stream: reader.current)
        #expect(shown.partial)
        #expect(!shown.reading)
        #expect(shown.list?.images.map(\.reference) == ["registry-k3sm:6450/a:1"])
    }

    @Test("a run killed before any image shows only the error")
    func killWithNothingRead() async {
        let cli = FakeImageCLI([.init(chunks: [Self.line(Self.startLine)], end: .killed)])
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        await tab.refresh()
        let shown = RegistryImagesShown.of(value: tab.value, load: tab.load, stream: reader.current)
        #expect(tab.load == .failed(RegistryImages.deadlineText))
        #expect(shown.list == nil)
        #expect(!shown.partial)
    }

    // MARK: The loader

    @Test("a first read shows rows and progress as the lines arrive, then the list at the end")
    func accumulatesIncrementally() async throws {
        let lines = try Self.lines()
        let under = TabUnderTest()
        let seen = Seen()
        let cli = FakeImageCLI([.init(chunks: lines, pauses: [1, 4, 9], end: .exited(0, Data()))]) { index in
            await drainMainQueue()
            await MainActor.run { seen.record(index, under.shown) }
        }
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        under.reader = reader
        under.tab = tab
        await tab.refresh()

        // After the start line: reading, no rows yet, no total.
        let atStart = try #require(seen[1])
        #expect(atStart.reading)
        #expect(atStart.list?.images.isEmpty == true)
        #expect(atStart.progress == nil)
        // After the first image and a progress line with one tag known.
        let midway = try #require(seen[4])
        #expect(midway.reading)
        #expect(midway.list?.images.map(\.reference) == ["registry-k3sm:6450/tools/multi:v1"])
        #expect(midway.progress?.fraction == 0)
        // Before the end line: all three, sorted, the bar full.
        let beforeEnd = try #require(seen[9])
        #expect(beforeEnd.list?.images.map(\.reference) == [
            "registry-k3sm:6450/app:v1", "registry-k3sm:6450/app:v2", "registry-k3sm:6450/tools/multi:v1",
        ])
        #expect(beforeEnd.progress?.text == "Reading the registry: 3 of 3 images")
        // At the end: loaded, the bar gone.
        #expect(tab.value?.images.count == 3)
        let after = under.shown
        #expect(!after.reading)
        #expect(after.progress == nil)
        #expect(cli.calls == [K3smCLI.imageListStreamArguments])
    }

    @Test("a refresh keeps the rows on screen until its end, then replaces them")
    func refreshWithoutFlicker() async throws {
        let lines = try Self.lines()
        let under = TabUnderTest()
        let seen = Seen()
        let second = [Self.line(Self.startLine),
                      Self.line(#"{"type":"progress","repositories":1,"repositoriesRead":0,"tags":1,"tagsRead":0}"#),
                      Self.line(Self.imageLine("b:1")), Self.line(Self.endLine)]
        let cli = FakeImageCLI([
            .init(chunks: lines, end: .exited(0, Data())),
            .init(chunks: second, pauses: [3], end: .exited(0, Data())),
        ]) { index in
            await drainMainQueue()
            await MainActor.run { seen.record(index, under.shown) }
        }
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        under.reader = reader
        under.tab = tab
        await tab.refresh()
        #expect(tab.value?.images.count == 3)
        await tab.refresh()

        let during = try #require(seen[3])
        #expect(during.reading)
        #expect(during.list?.images.count == 3)
        #expect(during.progress?.text == "Reading the registry: 0 of 1 images")
        #expect(tab.value?.images.map(\.reference) == ["registry-k3sm:6450/b:1"])
        #expect(under.shown.list?.images.count == 1)
    }

    @Test("a CLI that refuses -o ndjson is read with -o json, once, for the rest of the session")
    func fallsBackToJSON() async throws {
        let golden = try fixture("image_ls.golden.json")
        let cli = FakeImageCLI([
            .init(chunks: [Data("Error: unknown output format \"ndjson\"\n".utf8)], end: .exited(1, Data())),
            .init(end: .exited(0, golden)),
            .init(end: .exited(0, golden)),
        ])
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        await tab.refresh()
        #expect(!reader.streams)
        #expect(tab.value?.images.count == 3)
        await tab.refresh()
        #expect(cli.calls == [K3smCLI.imageListStreamArguments, K3smCLI.imageListArguments, K3smCLI.imageListArguments])
    }

    @Test("the JSON fallback's kill is the same visible deadline error")
    func fallbackKill() async {
        let cli = FakeImageCLI([.init(end: .exited(2, Data())), .init(end: .killed)])
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        await tab.refresh()
        #expect(tab.load == .failed(RegistryImages.deadlineText))
    }

    @Test("a streaming CLI's non-zero exit does not fall back")
    func noFallbackAfterStreaming() async {
        let cli = FakeImageCLI([.init(chunks: [Self.line(Self.startLine)], end: .exited(1, Data()))])
        let reader = RegistryImageReader(run: cli.run)
        let tab = Self.tab(reader)
        await tab.refresh()
        #expect(reader.streams)
        #expect(tab.load == .failed("k3sm image ls exited 1"))
        #expect(cli.calls.count == 1)
    }

    @Test("the stream's flag is spelled once")
    func flagSpelledOnce() {
        #expect(K3smCLI.imageListStreamArguments == ["image", "ls", "-o", K3smCLI.imageListStreamFormat])
        #expect(K3smCLI.imageListArguments == ["image", "ls", "-o", "json"])
    }
}
