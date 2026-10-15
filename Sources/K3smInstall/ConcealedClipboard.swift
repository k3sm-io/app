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

/// PasteboardType is a pasteboard type the app writes.
public struct PasteboardType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Plain text (`NSPasteboard.PasteboardType.string`).
    public static let string = PasteboardType(rawValue: "public.utf8-plain-text")
    /// The nspasteboard.org marker that asks clipboard managers and history
    /// tools not to record or show the item.
    public static let concealed = PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
}

/// PasteboardOptions are the preparation options of one pasteboard write.
public struct PasteboardOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The item stays on this Mac: Universal Clipboard does not offer it to
    /// other devices (`NSPasteboard.ContentsOptions.currentHostOnly`).
    public static let currentHostOnly = PasteboardOptions(rawValue: 1 << 0)
}

/// Pasteboard is the system pasteboard as the clipboard needs it. The app
/// adapts NSPasteboard; the tests use a fake that records each write.
@MainActor
public protocol Pasteboard: AnyObject {
    /// The pasteboard's change count now.
    var changeCount: Int { get }
    /// Replaces the contents with one item: `text` under the string type,
    /// and every other type in `types` as an empty marker, prepared with
    /// `options`. Returns the change count the write produced.
    func write(_ text: String, types: [PasteboardType], options: PasteboardOptions) -> Int
    /// Removes the contents.
    func clearContents()
    /// The types of the current item.
    var types: [PasteboardType] { get }
    /// The current item's string, if it has one.
    func string() -> String?
}

/// ClearTimer is a scheduled clear that can be cancelled.
@MainActor
public protocol ClearTimer: AnyObject {
    func cancel()
}

/// ClearScheduler runs a clear at a wall-clock deadline on the main queue.
/// The app's scheduler counts wall-clock time, so a Mac that sleeps past the
/// deadline clears on wake instead of a minute after it.
@MainActor
public protocol ClearScheduler: AnyObject {
    func schedule(at deadline: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any ClearTimer
}

/// ConcealedClipboard puts the join command on the pasteboard as a
/// concealed, this-Mac-only item and clears it after `lifetime`, only if
/// nothing replaced it meanwhile. The change count it compares against is
/// the one the write itself returned, never a later read, so another app's
/// copy in between is never mistaken for ours. A second copy cancels the
/// first clear and starts over; `clearIfUnchanged` (at quit) clears at once.
/// The clipboard keeps no copy of the text.
@MainActor
public final class ConcealedClipboard {
    /// How long the item stays.
    public nonisolated static let lifetime: TimeInterval = 60
    /// The types every write declares.
    public nonisolated static let types: [PasteboardType] = [.string, .concealed]
    /// The options every write uses.
    public nonisolated static let options: PasteboardOptions = [.currentHostOnly]

    private struct Pending {
        let baseline: Int
        let deadline: Date
        let timer: any ClearTimer
    }

    private let pasteboard: any Pasteboard
    private let scheduler: any ClearScheduler
    private let now: () -> Date
    private var pending: Pending?

    public init(pasteboard: any Pasteboard, scheduler: any ClearScheduler, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.now = now
    }

    /// Whether a clear is scheduled.
    public var isPending: Bool { pending != nil }

    /// Writes `text` and schedules its clear.
    public func copy(_ text: String) {
        pending?.timer.cancel()
        pending = nil
        let baseline = pasteboard.write(text, types: Self.types, options: Self.options)
        arm(baseline: baseline, deadline: now().addingTimeInterval(Self.lifetime))
    }

    /// Clears now if the item is still ours, and cancels the timer.
    public func clearIfUnchanged() {
        guard let p = pending else { return }
        p.timer.cancel()
        finish(p)
    }

    /// Clears a join command a crashed or force-quit app left behind: only
    /// when the current item carries the concealed marker AND its string is
    /// exactly a line this app copies (`JoinCommandText.isJoinCommand`).
    /// Anything else, concealed or not, is left alone. Returns whether it
    /// cleared.
    @discardableResult
    public static func sweepLeftover(_ pasteboard: any Pasteboard) -> Bool {
        guard pasteboard.types.contains(.concealed), let text = pasteboard.string(),
              JoinCommandText.isJoinCommand(text)
        else { return false }
        pasteboard.clearContents()
        return true
    }

    private func arm(baseline: Int, deadline: Date) {
        let timer = scheduler.schedule(at: deadline) { [weak self] in self?.fire() }
        pending = Pending(baseline: baseline, deadline: deadline, timer: timer)
    }

    /// The timer fired. A fire before the deadline re-arms; at or after it,
    /// the item is cleared if unchanged.
    private func fire() {
        guard let p = pending else { return }
        if now() < p.deadline {
            arm(baseline: p.baseline, deadline: p.deadline)
            return
        }
        finish(p)
    }

    private func finish(_ p: Pending) {
        pending = nil
        if pasteboard.changeCount == p.baseline {
            pasteboard.clearContents()
        }
    }
}
