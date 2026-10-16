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

/// JSONValue is one JSON document as the server reads and writes it: a
/// closed, Sendable tree, so every message is built from typed values and
/// never from text. It is serialised compactly with sorted keys, which keeps
/// a message on one line (the stdio transport's framing) and the output
/// reproducible.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// JSONParseError says why bytes are not one JSON document.
    public enum ParseError: Error, Equatable, Sendable {
        case malformed
    }

    /// Parses one JSON document; any top-level value is accepted.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ParseError.malformed
        }
        return JSONValue(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if !CFNumberIsFloatType(number), let int = Int(exactly: number.int64Value) {
                self = .int(int)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The value as a Foundation object for `JSONSerialization`. A double
    /// that is not finite becomes null, since JSON has no such number.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    /// The compact serialisation, keys sorted, with no line break anywhere:
    /// a line break inside a string is escaped. A scalar at the top level is
    /// wrapped and unwrapped so it serialises too.
    public func serialized() -> Data {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if let data = try? JSONSerialization.data(withJSONObject: foundation, options: options) {
            return data
        }
        return Data("null".utf8)
    }

    /// The serialisation as text.
    public var text: String {
        String(decoding: serialized(), as: UTF8.self)
    }

    /// The member `key` of an object, nil for anything else.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// A string, or null for nil.
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    /// A bool, or null for nil.
    static func optional(_ value: Bool?) -> JSONValue {
        value.map(JSONValue.bool) ?? .null
    }

    /// An integer, or null for nil.
    static func optional(_ value: Int64?) -> JSONValue {
        value.flatMap { Int(exactly: $0) }.map(JSONValue.int) ?? .null
    }

    /// An integer, or null for nil.
    static func optional(_ value: Int?) -> JSONValue {
        value.map(JSONValue.int) ?? .null
    }
}
