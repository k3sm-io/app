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

/// StatusAlert is a row's `alert` object: what is wrong and how to fix it, as
/// `k3sm status -o json`, the daemons probe and `k3sm alerts -o json` print it
/// on every row that needs attention. It is the app's one decoding of the
/// object; the Alerts tab and any other reader share it. Every string is
/// untrusted data: it reaches the screen only through `StatusDisplay.clip`,
/// and a command reaches the pasteboard only when `AlertCommand.copyable`
/// passes. The app never runs a step.
///
/// Decoding is lenient so a newer or damaged alert never fails the report:
/// an `alert` that is not an object or has no string `cause` reads as nil
/// (`StatusRow.alert`), unknown fields are ignored, a missing or mistyped
/// `evidence` or `fix` reads as empty, an evidence entry that is not a string
/// is dropped, and a missing `docs` reads as "".
public struct StatusAlert: Decodable, Equatable, Sendable {
    /// One sentence: what is wrong, in plain words.
    public let cause: String
    /// The facts the check saw, the row's detail first.
    public let evidence: [String]
    /// The ordered steps that repair the row.
    public let fix: [StatusFixStep]
    /// The user documentation page and anchor, relative to the docs
    /// directory (`troubleshooting.md#checks-that-need-sudo`); "" when absent.
    public let docs: String
    /// When the condition began, RFC 3339 text as printed; nil when absent,
    /// empty or not a string.
    public let since: String?

    public init(cause: String, evidence: [String] = [], fix: [StatusFixStep] = [], docs: String = "", since: String? = nil) {
        self.cause = cause
        self.evidence = evidence
        self.fix = fix
        self.docs = docs
        self.since = since
    }

    private enum CodingKeys: String, CodingKey { case cause, evidence, fix, docs, since }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cause = try c.decode(String.self, forKey: .cause)
        evidence = ((try? c.decodeIfPresent([Lenient<String>].self, forKey: .evidence)) ?? nil)?.compactMap(\.value) ?? []
        fix = ((try? c.decodeIfPresent([Lenient<StatusFixStep>].self, forKey: .fix)) ?? nil)?.compactMap(\.value) ?? []
        docs = ((try? c.decodeIfPresent(String.self, forKey: .docs)) ?? nil) ?? ""
        let since = ((try? c.decodeIfPresent(String.self, forKey: .since)) ?? nil) ?? ""
        self.since = since.isEmpty ? nil : since
    }
}

/// StatusFixStep is one step of an alert's fix: what it does, the command
/// that does it (nil for a step done by hand), whether it needs an
/// administrator, and whether a person should confirm it before it runs (it
/// destroys state or relaxes trust). A step without a string `step` is
/// dropped from its alert. A missing or mistyped `needsAdmin` or `confirm`
/// reads as true, and the initializer defaults both to true: an unknown flag
/// is shown as the cautious mark, never hidden.
public struct StatusFixStep: Decodable, Equatable, Sendable {
    public let step: String
    public let command: String?
    public let needsAdmin: Bool
    public let confirm: Bool

    public init(step: String, command: String? = nil, needsAdmin: Bool = true, confirm: Bool = true) {
        self.step = step
        self.command = command
        self.needsAdmin = needsAdmin
        self.confirm = confirm
    }

    private enum CodingKeys: String, CodingKey { case step, command, needsAdmin, confirm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(String.self, forKey: .step)
        let command = ((try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil) ?? ""
        self.command = command.isEmpty ? nil : command
        needsAdmin = ((try? c.decodeIfPresent(Bool.self, forKey: .needsAdmin)) ?? nil) ?? true
        confirm = ((try? c.decodeIfPresent(Bool.self, forKey: .confirm)) ?? nil) ?? true
    }
}

/// AlertsReport is the decoded output of `k3sm alerts -o json`: the full
/// report's verdict, role and summary, the node this Mac runs as, and only
/// the rows that carry an alert, each in the `StatusRow` shape. The app does
/// not read it yet; it is here so every reader shares one decoding.
public struct AlertsReport: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let verdict: Verdict
    public let role: String
    public let summary: String
    /// The Kubernetes node or short host name; nil when absent or not a string.
    public let node: String?
    /// The rows that need attention, in the full report's order. A missing
    /// list reads as empty.
    public let alerts: [StatusRow]
    /// The build that printed the report; nil when absent or malformed.
    public let release: StatusRelease?
    /// The RFC 3339 `timestamp` text as printed; "" when missing.
    public let timestamp: String

    public init(schemaVersion: Int, verdict: Verdict, role: String, summary: String, node: String? = nil,
                alerts: [StatusRow], release: StatusRelease? = nil, timestamp: String = "") {
        self.schemaVersion = schemaVersion
        self.verdict = verdict
        self.role = role
        self.summary = summary
        self.node = node
        self.alerts = alerts
        self.release = release
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, verdict, role, summary, node, alerts, timestamp
        case release = "version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        verdict = Verdict(word: try c.decode(String.self, forKey: .verdict))
        role = ((try? c.decodeIfPresent(String.self, forKey: .role)) ?? nil) ?? ""
        summary = ((try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil) ?? ""
        node = (try? c.decodeIfPresent(String.self, forKey: .node)) ?? nil
        alerts = try c.decodeIfPresent([StatusRow].self, forKey: .alerts) ?? []
        release = (try? c.decodeIfPresent(StatusRelease.self, forKey: .release)) ?? nil
        timestamp = ((try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? nil) ?? ""
    }

    /// Decodes `k3sm alerts -o json` output. It throws `StatusDecodeError`
    /// when the bytes are not a report this build can read.
    public static func decode(_ data: Data) throws -> AlertsReport {
        let report: AlertsReport
        do {
            report = try JSONDecoder().decode(AlertsReport.self, from: data)
        } catch {
            throw StatusDecodeError.malformed
        }
        guard report.schemaVersion == StatusReport.supportedSchemaVersion else {
            throw StatusDecodeError.unsupportedSchema(report.schemaVersion)
        }
        return report
    }
}

/// One list entry decoded as `T`, or nil when it is not one, so a single bad
/// entry drops only itself.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// AlertCommand decides whether a command may be copied: a fix step's, and
/// a legacy remedy or `next` line's (`RemedyStep`), the one rule for every
/// pasteboard write. The pasteboard gets exactly the producer's text or
/// nothing: a command is copyable only when it is non-blank, at most
/// `maxBytes` bytes, and every character is printable ASCII (space through
/// `~`), so no control, separator, bidirectional, zero-width or other
/// format character, and no homoglyph or fullwidth letter, can make the
/// pasted command differ from the one read; and `StatusDisplay.oneLine`
/// leaves it unchanged. Anything else is shown clipped, as text, with no Copy.
public enum AlertCommand {
    /// The longest command that may be copied, in UTF-8 bytes.
    public static let maxBytes = 1024

    /// Whether `command` may be put on the pasteboard as written.
    public static func copyable(_ command: String) -> Bool {
        guard !command.isEmpty, command.utf8.count <= maxBytes,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard command.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return false }
        return StatusDisplay.oneLine(command) == command
    }
}

/// AlertDocs turns an alert's `docs` into the k3sm site's page for it. Only
/// a page name and an optional anchor of lowercase letters, digits and
/// hyphens (`^[a-z0-9-]+\.md(#[a-z0-9-]+)?$`) gives a link, joined to
/// `siteBase` the way the site publishes its user docs (`page.md#anchor` is
/// `<siteBase>page/#anchor`); anything else, a URL, a path or a scheme
/// included, gives none.
public enum AlertDocs {
    /// The k3sm site's user documentation.
    public static let siteBase = "https://k3sm.io/docs/"
    /// The longest `docs` value read.
    static let maxLength = 200

    /// The site page for `docs`, nil when it is not a plain page reference.
    public static func url(_ docs: String) -> URL? {
        guard !docs.isEmpty, docs.utf8.count <= maxLength else { return nil }
        let parts = docs.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = parts[0]
        guard file.hasSuffix(".md") else { return nil }
        let page = file.dropLast(3)
        guard plain(page) else { return nil }
        var text = siteBase + page + "/"
        if parts.count == 2 {
            guard plain(parts[1]) else { return nil }
            text += "#" + parts[1]
        }
        return URL(string: text)
    }

    /// Whether `text` is one or more of `a`-`z`, `0`-`9` and `-`.
    static func plain(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }
}
