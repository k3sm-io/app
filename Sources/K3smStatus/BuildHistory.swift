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

/// BuildRecordID is a build's record id as `k3sm build ls` prints it: exactly
/// twelve lowercase hexadecimal characters, the shape the CLI's ledger gives
/// every record and accepts back. Only a value this guard admits reaches an
/// argument list, so a record id can never carry an option, a path or a
/// second argument.
public struct BuildRecordID: Hashable, Sendable {
    public static let length = 12
    public let value: String

    public init?(_ raw: String) {
        let scalars = raw.unicodeScalars
        guard scalars.count == Self.length,
              scalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        value = raw
    }
}

/// BuildStatus is where a recorded build stands, in the ledger's words. A
/// word the app does not know is kept as printed (clipped) and is neither
/// running nor finished, so it offers no action that depends on either.
public enum BuildStatus: Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case other(String)

    public init(_ word: String) {
        switch word {
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .other(StatusDisplay.clip(word))
        }
    }

    /// The word the row shows.
    public var word: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .other(let w): return w.isEmpty ? "Unknown" : w
        }
    }

    /// The severity word the row colours its dot by, as `PodHealth`.
    public var severity: String {
        switch self {
        case .running: return "warn"
        case .succeeded: return "ok"
        case .failed: return "bad"
        case .cancelled, .other: return "off"
        }
    }

    /// Whether the build has finished: succeeded, failed or cancelled.
    public var finished: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .running, .other: return false
        }
    }
}

/// BuildRecord is one build of the history as the Builds tab lists it.
/// Every string is clipped; the times are as the ledger recorded them.
public struct BuildRecord: Equatable, Sendable {
    /// The record id as printed, clipped: the row's selection key.
    public let key: String
    /// The id when `BuildRecordID` admits it; nil rows offer no action.
    public let id: BuildRecordID?
    /// The image tag the build was asked for, "" when the record has none.
    public let tag: String
    public let status: BuildStatus
    public let platform: String
    /// "native" or "engine", as the ledger words it.
    public let engine: String
    public let context: String
    public let dockerfile: String
    public let startedAt: Date?
    public let finishedAt: Date?
    /// The cluster-registry reference the build recorded its image under
    /// ("registry-k3sm:6450/myapp:dev"), clipped; set on success.
    public let reference: String?
    /// The reference's row key in the registry's image list
    /// (`ImagesList.rowKey`, as `RegistryImages` keys its rows); nil
    /// without a reference.
    public let imageKey: String?
    /// The digest of the image the build recorded, set on success.
    public let digest: String?
    /// The failure's text, set on failure.
    public let error: String?

    /// How long the build ran, up to `now` while it runs; nil without a start.
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        if let finishedAt { return max(0, finishedAt.timeIntervalSince(startedAt)) }
        return status == .running ? max(0, now.timeIntervalSince(startedAt)) : nil
    }

    /// The name the row and the inspector show.
    public var title: String { tag.isEmpty ? "untagged" : tag }
}

/// BuildHistory decodes `K3smCLI.buildHistoryArguments`, the invoking user's
/// build ledger (`k3sm build ls -o json`, a JSON array of records), and
/// formats its times for the Builds tab.
public enum BuildHistory {
    /// The tab's line when no build has been recorded.
    public static let emptyText = "No builds recorded. Every k3sm build is listed here when it starts."

    /// The records, newest first. A record without an id is skipped, and of
    /// two records with the same id only the first is kept, so every key is
    /// unique. It throws `BuildHistoryDecodeError` when the bytes are not an
    /// array of records.
    public static func decode(_ data: Data) throws -> [BuildRecord] {
        guard let top = try? JSONSerialization.jsonObject(with: data) else { throw BuildHistoryDecodeError.malformed }
        guard let items = top as? [Any] else { throw BuildHistoryDecodeError.notAnArray }
        var seen = Set<String>()
        var records: [(Int, BuildRecord)] = []
        for (index, item) in items.enumerated() {
            guard let object = item as? [String: Any], let raw = object["id"] as? String, !raw.isEmpty else { continue }
            let key = StatusDisplay.clip(raw)
            guard seen.insert(key).inserted else { continue }
            let string = { (name: String) in StatusDisplay.clip(object[name] as? String ?? "") }
            let optional = { (name: String) -> String? in
                (object[name] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            records.append((index, BuildRecord(
                key: key,
                id: BuildRecordID(raw),
                tag: string("tag"),
                status: BuildStatus(object["status"] as? String ?? ""),
                platform: string("platform"),
                engine: string("engine"),
                context: string("context"),
                dockerfile: string("dockerfile"),
                startedAt: (object["startedAt"] as? String).flatMap(timestamp),
                finishedAt: (object["finishedAt"] as? String).flatMap(timestamp),
                reference: optional("reference").map(StatusDisplay.clip),
                imageKey: optional("reference").map(ImagesList.rowKey),
                digest: optional("imageDigest").map(StatusDisplay.clip),
                error: optional("error").map(StatusDisplay.errorText))))
        }
        // Newest first by start; a record without one sorts last; ties keep
        // the ledger's own order.
        return records.sorted { a, b in
            switch (a.1.startedAt, b.1.startedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0 < b.0
            }
        }.map(\.1)
    }

    /// One history run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<[BuildRecord]> {
        guard exitCode == 0 else { return .failed("k3sm build ls exited \(exitCode)") }
        do {
            return .value(try decode(stdout))
        } catch {
            return .failed("the build history could not be read")
        }
    }

    /// An RFC 3339 time as Go's encoder writes it: seconds, an optional
    /// fraction of up to nine digits, and `Z` or a `±hh:mm` offset.
    public static func timestamp(_ text: String) -> Date? {
        let scalars = Array(text.unicodeScalars)
        // "yyyy-MM-ddTHH:mm:ss" is 19 characters; the fraction follows it.
        guard scalars.count >= 20 else { return nil }
        var fraction = ""
        var rest = scalars[19...]
        if rest.first == "." {
            rest = rest.dropFirst()
            while let c = rest.first, ("0"..."9").contains(c) {
                fraction.unicodeScalars.append(c)
                rest = rest.dropFirst()
            }
            guard !fraction.isEmpty, fraction.count <= 9 else { return nil }
        }
        var base = String.UnicodeScalarView()
        base.append(contentsOf: scalars[..<19])
        base.append(contentsOf: rest)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: String(base)) else { return nil }
        return whole.addingTimeInterval(fraction.isEmpty ? 0 : Double("0." + fraction) ?? 0)
    }

    /// A build's duration: "42s", "3m 05s", "1h 02m"; "" when unknown.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let s = Int(seconds.rounded(.down))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return String(format: "%dm %02ds", s / 60, s % 60)
        default: return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
        }
    }

    /// When a build started, in `timeZone`: "2026-10-16 09:41:07"; "" when unknown.
    public static func started(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// BuildImageLink is where a build record's Show in Images leads, decided
/// by `BuildHistory.imageLink(_:in:)`.
public enum BuildImageLink: Equatable, Sendable {
    /// The registry lists the build's image: the Images row key to select.
    case listed(String)
    /// The registry no longer holds the image the build recorded: its
    /// reference is not listed, or now names another digest.
    case gone
    /// The registry's list has not been read, or the registry could not be
    /// reached, so nothing can be said about the image.
    case unread

    /// The line the control shows instead of selecting; nil when it selects.
    public var note: String? {
        switch self {
        case .listed: return nil
        case .gone: return BuildHistory.imageGoneText
        case .unread: return BuildHistory.imageUnreadText
        }
    }
}

extension BuildHistory {
    /// The line when a build's image is no longer in the registry.
    public static let imageGoneText = "This build's image is no longer in the cluster's registry."
    /// The line when the registry's list could not be read.
    public static let imageUnreadText = "The registry's image list could not be read, so the image was not found."

    /// Where `record`'s Show in Images leads in `list`, the registry's last
    /// read: its row when the registry lists the record's reference with the
    /// digest the build recorded (either digest unreported counts as the
    /// same), `.gone` when it does not, `.unread` without a read of a
    /// reachable registry, and nil when the record names no image, so the
    /// row offers no control.
    public static func imageLink(_ record: BuildRecord, in list: RegistryImageList?) -> BuildImageLink? {
        guard let key = record.imageKey else { return nil }
        guard let list, list.reachable else { return .unread }
        guard let image = list.images.first(where: { $0.key == key }) else { return .gone }
        if let built = record.digest, let held = image.digest, built != held { return .gone }
        return .listed(image.key)
    }
}

/// BuildHistoryDecodeError says why the history could not be read.
public enum BuildHistoryDecodeError: Error, Equatable, Sendable {
    case malformed
    case notAnArray
}
