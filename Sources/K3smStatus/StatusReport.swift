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
    /// The command the CLI suggests for this row, "" when it names none. A
    /// missing or mistyped field reads as "".
    public let remedy: String
    /// The row's informational `wide` map, string values only: a key whose
    /// value is not a string is dropped, and a missing or mistyped map reads
    /// as empty. Every value is untrusted data.
    public let wide: [String: String]

    public init(name: String, state: String, detail: String, remedy: String = "", wide: [String: String] = [:]) {
        self.name = name
        self.state = state
        self.detail = detail
        self.remedy = remedy
        self.wide = wide
    }

    private enum CodingKeys: String, CodingKey { case name, state, detail, remedy, wide }

    /// Any key of the `wide` map.
    private struct WideKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decode(String.self, forKey: .state)
        detail = try c.decode(String.self, forKey: .detail)
        remedy = (try? c.decodeIfPresent(String.self, forKey: .remedy)) ?? ""
        var wide: [String: String] = [:]
        if let w = try? c.nestedContainer(keyedBy: WideKey.self, forKey: .wide) {
            for key in w.allKeys {
                if let value = try? w.decode(String.self, forKey: key) { wide[key.stringValue] = value }
            }
        }
        self.wide = wide
    }

    /// The row's state word, read as what the app does with it.
    public var rowState: RowState { RowState(word: state) }
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

/// StatusWorker is one other node of the cluster, from the additive `workers`
/// list a server prints. `version` is the node's kubelet version as printed
/// (`v1.36.2+k3sm.0.1.7`), nil while the node has reported none or the field is
/// not a string. It is the node's own advisory report, not an attestation.
public struct StatusWorker: Equatable, Sendable {
    public let name: String
    public let role: String
    public let version: String?

    public init(name: String, role: String, version: String? = nil) {
        self.name = name
        self.role = role
        self.version = version
    }

    /// The k3sm release inside the kubelet version: the semver build metadata
    /// after `+k3sm.` (`v1.36.2+k3sm.0.1.7` is `0.1.7`). The Kubernetes
    /// version before the `+` is not the k3sm release and is never compared.
    /// Nil when there is no version, no `+k3sm.` marker, or the release does
    /// not parse: unknown never satisfies a minimum.
    public var k3smRelease: SemanticVersion? {
        guard let version, let marker = version.range(of: "+k3sm.") else { return nil }
        return SemanticVersion(String(version[marker.upperBound...]))
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
    /// On a server, the cluster's other nodes. Nil means unknown (the field
    /// is absent, or not a list of named nodes): never read it as "no
    /// workers". An empty array means the server found there are none.
    public let workers: [StatusWorker]?
    /// On a worker, the `host:port` of the server it joined; nil when absent
    /// or not a string. Shown data only: it passes `ServerAddress` before use.
    public let joinTarget: String?
    /// This Mac's LAN access switch. An absent field reads as on with no
    /// setting recorded (`LANAccess.absentField`); a field that is not an
    /// object is unknown. Both the full report and the daemons probe carry it;
    /// only the full report carries the daemon's applied state.
    public let network: LANAccess
    /// The cluster's interconnect, present only when the cluster has an
    /// Interconnect the report could read; nil when absent or not an object.
    public let interconnect: StatusInterconnect?

    public init(
        schemaVersion: Int, verdict: Verdict, role: String, summary: String, rows: [StatusRow],
        stoppedBy: StoppedBy? = nil, workers: [StatusWorker]? = nil, joinTarget: String? = nil,
        network: LANAccess = .absentField, interconnect: StatusInterconnect? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.verdict = verdict
        self.role = role
        self.summary = summary
        self.rows = rows
        self.stoppedBy = stoppedBy
        self.workers = workers
        self.joinTarget = joinTarget
        self.network = network
        self.interconnect = interconnect
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, verdict, role, summary, rows, daemons, stoppedBy, workers, joinTarget, network, interconnect
    }

    /// The wire shape of one worker; a node without a string name makes the
    /// whole list unknown, a mistyped role or version reads as absent.
    private struct WireWorker: Decodable {
        let name: String
        let role: String
        let version: String?

        enum CodingKeys: String, CodingKey { case name, role, version }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
            let v = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
            version = v?.isEmpty == false ? v : nil
        }
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
        workers = ((try? c.decodeIfPresent([WireWorker].self, forKey: .workers)) ?? nil)?
            .map { StatusWorker(name: $0.name, role: $0.role, version: $0.version) }
        joinTarget = (try? c.decodeIfPresent(String.self, forKey: .joinTarget)) ?? nil
        if c.contains(.network) {
            network = (try? c.decode(LANAccess.self, forKey: .network)) ?? .unreadableField
        } else {
            network = .absentField
        }
        interconnect = (try? c.decodeIfPresent(StatusInterconnect.self, forKey: .interconnect)) ?? nil
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
