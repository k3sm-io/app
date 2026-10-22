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
import K3smStatus

/// StdioTransport is the MCP stdio transport: newline-delimited JSON-RPC on
/// standard input and output. Standard output carries only replies, one per
/// line; anything else the server says goes to standard error. A line longer
/// than `maxLineBytes` is discarded up to its line break and answered with a
/// parse error, so a runaway client cannot grow the buffer without bound.
///
/// Messages are handled one at a time, in order. While one runs, at most
/// `maxQueued` more wait; a message past that is answered at once with a
/// `serverBusy` error and dropped. `notifications/cancelled` is acted on as
/// it arrives: it cancels the matching request in flight (its CLI run is
/// killed, and no reply is sent for it) or drops it from the queue.
public enum StdioTransport {
    /// The longest request line read: requests are small.
    public static let maxLineBytes = 1 << 20
    /// The most messages that wait while one runs.
    public static let maxQueued = 8

    /// Line is one framed input line, or the marker of one that was too long.
    enum Line: Sendable {
        case message(Data)
        case overlong
    }

    /// Serves `server` until `input` reaches end of file and every queued
    /// message has been answered, writing each reply and a line break to
    /// `output`.
    public static func serve(_ server: MCPServer, input: FileHandle, output: FileHandle,
                             maxLineBytes: Int = maxLineBytes, maxQueued: Int = maxQueued) async {
        let session = Session(server: server, writer: ReplyWriter(output: output), maxQueued: maxQueued, maxLineBytes: maxLineBytes)
        for await line in lines(from: input, maxLineBytes: maxLineBytes) {
            await session.receive(line)
        }
        await session.drain()
    }

    /// The input split at line breaks, read on a thread of its own so a
    /// blocking read never holds a task's thread.
    static func lines(from input: FileHandle, maxLineBytes: Int) -> AsyncStream<Line> {
        AsyncStream { continuation in
            let thread = Thread {
                var splitter = LineSplitter(maxLineBytes: maxLineBytes)
                // What the pipe holds as it arrives (`PipeRead`): a client
                // waits for each reply, so a request must not wait for more
                // input. The handle is held to the last read: it closes its
                // descriptor when it goes.
                let fd = input.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                defer { withExtendedLifetime(input) {} }
                while let chunk = PipeRead.available(fd, into: &buffer) {
                    for line in splitter.feed(chunk) { continuation.yield(line) }
                }
                if let last = splitter.finish() { continuation.yield(last) }
                continuation.finish()
            }
            thread.start()
        }
    }
}

/// LineSplitter cuts a byte stream into lines at LF, dropping a CR before
/// it, and marks a line past the limit as overlong instead of keeping it.
struct LineSplitter {
    let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func feed(_ chunk: Data) -> [StdioTransport.Line] {
        var out: [StdioTransport.Line] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll()
                continue
            }
            if buffer.count + piece.count > maxLineBytes {
                buffer.removeAll()
                out.append(.overlong)
                continue
            }
            buffer.append(contentsOf: piece)
            if buffer.last == 0x0D { buffer.removeLast() }
            out.append(.message(buffer))
            buffer = Data()
        }
        if discarding { return out }
        if buffer.count + rest.count > maxLineBytes {
            buffer.removeAll()
            discarding = true
            out.append(.overlong)
        } else {
            buffer.append(contentsOf: rest)
        }
        return out
    }

    /// The last line when the stream ended without a line break.
    mutating func finish() -> StdioTransport.Line? {
        defer { buffer = Data() }
        guard !discarding, !buffer.isEmpty else { return nil }
        return .message(buffer)
    }
}

/// ReplyWriter is the one writer of standard output, so replies from the
/// queue and the immediate busy errors never interleave within a line.
actor ReplyWriter {
    let output: FileHandle
    private var closed = false

    init(output: FileHandle) {
        self.output = output
    }

    func write(_ reply: Data) {
        guard !closed else { return }
        var line = reply
        line.append(0x0A)
        do {
            try output.write(contentsOf: line)
        } catch {
            closed = true
        }
    }
}

/// Session runs the queue: one message in flight, at most `maxQueued`
/// waiting, cancellation by request id.
actor Session {
    private enum Entry {
        case message(Data, id: JSONValue?)
        case overlong
    }

    private let server: MCPServer
    private let writer: ReplyWriter
    private let maxQueued: Int
    private let maxLineBytes: Int
    private var queue: [Entry] = []
    private var running: Task<Void, Never>?
    private var runningID: JSONValue?

    init(server: MCPServer, writer: ReplyWriter, maxQueued: Int, maxLineBytes: Int) {
        self.server = server
        self.writer = writer
        self.maxQueued = maxQueued
        self.maxLineBytes = maxLineBytes
    }

    func receive(_ line: StdioTransport.Line) async {
        let entry: Entry
        switch line {
        case .overlong:
            entry = .overlong
        case .message(let data):
            let message = try? JSONValue.parse(data)
            if message?["method"] == "notifications/cancelled", message?["id"] == nil {
                cancel(message?["params"]?["requestId"])
                return
            }
            let id = message?["id"].flatMap { MCPServer.validID($0) ? $0 : nil }
            entry = .message(data, id: id)
        }
        guard queue.count < maxQueued else {
            if case .message(_, let id) = entry {
                await writer.write(MCPServer.error(id: id ?? .null, .serverBusy,
                    "Server busy: more than \(maxQueued) messages are waiting; send this one again later."))
            }
            return
        }
        queue.append(entry)
        startNext()
    }

    /// Cancels the request with `id`: the one in flight, or a waiting one.
    private func cancel(_ id: JSONValue?) {
        guard let id, MCPServer.validID(id) else { return }
        if runningID == id {
            running?.cancel()
            return
        }
        queue.removeAll {
            if case .message(_, let queued) = $0 { return queued == id }
            return false
        }
    }

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        let server = server, writer = writer, maxLineBytes = maxLineBytes
        switch entry {
        case .overlong:
            runningID = nil
            running = Task {
                await writer.write(MCPServer.error(id: .null, .parseError, "Parse error: the line is longer than \(maxLineBytes) bytes."))
                self.finished()
            }
        case .message(let data, let id):
            runningID = id
            running = Task {
                if let reply = await server.handle(data), !Task.isCancelled {
                    await writer.write(reply)
                }
                self.finished()
            }
        }
    }

    private func finished() {
        running = nil
        runningID = nil
        startNext()
    }

    /// Waits until the message in flight and every queued one are done.
    func drain() async {
        while let task = running {
            await task.value
        }
    }
}
