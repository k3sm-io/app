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

/// UpdateSignaturePolicy is the code-signature policy `k3sm update apply
/// --signature` takes, the CLI's two words. `ifSigned` (the CLI's default)
/// matches the new release to the installed build: a Developer ID signed
/// install takes only a release signed by the same team. `required` takes
/// only a Developer ID signed release, whatever is installed. The release's
/// checksum is verified under either.
public enum UpdateSignaturePolicy: String, CaseIterable, Sendable {
    case ifSigned = "if-signed"
    case required

    /// The Updates pane's popup item.
    public var title: String {
        switch self {
        case .ifSigned: "Same signer as the installed k3sm"
        case .required: "Developer ID signature required"
        }
    }
}

/// UpdateOptions is how one managed update runs: drain each node before it
/// updates, allow a release older than a node runs, and the signature
/// policy. Drain and the policy are the app's own preferences, read once
/// when Update is clicked; allowing a downgrade is never stored, and is
/// chosen in the confirmation for that apply only. The confirmation names
/// every option that is not the default (`confirmationLines`), and the run
/// passes exactly the options confirmed to `k3sm update apply` as its own
/// flags, from a fixed vocabulary: nothing typed reaches the command line.
/// The defaults add no flag, so they run the CLI's defaults.
public struct UpdateOptions: Equatable, Sendable {
    public var drain: Bool
    public var allowDowngrade: Bool
    public var signature: UpdateSignaturePolicy

    public static let defaults = UpdateOptions(drain: false, allowDowngrade: false, signature: .ifSigned)

    /// The confirmation's checkbox for a downgrade, and its line once on.
    public static let downgradeTitle = "Allow a release older than a node runs"
    public static let drainLine = "Each node's pods are drained before it updates."
    public static let signatureRequiredLine = "Only a release with a Developer ID signature is accepted."
    public static let downgradeLine = "A node may move to an older release."
    /// The note under the pane's options.
    public static let paneNote =
        "Update names these before it starts, and asks about an older release only when a node runs a newer one. The release's checksum is always verified."

    public init(drain: Bool, allowDowngrade: Bool, signature: UpdateSignaturePolicy) {
        self.drain = drain
        self.allowDowngrade = allowDowngrade
        self.signature = signature
    }

    /// The argv after the CLI path: `K3smCLI.updateApplyArguments` and the
    /// flags `cmd/k3sm/update.go` defines for what differs from its defaults.
    public var arguments: [String] {
        var argv = K3smCLI.updateApplyArguments
        if drain { argv.append("--drain") }
        if allowDowngrade { argv.append("--allow-downgrade") }
        if signature != .ifSigned { argv += ["--signature", signature.rawValue] }
        return argv
    }

    /// One sentence for each option that is not the default, in argv order;
    /// empty for the defaults.
    public var confirmationLines: [String] {
        var lines: [String] = []
        if drain { lines.append(Self.drainLine) }
        if allowDowngrade { lines.append(Self.downgradeLine) }
        if signature == .required { lines.append(Self.signatureRequiredLine) }
        return lines
    }
}

extension UpdateOffer {
    /// The part of a `behind` row's detail that names the nodes running a
    /// release newer than the latest (`k3sm` `pkg/status/update.go`,
    /// `UpdateRowFrom`): "...; newer than the latest release: b (v0.2.0)".
    public static let newerNodesMarker = "; newer than the latest release: "

    /// Whether `--allow-downgrade` could change what the apply does: the
    /// live row is `behind` and names a node newer than the latest release,
    /// which the roll would otherwise refuse to move back.
    public static func offersDowngrade(in report: StatusReport?) -> Bool {
        guard let row = report?.row(named: "update"), row.rowState == .behind else { return false }
        return row.detail.contains(newerNodesMarker)
    }
}

/// UpdatesPaneFacts is what the Settings Updates pane says about releases,
/// from the last full report's `update` row and the installed `k3sm
/// version`: the installed release, the available one, and the row's state
/// in plain words. A tag reaches the pane only when it parses as a release
/// (`UpdateOffer.latestTag`); every other row string is clipped.
public struct UpdatesPaneFacts: Equatable, Sendable {
    /// "v0.1.8", or "unknown".
    public let installed: String
    /// The newest release the check found (the roll's target while one
    /// rolls), or "not known".
    public let available: String
    /// One sentence.
    public let state: String

    public static let unknownVersion = "unknown"
    public static let notKnown = "not known"

    public init(installed: String, available: String, state: String) {
        self.installed = installed
        self.available = available
        self.state = state
    }

    public static func decide(report: StatusReport?, installed: SemanticVersion?) -> UpdatesPaneFacts {
        let installedText = installed.map { "v" + $0.description } ?? unknownVersion
        guard let report else {
            return UpdatesPaneFacts(installed: installedText, available: notKnown,
                                    state: "The status of this Mac has not been read yet.")
        }
        guard let row = report.row(named: "update") else {
            return UpdatesPaneFacts(installed: installedText, available: notKnown, state: "This k3sm reports no update check.")
        }
        let latest = UpdateOffer.latestTag(in: row)
        let target = row.wide["target"].flatMap { UpdateOffer.valid($0) ? $0 : nil }
        let state: String
        var available = latest
        switch row.rowState {
        case .behind:
            state = latest.map { "k3sm \($0) is available; at least one node runs an older release." }
                ?? "A newer release is available; at least one node runs an older release."
        case .ahead:
            state = "A node runs a release newer than the latest one."
        case .rolling:
            state = target.map { "An update to \($0) is rolling." } ?? "An update is rolling."
            available = target ?? latest
        case .healthy:
            state = "This cluster runs the latest release."
        case .unknown(let word) where word == "unknown":
            state = sentence("Not known: " + StatusDisplay.clip(row.detail))
        default:
            state = sentence("The update check says " + StatusDisplay.clip(row.state) + ": " + StatusDisplay.clip(row.detail))
        }
        return UpdatesPaneFacts(installed: installedText, available: available ?? notKnown, state: state)
    }

    /// `text` with a closing period, clipped.
    private static func sentence(_ text: String) -> String {
        let clipped = StatusDisplay.clip(text)
        return clipped.hasSuffix(".") ? clipped : clipped + "."
    }
}

/// UpdateNowControl is the Updates pane's Update Now button: enabled only
/// while `UpdateOffer` offers the update and nothing blocks it; otherwise
/// disabled, with the reason its help tag carries.
public struct UpdateNowControl: Equatable, Sendable {
    public static let title = "Update Now"

    public let enabled: Bool
    public let reason: String?

    public static let latestReason = "Every node already runs the latest release."
    public static let aheadReason = "No release is newer than the one this cluster runs."
    public static let unknownReason = "k3sm has not reported a newer release."
    public static let finishedReason = "The update to this release has just finished."

    public init(enabled: Bool, reason: String?) {
        self.enabled = enabled
        self.reason = reason
    }

    public static func decide(offer: UpdateOffer, report: StatusReport?) -> UpdateNowControl {
        switch offer {
        case .available(_, let reason):
            return UpdateNowControl(enabled: reason == nil, reason: reason)
        case .updating:
            return UpdateNowControl(enabled: false, reason: offer.disabledReason)
        case .hidden:
            let reason: String
            switch report?.row(named: "update")?.rowState {
            case .healthy?: reason = latestReason
            case .ahead?: reason = aheadReason
            case .behind? where report?.row(named: "update").flatMap(UpdateOffer.latestTag(in:)) != nil:
                reason = finishedReason
            default: reason = unknownReason
            }
            return UpdateNowControl(enabled: false, reason: reason)
        }
    }
}
