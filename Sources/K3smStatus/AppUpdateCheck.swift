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

/// AppIndexFacts is what the app's update check keeps from a release index
/// the verifier accepted: the tag, the index's own `issuedAt`, the signing
/// time the timestamp authority attested, and whether this Mac's macOS runs
/// the release. The index itself stays in memory for this process only.
public struct AppIndexFacts: Equatable, Sendable {
    /// The final release tag, `vMAJOR.MINOR.PATCH`.
    public let tag: String
    /// `ReleaseIndex.issuedDate`.
    public let issuedAt: Date
    /// The attested signing time (`ReleaseIndexVerifier.VerifiedReleaseIndex.signedAt`).
    public let signedAt: Date
    /// `ReleaseIndex.supports(macOS:)` for this Mac.
    public let macOS: ReleaseIndex.MacOSSupport

    public init(tag: String, issuedAt: Date, signedAt: Date, macOS: ReleaseIndex.MacOSSupport) {
        self.tag = tag
        self.issuedAt = issuedAt
        self.signedAt = signedAt
        self.macOS = macOS
    }

    /// The facts of a verified index, judged for a Mac on `macOS`.
    public init(index: ReleaseIndex, signedAt: Date, macOS: OperatingSystemVersion) {
        self.init(tag: index.tag, issuedAt: index.issuedDate, signedAt: signedAt, macOS: index.supports(macOS: macOS))
    }
}

/// AppIndexHighWater is the highest `(tag, issuedAt)` pair the update check
/// has accepted, the floor an older index is refused below. It is the only
/// thing the check stores about an index (`AppPreferences.storeHighWater`).
public struct AppIndexHighWater: Equatable, Sendable {
    /// A final release tag, `vMAJOR.MINOR.PATCH`.
    public let tag: String
    /// The tag as a version.
    public let version: SemanticVersion
    /// The accepted index's `issuedAt`.
    public let issuedAt: Date

    /// A pair whose tag is a final release tag (`ReleaseIndex.isFinalTag`)
    /// and whose date is finite; nil for anything else.
    public init?(tag: String, issuedAt: Date) {
        guard ReleaseIndex.isFinalTag(tag), let version = SemanticVersion(tag), version.prerelease.isEmpty,
              issuedAt.timeIntervalSince1970.isFinite
        else { return nil }
        self.tag = tag
        self.version = version
        self.issuedAt = issuedAt
    }

    /// Whether `version` and `issuedAt` sort below this pair: a lower
    /// release, or the same release with an older `issuedAt`.
    public func isAbove(version other: SemanticVersion, issuedAt otherIssued: Date) -> Bool {
        other < version || (other == version && otherIssued < issuedAt)
    }
}

/// StoredHighWater is the high-water pair as the preferences domain holds
/// it: nothing, a valid pair, or something else (another type, a tag that is
/// not a final release, one key without the other), which the check treats
/// as absent and logs.
public enum StoredHighWater: Equatable, Sendable {
    case absent
    case garbage
    case stored(AppIndexHighWater)

    /// The pair, or nil for `.absent` and `.garbage` alike.
    public var pair: AppIndexHighWater? {
        if case .stored(let pair) = self { return pair }
        return nil
    }
}

/// AppUpdateAcceptance is the check a verified release index passes before
/// the app believes it, beyond its signature: the index's `issuedAt` is no
/// later than the attested signing time plus `maxIssuedAfterSigning`, and the
/// index is not older than the highest one already accepted. An index below
/// the running bundle's own sealed tag is not newer and is never stored, so
/// the stored mark never falls behind the running bundle. The signing time
/// is the timestamp authority's, never this Mac's clock.
public enum AppUpdateAcceptance {
    /// How far the index's own `issuedAt` may run past the attested signing
    /// time: ten minutes, room for a release host's clock drift between
    /// writing the index and signing it. `--verify-index` at release time
    /// holds the same bound, so a release host with a wrong clock fails there.
    public static let maxIssuedAfterSigning: TimeInterval = 600

    /// Why an index was not accepted.
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        /// `issuedAt` is later than the signing time allows (by how many seconds).
        case issuedAfterSigning(seconds: Int)
        /// The tag is not a final release tag.
        case tag
        /// A lower release than one already accepted (that release).
        case olderRelease(accepted: String)
        /// The same release as the one accepted, with an older `issuedAt`.
        case olderIndex

        public var description: String {
            switch self {
            case .issuedAfterSigning(let s): "the index is dated \(s) seconds after its signature"
            case .tag: "the index does not name a final release"
            case .olderRelease(let tag): "the index names an older release than \(StatusDisplay.clip(tag)), already seen"
            case .olderIndex: "the index is older than one already seen for the same release"
            }
        }
    }

    /// The verdict: the pair to store, or why not.
    public enum Verdict: Equatable, Sendable {
        /// Accepted; the pair is the new high-water mark (the stored one,
        /// unchanged, when the index is the same one fetched again).
        case accepted(AppIndexHighWater)
        /// Verified and not a replay of the stored mark, but below the
        /// running bundle's own tag: not newer, so it is shown as "this build
        /// is newer" and never stored.
        case belowRunning
        case refused(Refusal)
    }

    /// The acceptance check, in order: the `issuedAt` bound, then the
    /// monotonic `(tag, issuedAt)` floor against `stored`, then the running
    /// bundle's sealed `ownTag`. A lower tag than the stored one is refused;
    /// the same tag with an older `issuedAt` is refused; a tag below `ownTag`
    /// is `belowRunning`; the same pair is accepted (a fetch of the same
    /// index); anything above it is accepted and becomes the new mark.
    public static func accept(tag: String, issuedAt: Date, signedAt: Date, stored: AppIndexHighWater?,
                              ownTag: String?) -> Verdict {
        let limit = signedAt.addingTimeInterval(maxIssuedAfterSigning)
        guard issuedAt <= limit else {
            let ahead = issuedAt.timeIntervalSince(signedAt)
            return .refused(.issuedAfterSigning(seconds: ahead.isFinite ? Int(min(ahead, 1e12).rounded(.up)) : Int.max))
        }
        guard let pair = AppIndexHighWater(tag: tag, issuedAt: issuedAt) else { return .refused(.tag) }
        if let stored {
            if pair.version < stored.version { return .refused(.olderRelease(accepted: stored.tag)) }
            if pair.version == stored.version, issuedAt < stored.issuedAt { return .refused(.olderIndex) }
        }
        if let own = ownTag.flatMap(AppVersion.releaseTagVersion), pair.version < own { return .belowRunning }
        if let stored, pair.version == stored.version, issuedAt == stored.issuedAt { return .accepted(stored) }
        return .accepted(pair)
    }
}

/// AppUpdateCheckOutcome is how the last check of this launch ended.
public enum AppUpdateCheckOutcome: Equatable, Sendable {
    /// An index was fetched, verified and accepted.
    case accepted(AppIndexFacts)
    /// The fetch, the signature check, the decode or the acceptance check
    /// failed; the reason is for the line under "Could not check".
    case failed(String)
}

/// AppUpdateTransfer is a release download in flight, which a later step
/// reports while the offer stands.
public enum AppUpdateTransfer: Equatable, Sendable {
    case downloading
    case verifying
}

/// AppUpdateState is the app's own line in Settings > Updates, the status
/// item's menu and the popover: where this build stands against the latest
/// release the signed index names. Every failure is `couldNotCheck`, never
/// an offer.
public enum AppUpdateState: Equatable, Sendable {
    /// This build is the latest release.
    case upToDate(tag: String)
    /// A newer release is available.
    case available(tag: String)
    /// The newer release is downloading.
    case downloading
    /// The downloaded release is being verified.
    case verifying
    /// This build is newer than the latest release (a release candidate,
    /// or a build from a tag not published yet).
    case buildIsNewer(own: String, latest: String)
    /// A build with no Team ID pin or no payload tag: no request is made.
    case development
    /// The newer release needs a newer macOS than this Mac runs.
    case requiresNewerMacOS(String)
    /// The check failed; the reason, as shown.
    case couldNotCheck(reason: String)
    /// Automatic checks are off and none was asked for.
    case checksOff
    /// Checks are on and the first has not finished.
    case notCheckedYet

    /// The line shown for the state. Tags come from a verified index or the
    /// sealed bundle; they are clipped all the same, without their `v`.
    public var line: String {
        switch self {
        case .upToDate(let tag): "k3sm.app \(Self.shown(tag)) is the latest release."
        case .available(let tag): "k3sm.app \(Self.shown(tag)) is available."
        case .downloading: "Downloading the new release of k3sm.app."
        case .verifying: "Verifying the new release of k3sm.app."
        case .buildIsNewer(let own, let latest):
            "This build (\(Self.shown(own))) is newer than the latest release (\(Self.shown(latest)))."
        case .development: "Development build: updates are not checked."
        case .requiresNewerMacOS(let version):
            "The latest k3sm.app needs macOS \(StatusDisplay.clip(version)) or later."
        case .couldNotCheck(let reason): "Could not check for updates: " + StatusDisplay.errorText(reason)
        case .checksOff: "Automatic update checks are off."
        case .notCheckedYet: "Not checked yet."
        }
    }

    /// The case's name, for the log: never the line, which can carry a
    /// failure's text.
    public var caseName: String {
        switch self {
        case .upToDate: "upToDate"
        case .available: "available"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .buildIsNewer: "buildIsNewer"
        case .development: "development"
        case .requiresNewerMacOS: "requiresNewerMacOS"
        case .couldNotCheck: "couldNotCheck"
        case .checksOff: "checksOff"
        case .notCheckedYet: "notCheckedYet"
        }
    }

    /// The index tag the state names, for the log; nil when it names none.
    public var logTag: String? {
        switch self {
        case .upToDate(let tag), .available(let tag): tag
        case .buildIsNewer(_, let latest): latest
        default: nil
        }
    }

    /// Whether the state offers a release.
    public var isOffer: Bool {
        if case .available = self { return true }
        return false
    }

    /// A tag without its leading `v`, clipped.
    static func shown(_ tag: String) -> String {
        let clipped = StatusDisplay.clip(tag)
        return clipped.hasPrefix("v") ? String(clipped.dropFirst()) : clipped
    }

    /// Decides the state. Inputs: the running bundle's sealed
    /// `K3smPayloadTag` (nil for a build without one), whether a Team ID pin
    /// is compiled in, whether automatic checks are on, the last check's
    /// outcome (nil before one; the caller drops an automatic check's outcome
    /// once checks are turned off), the stored high-water pair, and a
    /// download in flight.
    ///
    /// The order is the contract: no pin, or no release tag, is a development
    /// build; no outcome is `checksOff` or `notCheckedYet`; a failure is
    /// `couldNotCheck`. An accepted index is judged against the effective
    /// floor, the higher of the stored pair and the running tag: an index
    /// below the stored pair is `couldNotCheck` (the acceptance check refuses
    /// it first; this holds it again); a release newer than the running tag
    /// is offered, or `requiresNewerMacOS` when this Mac cannot run it; the
    /// same release is `upToDate`; an older one is `buildIsNewer`. A release
    /// candidate below a final release is offered that final release.
    public static func decide(ownTag: String?, pinned: Bool, checksOn: Bool, outcome: AppUpdateCheckOutcome?,
                              stored: AppIndexHighWater?, transfer: AppUpdateTransfer? = nil) -> AppUpdateState {
        guard pinned, let ownTag, let own = AppVersion.releaseTagVersion(ownTag),
              !(own.major == 0 && own.minor == 0 && own.patch == 0)
        else { return .development }
        switch outcome {
        case nil:
            return checksOn ? .notCheckedYet : .checksOff
        case .failed(let reason)?:
            return .couldNotCheck(reason: reason)
        case .accepted(let facts)?:
            guard let latest = AppIndexHighWater(tag: facts.tag, issuedAt: facts.issuedAt) else {
                return .couldNotCheck(reason: AppUpdateAcceptance.Refusal.tag.description)
            }
            if let stored, stored.isAbove(version: latest.version, issuedAt: latest.issuedAt) {
                return .couldNotCheck(reason: "the index is older than one already seen")
            }
            if latest.version > own {
                if case .requiresNewer(let minimum) = facts.macOS { return .requiresNewerMacOS(minimum) }
                switch transfer {
                case .downloading?: return .downloading
                case .verifying?: return .verifying
                case nil: return .available(tag: facts.tag)
                }
            }
            if latest.version == own { return .upToDate(tag: facts.tag) }
            return .buildIsNewer(own: ownTag, latest: facts.tag)
        }
    }
}

/// AppUpdateAge is the age of the last successful check, as Settings >
/// Updates shows it.
public enum AppUpdateAge {
    /// "Last checked: never", "just now", "5 minutes ago", "3 hours ago",
    /// "2 days ago". A date ahead of `now` (a clock set back) reads as just now.
    public static func line(lastCheck: Date?, now: Date) -> String {
        guard let lastCheck else { return "Last checked: never." }
        let seconds = max(0, now.timeIntervalSince(lastCheck))
        let minutes = Int(seconds / 60), hours = Int(seconds / 3_600), days = Int(seconds / 86_400)
        let age: String
        if minutes < 1 {
            age = "just now"
        } else if hours < 1 {
            age = minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        } else if days < 1 {
            age = hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else {
            age = days == 1 ? "1 day ago" : "\(days) days ago"
        }
        return "Last checked: \(age)."
    }
}

/// AppAheadOfCluster is the persistent fact that this app carries a newer
/// release than the cluster's server runs: shown in Settings > Updates, the
/// status item's menu and the popover for as long as it holds, never as a
/// one-time question.
public struct AppAheadOfCluster: Equatable, Sendable {
    /// The app's payload tag and the cluster's release tag.
    public let app: String
    public let cluster: String

    public init(app: String, cluster: String) {
        self.app = app
        self.cluster = cluster
    }

    /// The line shown.
    public var line: String {
        "This app carries \(AppUpdateState.shown(app)), newer than the cluster's \(AppUpdateState.shown(cluster))."
    }

    /// The fact, or nil: both tags must be release tags
    /// (`AppVersion.releaseTagVersion`) and the app's the newer.
    public static func decide(appTag: String?, clusterTag: String?) -> AppAheadOfCluster? {
        guard let appTag, let clusterTag,
              let app = AppVersion.releaseTagVersion(appTag), let cluster = AppVersion.releaseTagVersion(clusterTag),
              app > cluster
        else { return nil }
        return AppAheadOfCluster(app: appTag, cluster: clusterTag)
    }

    /// The fact from the update plan's own facts: the sealed payload tag
    /// against the server's installed release (`installedTag` on a server,
    /// the server's own Node or the control plane's release on a worker).
    public static func decide(facts: UpdatePlanFacts) -> AppAheadOfCluster? {
        let cluster: String?
        switch facts.role {
        case .server?: cluster = facts.installedTag ?? facts.serverRunning
        case .agent?: cluster = facts.serverRunning ?? facts.controlPlane.map { "v" + $0.description }
        case nil: cluster = nil
        }
        return decide(appTag: facts.payloadTag, clusterTag: cluster)
    }
}

/// AppUpdateNotice is the notification for a new release of the app itself,
/// with `UpdateNotice`'s rule: once per release, only with the notification
/// preference on, only for an offer.
public enum AppUpdateNotice {
    /// The notification's identifier, beside the cluster's update notice.
    public static let identifier = "io.k3sm.app.app-update-available"

    /// The notice for `state`, or nil: not an offer, the preference off, or
    /// `notified` already names the release.
    public static func decide(state: AppUpdateState, enabled: Bool, notified: String?) -> UpdateNotice? {
        guard enabled, case .available(let tag) = state else { return nil }
        let release = AppUpdateState.shown(tag)
        if let notified, AppUpdateState.shown(notified) == release { return nil }
        return UpdateNotice(release: release, title: StatusDisplay.clip("k3sm.app \(release) is available"),
                            body: "Settings > Updates has the new release of the app.")
    }
}

/// AppUpdateSchedule is when the app checks for a new release of itself:
/// first `firstDelay` after launch, then every `PollIntervals.appUpdateCheck`
/// (a day, two under Low power) spread by `PollJitter`. A turn that falls in
/// the first run or while a root step runs is held back and tried again after
/// `firstDelay`. With `pref.checkAppUpdates` off a turn makes no request.
public enum AppUpdateSchedule {
    /// The wait before the first check of a launch.
    public static let firstDelay: Duration = .seconds(60)

    /// What one scheduled turn does.
    public enum Turn: Equatable, Sendable {
        case check
        /// The first run is on screen or a root step runs: try again soon.
        case holdBack
        /// Automatic checks are off: no request.
        case off
    }

    public static func turn(checksOn: Bool, firstRun: Bool, rootStepRunning: Bool) -> Turn {
        guard checksOn else { return .off }
        return firstRun || rootStepRunning ? .holdBack : .check
    }

    /// The wait after `turn`: `firstDelay` after a held-back turn, otherwise
    /// the profile's interval spread by `unit`.
    public static func nextWait(after turn: Turn, intervals: PollIntervals, unit: Double) -> Duration {
        turn == .holdBack ? firstDelay : PollJitter.spread(intervals.appUpdateCheck, unit: unit)
    }
}
