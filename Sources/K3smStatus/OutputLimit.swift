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

/// OutputLimit is the most standard output the app reads from one run of
/// the CLI. Cluster-supplied output (a pod list, a manifest, a log) can be
/// any size, so the reader stops at the limit and the run is killed rather
/// than the whole payload being held on every poll.
public enum OutputLimit {
    /// The status report, the daemons probe and `k3sm version`: 1 MiB.
    public static let status = 1 << 20
    /// The pod and node lists: 16 MiB.
    public static let list = 16 << 20
    /// The metrics read, nodes and pods in one list: 16 MiB. Each list once
    /// had 4 MiB of compact `--raw` JSON; the one read carries both, and
    /// kubectl prints it indented, about twice the bytes, so 2 x 2 x 4 MiB.
    public static let metrics = 16 << 20
    /// The inspector's logs, events or manifest: 64 KiB, the most it shows.
    public static let detail = 64 << 10
    /// One log read for the Summarize Logs action: 256 KiB, room for
    /// `K3smCLI.logSummaryTail` stamped lines.
    public static let logSummary = 256 << 10
    /// A build's stored log in its sheet: 1 MiB. The CLI keeps up to 16 MiB;
    /// past this the sheet says the rest is in `k3sm build logs`.
    public static let buildLog = 1 << 20
}

/// CappedOutput keeps at most `limit` bytes of a stream, in order, and
/// records whether more arrived.
public struct CappedOutput: Sendable {
    public let limit: Int
    public private(set) var data = Data()
    /// True once the stream has passed `limit`: the bytes past it were dropped.
    public private(set) var overflowed = false

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// append adds `chunk` up to the limit. It returns false once the stream
    /// has passed the limit, so the reader can stop and end the producer.
    public mutating func append(_ chunk: Data) -> Bool {
        guard !overflowed else { return false }
        let room = limit - data.count
        if chunk.count <= room {
            data.append(chunk)
            return true
        }
        data.append(chunk.prefix(room))
        overflowed = true
        return false
    }
}
