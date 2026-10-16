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

/// StdioTransport is the MCP stdio transport: newline-delimited JSON-RPC on
/// standard input and output. Standard output carries only replies, one per
/// line; anything else the server says goes to standard error. A line longer
/// than `maxLineBytes` is discarded up to its line break and answered with a
/// parse error, so a runaway client cannot grow the buffer without bound.
public enum StdioTransport {
    /// The longest request line read: requests are small.
    public static let maxLineBytes = 1 << 20

    /// Line is one framed input line, or the marker of one that was too long.
    enum Line: Sendable {
        case message(Data)
        case overlong
    }

    /// Serves `server` until `input` reaches end of file, one message at a
    /// time, writing each reply and a line break to `output`.
    public static func serve(_ server: MCPServer, input: FileHandle, output: FileHandle, maxLineBytes: Int = maxLineBytes) async {
        for await line in lines(from: input, maxLineBytes: maxLineBytes) {
            let reply: Data?
            switch line {
            case .message(let data):
                reply = await server.handle(data)
            case .overlong:
                reply = MCPServer.error(id: .null, .parseError, "Parse error: the line is longer than \(maxLineBytes) bytes.")
            }
            guard var reply else { continue }
            reply.append(0x0A)
            do {
                try output.write(contentsOf: reply)
            } catch {
                return
            }
        }
    }

    /// The input split at line breaks, read on a thread of its own so a
    /// blocking read never holds a task's thread.
    static func lines(from input: FileHandle, maxLineBytes: Int) -> AsyncStream<Line> {
        AsyncStream { continuation in
            let thread = Thread {
                var splitter = LineSplitter(maxLineBytes: maxLineBytes)
                while let chunk = try? input.read(upToCount: 64 * 1024), !chunk.isEmpty {
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
