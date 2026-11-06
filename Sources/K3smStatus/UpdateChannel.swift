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

/// UpdateChannel is a release channel the app knows, the two words of the
/// cluster's `UpdatePolicy`: `stable` offers tagged finals, and `rc` also offers
/// release candidates. A channel changes what is offered and never starts a roll.
public enum UpdateChannel: String, CaseIterable, Equatable, Sendable {
    case stable
    case rc
}

/// UpdateChannelReading is what the report's `update` row says about the channel,
/// from `wide.channel`. The cluster is the one source: the app stores no channel.
/// `absent` is no report, no row, no usable field (a k3sm from before channels), or a
/// row with no result to name one for. `unknown` is any other word, matched exactly,
/// so a value this app does not know never reads as a real channel. Both behave as
/// `stable`. The unknown word is not kept, so it cannot reach a screen.
public enum UpdateChannelReading: Equatable, Sendable {
    case absent
    case known(UpdateChannel)
    case unknown

    /// The line an unknown channel adds, naming why this reads as stable.
    public static let unknownNote = "The server's channel could not be read, so this reads as stable."

    public init(report: StatusReport?) {
        guard let word = report?.row(named: "update")?.wide["channel"], !word.isEmpty else {
            self = .absent
            return
        }
        self = UpdateChannel(rawValue: word).map(Self.known) ?? .unknown
    }

    /// The channel this reading behaves as: only `rc` reads as `rc`.
    public var channel: UpdateChannel {
        if case .known(let channel) = self { return channel }
        return .stable
    }

    /// The channel's word for a reader of the app's output; nil when none is
    /// reported, and the word it behaves as when it is unknown (`note` says so).
    public var word: String? {
        self == .absent ? nil : channel.rawValue
    }

    /// Why the channel shown is not the one reported; nil when it is.
    public var note: String? {
        self == .unknown ? Self.unknownNote : nil
    }
}

/// UpdateChannelPicker is the state of the Updates pane's channel picker: what it
/// selects, the value the report gives, and whether it can be changed, with the reason
/// its help tag carries when it cannot. A lasting reason comes before a passing one, so
/// the reason given is the one that will still hold when the other clears. An unknown
/// channel is not offered for change: it comes from a k3sm newer than this app, whose
/// setting this app should not overwrite without knowing what it means.
public struct UpdateChannelPicker: Equatable, Sendable {
    public static let noClusterReason = "No cluster is running, so there is no channel to set."
    public static let workerReason = "The channel is set on the server."
    public static let noChannelReason = "This k3sm has not reported a channel, so the app treats it as stable."
    public static let unknownChannelReason = "This k3sm reports a channel this app does not know, so it reads as stable."
    public static let rollingReason = "The channel can change once this update finishes."

    public let selection: UpdateChannel
    public let enabled: Bool
    public let reason: String?

    public init(selection: UpdateChannel, enabled: Bool, reason: String?) {
        self.selection = selection
        self.enabled = enabled
        self.reason = reason
    }

    public static func decide(report: StatusReport?, progress: UpdateProgress, developerBuild: Bool) -> UpdateChannelPicker {
        let reading = UpdateChannelReading(report: report)
        let disabled = { (reason: String) in
            UpdateChannelPicker(selection: reading.channel, enabled: false, reason: reason)
        }
        guard let report, report.verdict == .running || report.verdict == .degraded,
              let role = NodeRole.detect(in: report) else { return disabled(noClusterReason) }
        if developerBuild { return disabled(UpdateOffer.developerBuildReason) }
        if role == .agent { return disabled(workerReason) }
        switch reading {
        case .absent: return disabled(noChannelReason)
        case .unknown: return disabled(unknownChannelReason)
        case .known: break
        }
        if progress.isRolling || UpdateOffer.rowRolling(in: report) { return disabled(rollingReason) }
        return UpdateChannelPicker(selection: reading.channel, enabled: true, reason: nil)
    }
}

extension SemanticVersion {
    /// Whether this is a release candidate, `-rc.N`. A Go pseudo-version and any
    /// other pre-release are not.
    public var isReleaseCandidate: Bool {
        prerelease.count == 2 && prerelease[0] == "rc" && !prerelease[1].isEmpty && prerelease[1].allSatisfy(\.isASCIIDigit)
    }
}
