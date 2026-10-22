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

/// PipeRead reads a pipe as its writer fills it. `FileHandle.read(upToCount:)`
/// is not used on a pipe that stays open: it waits until it has the whole
/// count or the end of the stream, so a short line a writer sends and then
/// waits after (a watch's frame, a followed log's line, a request on the MCP
/// server's input) would stay in the pipe until the count was reached.
public enum PipeRead {
    /// One read(2) of what the pipe holds now, up to the buffer's size: nil
    /// at the end of the stream or on an error. A read interrupted by a
    /// signal is retried.
    public static func available(_ fd: Int32, into buffer: inout [UInt8]) -> Data? {
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }
}
