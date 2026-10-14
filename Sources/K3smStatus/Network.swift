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

/// LANSetting is one value of this Mac's "Allow connections from other
/// devices" switch (`k3sm network lan`). Only the CLI's two words map to on
/// and off; anything else, a mistyped field included, is `unknown`, never off.
public enum LANSetting: Equatable, Sendable {
    case on
    case off
    case unknown

    /// Reads the CLI's wire word.
    public init(word: String) {
        switch word {
        case "on": self = .on
        case "off": self = .off
        default: self = .unknown
        }
    }

    /// The word the app shows.
    public var word: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        case .unknown: return "unknown"
        }
    }
}

/// LANRecordState is the CLI's `recordState` marker on the `network` object.
/// It is absent for a usable record, and `unreadable` when a record exists
/// but could not be used. Any other value is `unknown`, never `ok`.
public enum LANRecordState: Equatable, Sendable {
    case ok
    case unreadable
    case unknown

    /// Reads the CLI's wire word.
    public init(word: String) {
        self = word == "unreadable" ? .unreadable : .unknown
    }
}

/// LANApplied is the node daemon's own report of the LAN state it serves,
/// present in the status only when the caller could read it (root).
public struct LANApplied: Equatable, Sendable {
    public let setting: LANSetting
    /// The daemon's message when its last change was refused; "" otherwise.
    /// It is CLI text: shown only through `StatusDisplay.errorText`.
    public let error: String

    public init(setting: LANSetting, error: String = "") {
        self.setting = setting
        self.error = error
    }
}

/// LANAccess is the decoded `network` object of `k3sm status -o json`.
///
/// - An absent field (a k3sm from before the switch) reads as on with no
///   setting recorded, which is what that k3sm serves.
/// - A field that is present but not an object, or whose `lan` is not one of
///   the CLI's two words, is `unknown`.
public struct LANAccess: Equatable, Sendable {
    /// The recorded setting, the value the checkbox shows.
    public let setting: LANSetting
    /// False when no setting is recorded, which reads as on.
    public let recorded: Bool
    /// The listener families the switch controls on this node.
    public let covers: [String]
    /// The network-facing listeners the switch does not control; nil when
    /// the report did not say.
    public let alwaysOn: [String]?
    /// The daemon's applied report, when the caller could read it.
    public let applied: LANApplied?
    /// Whether the record could be used. `unreadable` comes with a setting
    /// of off (what the node daemon serves then) and `recorded` true.
    public let recordState: LANRecordState
    /// False when the daemon's applied report exists but the caller may not
    /// read it; nil when the report did not say (read, absent, or not looked
    /// at, as in the daemons probe).
    public let appliedReadable: Bool?
    /// Whether the report carried a `network` field at all.
    public let fieldPresent: Bool

    public init(setting: LANSetting, recorded: Bool, covers: [String] = [], alwaysOn: [String]? = nil,
                applied: LANApplied? = nil, recordState: LANRecordState = .ok, appliedReadable: Bool? = nil,
                fieldPresent: Bool = true) {
        self.setting = setting
        self.recorded = recorded
        self.covers = covers
        self.alwaysOn = alwaysOn
        self.applied = applied
        self.recordState = recordState
        self.appliedReadable = appliedReadable
        self.fieldPresent = fieldPresent
    }

    /// What a report with no `network` field means: on, nothing recorded.
    public static let absentField = LANAccess(setting: .on, recorded: false, fieldPresent: false)

    /// What a `network` field that is not an object means.
    public static let unreadableField = LANAccess(setting: .unknown, recorded: true, recordState: .unknown)
}

extension LANAccess: Decodable {
    private enum CodingKeys: String, CodingKey { case lan, recorded, recordState, covers, alwaysOn, applied, appliedReadable }
    private enum AppliedKeys: String, CodingKey { case lan, error }

    /// Decodes tolerantly: a missing or mistyped `lan` is unknown, a missing
    /// `recorded` is true (the value is taken as it is printed), mistyped
    /// lists are empty or unknown, and an applied report without a string
    /// `lan` is left out. An absent `recordState` is ok, `unreadable` is
    /// unreadable, and anything else, a mistyped value included, is unknown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let word = (try? c.decodeIfPresent(String.self, forKey: .lan)) ?? nil
        setting = word.map(LANSetting.init(word:)) ?? .unknown
        recorded = ((try? c.decodeIfPresent(Bool.self, forKey: .recorded)) ?? nil) ?? true
        covers = ((try? c.decodeIfPresent([String].self, forKey: .covers)) ?? nil) ?? []
        alwaysOn = (try? c.decodeIfPresent([String].self, forKey: .alwaysOn)) ?? nil
        if let a = try? c.nestedContainer(keyedBy: AppliedKeys.self, forKey: .applied),
           let lan = (try? a.decodeIfPresent(String.self, forKey: .lan)) ?? nil {
            let error = ((try? a.decodeIfPresent(String.self, forKey: .error)) ?? nil) ?? ""
            applied = LANApplied(setting: LANSetting(word: lan), error: error)
        } else {
            applied = nil
        }
        if c.contains(.recordState) {
            if let word = (try? c.decode(String.self, forKey: .recordState)) {
                recordState = LANRecordState(word: word)
            } else {
                recordState = .unknown
            }
        } else {
            recordState = .ok
        }
        appliedReadable = (try? c.decodeIfPresent(Bool.self, forKey: .appliedReadable)) ?? nil
        fieldPresent = true
    }
}

extension StatusReport {
    /// Whether this Mac's role has the LAN switch: an installed server or
    /// worker. Any other role, or no install, has none, and the app hides
    /// the checkbox.
    public var hasLANSwitch: Bool {
        verdict != .notInstalled && NodeRole.detect(in: self) != nil
    }
}
