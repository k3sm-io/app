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

/// LogColumns is the width of a log's longest line, in monospaced columns,
/// kept as the log grows. A log view does not wrap its lines; it scrolls
/// sideways to the longest one, so it needs that width. Measuring every line
/// on each append would cost the whole log per line read, so the count is
/// incremental: `append` reads only the new text, carrying the open last
/// line's columns into the next append.
///
/// A tab moves to the next stop of `tabStop` columns (the view sets its tab
/// stops to match) and a wide East Asian character or emoji counts two.
public struct LogColumns: Equatable, Sendable {
    /// Columns between tab stops.
    public static let tabStop = 8

    /// The longest line seen, the open last line included.
    public private(set) var longest = 0
    /// The columns of the last line, which has no newline yet.
    public private(set) var current = 0

    public init() {}

    /// The columns of `text` read at once.
    public init(_ text: some StringProtocol) {
        append(text)
    }

    /// append counts `text`, the log's new end.
    public mutating func append(_ text: some StringProtocol) {
        for character in text {
            if character.isNewline {
                current = 0
            } else if character == "\t" {
                current += Self.tabStop - current % Self.tabStop
            } else {
                current += Self.isWide(character) ? 2 : 1
            }
            if current > longest { longest = current }
        }
    }

    /// The width that shows the longest line whole: its columns at
    /// `advance` points each, the text inset on both sides, the line
    /// padding on both sides, and one point for the caret.
    public func width(advance: Double, inset: Double, padding: Double) -> Double {
        Double(longest) * advance + 2 * inset + 2 * padding + 1
    }

    /// Whether a monospaced font draws `character` two columns wide: the
    /// East Asian wide and fullwidth blocks and the emoji pictographs.
    static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value, scalar >= 0x1100 else { return false }
        switch scalar {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
