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

/// KubeListError says why kubectl's output could not be read as the list a
/// console tab asked for: not JSON with a `kind` and `items`, or a list
/// holding a kind the tab did not ask for (the text is that kind, clipped).
public enum KubeListError: Error, Equatable, Sendable {
    case malformed
    case unexpectedKind(String)
}

/// KubeList is the reading the Services, Storage, Models and Events tabs
/// share: the items of kubectl's `-o json` output as dictionaries, checked
/// against the kinds the tab asked for, and the tolerant field accessors
/// their decoders use. A field that is absent or mistyped reads as absent;
/// only a top level that is not a list fails the read.
enum KubeList {
    /// The items of a `List` (kubectl's shape for several types, or for
    /// `-A`) or a typed list (`<Kind>List`), each of a kind in `kinds`.
    static func objects(_ data: Data, kinds: Set<String>) throws -> [[String: Any]] {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = top["kind"] as? String, let items = top["items"] as? [Any] else {
            throw KubeListError.malformed
        }
        guard kind == "List" || kinds.contains(where: { kind == $0 + "List" }) else {
            throw KubeListError.unexpectedKind(StatusDisplay.clip(kind))
        }
        let objects = items.compactMap { $0 as? [String: Any] }
        // A typed list's items may omit their own kind; they are the list's.
        let implied = kind == "List" ? nil : String(kind.dropLast("List".count))
        for object in objects {
            let itemKind = object["kind"] as? String ?? implied ?? ""
            guard kinds.contains(itemKind) else { throw KubeListError.unexpectedKind(StatusDisplay.clip(itemKind)) }
        }
        return objects.map { object in
            guard object["kind"] == nil, let implied else { return object }
            var copy = object
            copy["kind"] = implied
            return copy
        }
    }

    /// One list run as a tab result: a non-zero exit, a malformed list or an
    /// unexpected kind fails with the app's own sentence.
    static func tabResult<Value>(
        exitCode: Int32, stdout: Data, what: String, decode: (Data) throws -> Value
    ) -> TabResult<Value> {
        guard exitCode == 0 else { return .failed("k3sm kubectl exited \(exitCode)") }
        do {
            return .value(try decode(stdout))
        } catch KubeListError.unexpectedKind(let kind) {
            return .failed("kubectl returned a \(kind), not the \(what)")
        } catch {
            return .failed("the \(what) could not be read")
        }
    }

    static func dict(_ object: [String: Any], _ key: String) -> [String: Any] {
        object[key] as? [String: Any] ?? [:]
    }

    static func array(_ object: [String: Any], _ key: String) -> [[String: Any]] {
        (object[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let s = object[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    /// A whole JSON number, never a boolean.
    static func int(_ object: [String: Any], _ key: String) -> Int? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// A whole, non-negative JSON number of bytes, never a boolean; nil past Int64.
    static func bytes(_ object: [String: Any], _ key: String) -> Int64? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let value = Int64(exactly: number.doubleValue), value >= 0 else { return nil }
        return value
    }

    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func name(_ object: [String: Any]) -> String {
        string(dict(object, "metadata"), "name") ?? ""
    }

    static func namespace(_ object: [String: Any]) -> String {
        string(dict(object, "metadata"), "namespace") ?? ""
    }

    /// An RFC 3339 time, with or without fractional seconds (an Event's
    /// `eventTime` is a MicroTime); nil for anything else.
    static func time(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
