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

import Darwin
import Foundation
import Synchronization

/// LoopbackServer is a one-thread HTTP/1.1 server on 127.0.0.1 for the
/// fetcher's tests: it records each request's bytes exactly as they arrived
/// and answers with the next scripted response, then closes the connection.
/// Nothing leaves the Mac.
final class LoopbackServer: Sendable {
    let port: UInt16
    private let listener: Int32
    private let state: Mutex<(requests: [Data], responses: [Data])>

    /// Starts listening; `responses` are sent in order, one per connection,
    /// the last repeated.
    init(responses: [Data]) throws {
        var addr = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var opened: Int32 = -1
        var failure: any Error = POSIXError(.EIO)
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                continue
            }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            if bound != 0 {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                continue
            }
            if listen(fd, 8) != 0 {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                continue
            }
            let named = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            if named != 0 {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                continue
            }
            opened = fd
            break
        }
        guard opened >= 0 else { throw failure }
        let fd = opened
        port = UInt16(bigEndian: addr.sin_port)
        listener = fd
        state = Mutex((requests: [], responses: responses))
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    /// The URL of `path` on this server.
    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Replaces the scripted responses (for a chain that needs the port).
    func setResponses(_ responses: [Data]) {
        state.withLock { $0.responses = responses }
    }

    /// Every request received so far, as raw bytes.
    var requests: [Data] { state.withLock { $0.requests } }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func serve() {
        while true {
            let conn = accept(listener, nil, nil)
            guard conn >= 0 else { return }
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while request.count < 65536, request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(conn, &buffer, buffer.count)
                if n <= 0 { break }
                request.append(contentsOf: buffer[0..<n])
            }
            let response = state.withLock { s -> Data in
                s.requests.append(request)
                return s.responses.count > 1 ? s.responses.removeFirst() : (s.responses.first ?? Data())
            }
            response.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(conn, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
            shutdown(conn, SHUT_WR)
            close(conn)
        }
    }

    /// An HTTP/1.1 response with `status`, `headers` and `body`; the body's
    /// length is sent only when `length` is true (otherwise the close ends it).
    static func response(_ status: String, headers: [String] = [], body: Data = Data(), length: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for header in headers { head += header + "\r\n" }
        if length { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
