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

/// WatchKind is a resource the console follows with a held kubectl watch
/// instead of a list poll: the pods (the Workloads tab and the panel) and
/// the nodes (the shared node list). Every other list stays on its timer.
public enum WatchKind: String, Sendable, CaseIterable {
    case pods
    case nodes

    /// The kubectl resource name the watch and the one-shot list name.
    public var resource: String { rawValue }

    /// The typed list the fold assembles, which the existing decoders
    /// (`Workloads.decode`, `NodeListRead.decode`) already accept.
    public var listKind: String {
        switch self {
        case .pods: return "PodList"
        case .nodes: return "NodeList"
        }
    }

    /// The kind every streamed object must carry.
    var objectKind: String {
        switch self {
        case .pods: return "Pod"
        case .nodes: return "Node"
        }
    }

    /// The one-shot list of the kind: the poll the watch replaces, run when
    /// a watch settles with no frame at all (an empty kind).
    public var listArguments: [String] {
        switch self {
        case .pods: return K3smCLI.workloadsArguments
        case .nodes: return K3smCLI.nodesArguments
        }
    }
}

/// WatchLineFramer splits a watch's standard output into lines: kubectl's
/// `--output-watch-events -o json` prints one compact JSON object per line.
/// A line is bounded: once the bytes since the last newline pass
/// `maxLine`, the framer stops for good (`overflowed`), and the stream is
/// degraded rather than retried, since a retry would meet the same object.
public struct WatchLineFramer: Sendable {
    public let maxLine: Int
    public private(set) var overflowed = false
    private var partial = Data()

    public init(maxLine: Int = WatchPolicy.maxLineBytes) {
        self.maxLine = max(1, maxLine)
    }

    /// The whole lines `chunk` completes, in order, without their newline
    /// (a trailing carriage return is dropped too); empty lines are skipped.
    /// After an overflow it returns nothing.
    public mutating func append(_ chunk: Data) -> [Data] {
        guard !overflowed else { return [] }
        var lines: [Data] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            let piece = chunk[start..<newline]
            guard partial.count + piece.count <= maxLine else {
                overflow()
                return lines
            }
            var line = partial
            line.append(piece)
            partial = Data()
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
            start = chunk.index(after: newline)
        }
        let rest = chunk[start...]
        guard partial.count + rest.count <= maxLine else {
            overflow()
            return lines
        }
        partial.append(rest)
        return lines
    }

    /// The unterminated tail at the end of the stream, if any.
    public mutating func finish() -> Data? {
        guard !overflowed, !partial.isEmpty else { return nil }
        defer { partial = Data() }
        return partial
    }

    private mutating func overflow() {
        overflowed = true
        partial = Data()
    }
}

/// WatchFrame is one watch line read: an object to add or replace (its key
/// and its raw JSON bytes), one to remove, or a line that changes nothing.
/// The object's bytes are kept as kubectl printed them, so the list is
/// assembled by concatenation and decoded once, by the existing decoder,
/// whose `StatusDisplay.clip` still guards every string shown.
public enum WatchFrame: Equatable, Sendable {
    case upsert(key: String, object: Data)
    case delete(key: String)
    /// A BOOKMARK, or an event type this build does not know: ignored.
    case ignored
    /// An ERROR whose Status code is 410: the resource version is gone and
    /// the watch is relisted at once.
    case gone
    /// An ERROR whose Status is 401 or 403 (or whose reason is Unauthorized
    /// or Forbidden): the cluster refused the credential. Read from the
    /// Status object's fields, never from its message text.
    case refused(message: String)
    /// Any other ERROR: the watch is restarted after a backoff.
    case failure(code: Int?, message: String)
    /// A line that is not a watch event with an object of the kind and a
    /// uid: counted toward the stream's undecodable burst, never folded.
    case undecodable

    /// Reads one line. Order is never taken from `resourceVersion`: the
    /// apiserver sends a watch in order, and a relist reconciles.
    ///
    /// An ADDED or MODIFIED object enters the fold only once it has been
    /// decoded as an object of the kind (`Pod`, `Node`) with a uid. In
    /// kubectl's compact shape, `{"type":"<T>","object":{...}}`, the object's
    /// bytes are cut out of the line and decoded on their own: they are the
    /// bytes the fold keeps, so the check covers exactly what is spliced into
    /// the list, and a cut that is not one whole JSON object is refused. A
    /// line of any other shape is decoded whole and its object serialized.
    public static func parse(_ line: Data, kind: WatchKind) -> WatchFrame {
        for type in ["ADDED", "MODIFIED"] {
            guard let raw = rawObject(line, type: type) else { continue }
            if let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                guard let key = validKey(of: object, kind: kind) else { return .undecodable }
                return .upsert(key: key, object: raw)
            }
            // Not one whole object (a line with more after it): read it whole.
            break
        }
        guard let top = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = top["type"] as? String else { return .undecodable }
        let object = top["object"] as? [String: Any]
        switch type {
        case "ADDED", "MODIFIED":
            guard let object, let key = validKey(of: object, kind: kind),
                  let raw = try? JSONSerialization.data(withJSONObject: object) else { return .undecodable }
            return .upsert(key: key, object: raw)
        case "DELETED":
            guard let object, let key = validKey(of: object, kind: kind) else { return .undecodable }
            return .delete(key: key)
        case "ERROR":
            let code = object.flatMap { KubeList.int($0, "code") }
            let reason = object.flatMap { KubeList.string($0, "reason") }
            let message = StatusDisplay.errorText(object.flatMap { KubeList.string($0, "message") } ?? "")
            if code == 410 { return .gone }
            if code == 401 || code == 403 || reason == "Unauthorized" || reason == "Forbidden" {
                return .refused(message: message)
            }
            return .failure(code: code, message: message)
        default:
            // BOOKMARK and any type a later apiserver adds.
            return .ignored
        }
    }

    /// The object's identity, its uid, when the object is of the kind; nil
    /// otherwise (no uid, an empty one, or another kind).
    static func validKey(of object: [String: Any], kind: WatchKind) -> String? {
        guard KubeList.string(object, "kind") == kind.objectKind else { return nil }
        guard let uid = KubeList.string(KubeList.dict(object, "metadata"), "uid"), !uid.isEmpty else { return nil }
        return uid
    }

    /// The bytes of `object` cut straight out of kubectl's compact line,
    /// `{"type":"<T>","object":{...}}`; nil when the line has another shape.
    /// The cut is not yet known to be one JSON object: `parse` decodes it.
    static func rawObject(_ line: Data, type: String) -> Data? {
        let prefix = Data(#"{"type":"\#(type)","object":"#.utf8)
        guard line.starts(with: prefix) else { return nil }
        var end = line.endIndex
        while end > line.startIndex, [0x20, 0x09, 0x0A, 0x0D].contains(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        let start = line.startIndex + prefix.count
        guard end > start + 1, line[line.index(before: end)] == UInt8(ascii: "}") else { return nil }
        let object = line[start..<line.index(before: end)]
        guard object.first == UInt8(ascii: "{"), object.last == UInt8(ascii: "}") else { return nil }
        return Data(object)
    }
}

/// WatchFold is one kind's objects as the watch last described them: each
/// object's raw bytes by key. The list the decoders take is assembled from
/// it by concatenation. It is bounded (`maxObjects`, `maxBytes`): past
/// either the stream falls back to the list poll, since the fold is
/// O(list) per redraw and that ceiling is stated, not discovered.
public struct WatchFold: Sendable {
    public enum Change: Equatable, Sendable {
        case changed
        case unchanged
        case overCap
    }

    public let maxObjects: Int
    public let maxBytes: Int
    private(set) var objects: [String: Data] = [:]
    public private(set) var bytes = 0

    public init(maxObjects: Int = WatchPolicy.maxObjects, maxBytes: Int = WatchPolicy.maxFoldBytes) {
        self.maxObjects = maxObjects
        self.maxBytes = maxBytes
    }

    public var count: Int { objects.count }

    /// Applies one frame: ADDED and MODIFIED add or replace, DELETED of an
    /// unknown key changes nothing; other frames are the stream's to handle.
    public mutating func apply(_ frame: WatchFrame) -> Change {
        switch frame {
        case .upsert(let key, let object):
            let old = objects[key]
            if old == object { return .unchanged }
            let newBytes = bytes - (old?.count ?? 0) + object.count
            let newCount = objects.count + (old == nil ? 1 : 0)
            guard newCount <= maxObjects, newBytes <= maxBytes else { return .overCap }
            objects[key] = object
            bytes = newBytes
            return .changed
        case .delete(let key):
            guard let old = objects.removeValue(forKey: key) else { return .unchanged }
            bytes -= old.count
            return .changed
        case .ignored, .gone, .refused, .failure, .undecodable:
            return .unchanged
        }
    }

    /// The fold as a typed list (`PodList`, `NodeList`), its items in key
    /// order so the same fold always gives the same bytes.
    public func list(kind: WatchKind) -> Data {
        var data = Data(#"{"apiVersion":"v1","kind":"\#(kind.listKind)","items":["#.utf8)
        data.reserveCapacity(bytes + objects.count + 64)
        for (index, key) in objects.keys.sorted().enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(objects[key]!)
        }
        data.append(contentsOf: Array("]}".utf8))
        return data
    }

    /// A fold of a one-shot list's items (the settle of a watch that sent
    /// no frame); nil when `data` is not a list of the kind or an item has
    /// no uid (the list poll then stands in).
    public static func fromList(_ data: Data, kind: WatchKind,
                                maxObjects: Int = WatchPolicy.maxObjects, maxBytes: Int = WatchPolicy.maxFoldBytes) -> WatchFold? {
        guard let items = try? KubeList.objects(data, kinds: [kind.objectKind]) else { return nil }
        var fold = WatchFold(maxObjects: maxObjects, maxBytes: maxBytes)
        for item in items {
            guard let key = WatchFrame.validKey(of: item, kind: kind),
                  let raw = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            if fold.apply(.upsert(key: key, object: raw)) == .overCap { return nil }
        }
        return fold
    }
}
