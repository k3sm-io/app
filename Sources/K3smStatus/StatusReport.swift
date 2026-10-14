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

/// Verdict is the one-word answer `k3sm status` leads with. The words are the
/// CLI's stable vocabulary; a word this build does not know decodes as
/// `unrecognized` rather than failing the whole report.
public enum Verdict: Equatable, Sendable {
    case running
    case degraded
    case stopped
    case notInstalled
    case unknown
    case unrecognized(String)

    /// Creates a verdict from the CLI's wire word.
    public init(word: String) {
        switch word {
        case "running": self = .running
        case "degraded": self = .degraded
        case "stopped": self = .stopped
        case "not-installed": self = .notInstalled
        case "unknown": self = .unknown
        default: self = .unrecognized(word)
        }
    }

    /// The wire word, as the CLI prints it.
    public var word: String {
        switch self {
        case .running: return "running"
        case .degraded: return "degraded"
        case .stopped: return "stopped"
        case .notInstalled: return "not-installed"
        case .unknown: return "unknown"
        case .unrecognized(let w): return w
        }
    }
}

/// StatusRow is one subsystem line of the report. Only the fields the app
/// reads are decoded; everything else in the JSON is ignored.
public struct StatusRow: Decodable, Equatable, Sendable {
    public let name: String
    public let state: String
    public let detail: String

    public init(name: String, state: String, detail: String) {
        self.name = name
        self.state = state
        self.detail = detail
    }
}

/// StoppedBy is who stopped k3sm on this Mac, from the additive `stoppedBy`
/// object the CLI prints while a stop marker exists. Every field is data shown
/// verbatim; `at` stays the CLI's RFC 3339 text. It carries no verdict.
public struct StoppedBy: Decodable, Equatable, Sendable {
    /// "user" or "auto" today; any other word is kept as printed.
    public let actor: String
    public let reason: String
    public let at: String
    /// "stopping" (a stop left something behind) or "stopped".
    public let phase: String

    public init(actor: String, reason: String, at: String, phase: String) {
        self.actor = actor
        self.reason = reason
        self.at = at
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey { case actor, reason, at, phase }

    /// Decodes tolerantly: a missing or mistyped field reads as "".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actor = (try? c.decodeIfPresent(String.self, forKey: .actor)) ?? ""
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        phase = (try? c.decodeIfPresent(String.self, forKey: .phase)) ?? ""
    }

    /// The one line the window shows, for example
    /// `stopped by user: maintenance window`.
    public var line: String {
        let head = "\(phase.isEmpty ? "stopped" : phase) by \(actor.isEmpty ? "someone" : actor)"
        return reason.isEmpty ? head : head + ": " + reason
    }
}

/// StatusReport is the decoded output of `k3sm status -o json` (rows in
/// `rows`) or of the cheaper `k3sm status daemons -o json` probe (rows in
/// `daemons`). Both shapes carry the same top-level fields.
public struct StatusReport: Decodable, Equatable, Sendable {
    /// The contract version this decoder understands.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let verdict: Verdict
    public let role: String
    public let summary: String
    public let rows: [StatusRow]
    /// Who stopped k3sm, present only while the CLI reports a stop marker. A
    /// `stoppedBy` value that is not an object decodes as nil rather than
    /// failing the report.
    public let stoppedBy: StoppedBy?

    public init(schemaVersion: Int, verdict: Verdict, role: String, summary: String, rows: [StatusRow], stoppedBy: StoppedBy? = nil) {
        self.schemaVersion = schemaVersion
        self.verdict = verdict
        self.role = role
        self.summary = summary
        self.rows = rows
        self.stoppedBy = stoppedBy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, verdict, role, summary, rows, daemons, stoppedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        verdict = Verdict(word: try c.decode(String.self, forKey: .verdict))
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        if let r = try c.decodeIfPresent([StatusRow].self, forKey: .rows) {
            rows = r
        } else {
            rows = try c.decodeIfPresent([StatusRow].self, forKey: .daemons) ?? []
        }
        stoppedBy = (try? c.decodeIfPresent(StoppedBy.self, forKey: .stoppedBy)) ?? nil
    }

    /// Returns the row with the given name, if the report carries one.
    public func row(named name: String) -> StatusRow? {
        rows.first { $0.name == name }
    }

    /// Decodes a report from the CLI's standard output. It throws
    /// `StatusDecodeError` when the bytes are not a report this build can read.
    public static func decode(_ data: Data) throws -> StatusReport {
        let report: StatusReport
        do {
            report = try JSONDecoder().decode(StatusReport.self, from: data)
        } catch {
            throw StatusDecodeError.malformed
        }
        guard report.schemaVersion == supportedSchemaVersion else {
            throw StatusDecodeError.unsupportedSchema(report.schemaVersion)
        }
        return report
    }
}

/// StatusDecodeError says why a CLI output could not be read as a report.
public enum StatusDecodeError: Error, Equatable, Sendable {
    /// The output is not JSON, or lacks a required field.
    case malformed
    /// The output declares a contract version this build does not read.
    case unsupportedSchema(Int)
}
