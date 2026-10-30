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

/// AppUpdateOwn is what the running app is, for its own update check: the
/// exact release tag its sealed `Info.plist` carries (`AppVersion.payloadTag`,
/// or the short version for a bundle built before that key) and whether the
/// build pins a Team ID. Without both it is a development build, which never
/// checks.
public struct AppUpdateOwn: Equatable, Sendable {
    /// The release, nil for a development build's `0.0.0` or an unreadable tag.
    public let version: SemanticVersion?
    /// Whether a Team ID is compiled in, so a release index can be verified.
    public let pinned: Bool

    public init(tag: String?, pinned: Bool) {
        let version = tag.flatMap(SemanticVersion.init)
        self.version = version.flatMap { $0.major == 0 && $0.minor == 0 && $0.patch == 0 ? nil : $0 }
        self.pinned = pinned
    }

    /// The running bundle, from its `Info.plist` (`AppVersion.payloadRelease(info:)`).
    public init(info: [String: Any]?, pinned: Bool) {
        version = AppVersion.payloadRelease(info: info)
        self.pinned = pinned
    }

    /// Whether this build may check at all.
    public var isRelease: Bool { pinned && version != nil }
}

/// AppUpdateLatest is the part of a verified release index the app's own
/// line needs: its tag, its issue time and the macOS it needs.
public struct AppUpdateLatest: Equatable, Sendable {
    public let tag: String
    public let version: SemanticVersion
    /// `YYYY-MM-DDTHH:MM:SSZ`, as the index writes it.
    public let issuedAt: String
    public let minimumMacOS: String

    /// Nil unless `tag` is a release tag and `issuedAt` a UTC time.
    public init?(tag: String, issuedAt: String, minimumMacOS: String) {
        guard let version = AppVersion.releaseTagVersion(tag), AppUpdateRecord.time(issuedAt) != nil else { return nil }
        self.tag = tag
        self.version = version
        self.issuedAt = issuedAt
        self.minimumMacOS = minimumMacOS
    }

    /// The fields of a decoded index (`ReleaseIndex.parse` has checked them).
    public init?(index: ReleaseIndex) {
        self.init(tag: index.tag, issuedAt: index.issuedAt, minimumMacOS: index.minimumMacOS)
    }

    func supports(macOS: OperatingSystemVersion) -> Bool {
        var parts = minimumMacOS.split(separator: ".").map { Int($0) ?? Int.max }
        while parts.count < 3 { parts.append(0) }
        let have = [macOS.majorVersion, macOS.minorVersion, macOS.patchVersion]
        return !have.lexicographicallyPrecedes(parts)
    }
}

/// AppUpdateResult is the outcome of the last check: a verified and accepted
/// index, or why there is none. A failure never becomes an offer.
public enum AppUpdateResult: Equatable, Sendable {
    case verified(AppUpdateLatest)
    /// Why the check failed: a network, signature, decode or floor refusal,
    /// as its own words; the state line cleans it for the screen.
    case failed(String)
}

/// AppUpdateDownload is where the new release's disk image stands.
public enum AppUpdateDownload: Equatable, Sendable {
    case idle
    /// Downloading or verifying.
    case inFlight
    /// Verified and staged: the next step is a restart.
    case verified
}

/// AppUpdateRecord is the app's monotonic floor: the highest `(tag,
/// issuedAt)` it has accepted, kept in its preferences. An index below it
/// is a replay and is refused. The floor the app compares against is the
/// higher of this mark and the running bundle's own tag, read from its
/// sealed `Info.plist`, so resetting the preferences cannot lower it.
public struct AppUpdateRecord: Equatable, Sendable {
    public var highTag: String?
    public var highIssuedAt: String?

    public init(highTag: String? = nil, highIssuedAt: String? = nil) {
        self.highTag = highTag
        self.highIssuedAt = highIssuedAt
    }

    /// How far an index's own issue time may run ahead of its timestamp:
    /// the verifier's allowance for clock skew.
    public static let issueLead: TimeInterval = 3_600

    public static let olderThanSeen = "the index names a release older than one this app has already seen"
    public static let issuedAfterSigning = "the index says it was issued after it was signed"

    public enum Acceptance: Equatable, Sendable {
        /// The record to store.
        case accepted(AppUpdateRecord)
        case refused(String)
    }

    /// Whether to take `latest`, signed at `signedAt` (the timestamp
    /// authority's time, never the Mac's clock): refused when its tag is
    /// below the stored mark, or equal to it with an older issue time, and
    /// when it says it was issued after it was signed. The running bundle's
    /// half of the floor is applied by `AppUpdateState.decide`: an accepted
    /// index below the running bundle reads "this build is newer" and is
    /// never an offer, whatever the stored mark says.
    public static func accept(_ latest: AppUpdateLatest, signedAt: Date, record: AppUpdateRecord) -> Acceptance {
        guard let issued = time(latest.issuedAt), issued <= signedAt.addingTimeInterval(issueLead) else {
            return .refused(issuedAfterSigning)
        }
        guard let tag = record.highTag, let high = AppVersion.releaseTagVersion(tag) else {
            return .accepted(AppUpdateRecord(highTag: latest.tag, highIssuedAt: latest.issuedAt))
        }
        if latest.version < high { return .refused(olderThanSeen) }
        if latest.version == high {
            guard let seen = record.highIssuedAt.flatMap(time), let issuedTime = time(latest.issuedAt), issuedTime >= seen
            else { return .refused(olderThanSeen) }
        }
        return .accepted(AppUpdateRecord(highTag: latest.tag, highIssuedAt: latest.issuedAt))
    }

    /// A `YYYY-MM-DDTHH:MM:SSZ` time, nil for anything else.
    static func time(_ text: String) -> Date? {
        guard text.utf8.count == 20 else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// AppUpdateState is the app's own release line in Settings > Updates and
/// the menu: one of the states the update plan names, decided from what the
/// app is, the last check and the download. Only `available` is an offer.
public enum AppUpdateState: Equatable, Sendable {
    /// No Team ID pin or no release: nothing is checked automatically.
    case development
    /// A release build that has not checked yet.
    case notChecked
    case upToDate(String)
    case available(String, AppUpdateDownload)
    /// A newer release this macOS cannot run; nothing is downloaded.
    case requiresNewerMacOS(String, minimum: String)
    /// This build is newer than the latest release (a release candidate, or
    /// a build from an unpublished tag).
    case buildNewer(own: String, latest: String)
    /// The reason, cleaned for the screen.
    case couldNotCheck(String)

    public static func decide(own: AppUpdateOwn, result: AppUpdateResult?, download: AppUpdateDownload,
                              macOS: OperatingSystemVersion) -> AppUpdateState {
        guard own.isRelease, let ownVersion = own.version else { return .development }
        switch result {
        case nil:
            return .notChecked
        case .failed(let reason):
            return .couldNotCheck(StatusDisplay.errorText(reason))
        case .verified(let latest):
            let shown = StatusDisplay.clip(latest.version.description)
            if latest.version == ownVersion { return .upToDate(shown) }
            if latest.version < ownVersion { return .buildNewer(own: StatusDisplay.clip(ownVersion.description), latest: shown) }
            guard latest.supports(macOS: macOS) else {
                return .requiresNewerMacOS(shown, minimum: StatusDisplay.clip(latest.minimumMacOS))
            }
            return .available(shown, download)
        }
    }

    /// Whether the line offers an update.
    public var isOffer: Bool {
        if case .available = self { true } else { false }
    }

    /// The release a state names, for the notice.
    var offered: String? {
        if case .available(let release, _) = self { release } else { nil }
    }

    /// One sentence.
    public var line: String {
        switch self {
        case .development: "Development build: updates are not checked."
        case .notChecked: "k3sm.app has not checked for updates yet."
        case .upToDate(let release): "k3sm.app \(release) is the latest release."
        case .available(let release, .idle): "k3sm.app \(release) is available."
        case .available(let release, .inFlight): "Downloading and verifying k3sm.app \(release)."
        case .available(let release, .verified): "k3sm.app \(release) is ready: restart to update."
        case .requiresNewerMacOS(let release, let minimum):
            "k3sm.app \(release) needs macOS \(minimum) or later; nothing was downloaded."
        case .buildNewer(let own, let latest): "This build (\(own)) is newer than the latest release (\(latest))."
        case .couldNotCheck(let reason): "Could not check for updates: \(reason)" + (reason.hasSuffix(".") ? "" : ".")
        }
    }

    /// The age of the last successful check.
    public static func lastCheckLine(_ last: Date?, now: Date) -> String {
        let prefix = "Last successful check: "
        guard let last else { return prefix + "never" }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        func ago(_ n: Int, _ unit: String) -> String { prefix + "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return prefix + "just now"
        case ..<3_600: return ago(seconds / 60, "minute")
        case ..<86_400: return ago(seconds / 3_600, "hour")
        default: return ago(seconds / 86_400, "day")
        }
    }

    /// The standing line while the app carries a newer k3sm than this Mac
    /// runs, nil otherwise. It stays until the cluster is updated; it is not
    /// a question, and it starts nothing.
    public static func aheadOfCluster(own: AppUpdateOwn, cluster: SemanticVersion?) -> String? {
        guard let carried = own.version, let cluster, cluster < carried else { return nil }
        return StatusDisplay.clip("This app carries k3sm \(carried); this Mac's k3sm runs \(cluster).")
    }
}

/// AppUpdateSchedule is when the app checks: a minute after launch, then
/// once a day spread by `PollJitter`, twice as long under Low power. An
/// automatic check runs only with `pref.checkAppUpdates` on and never during
/// first run; Check Now always may. A development build never checks.
public enum AppUpdateSchedule {
    public static let firstDelay: Duration = .seconds(60)
    public static let interval: Duration = .seconds(86_400)

    public enum Trigger: Sendable {
        case automatic
        /// Check for Updates in the app menu, or Check Now in Settings.
        case user
    }

    /// The wait before the next automatic check.
    public static func wait(profile: PollProfile, unit: Double) -> Duration {
        PollJitter.spread(profile == .lowPower ? interval * 2 : interval, unit: unit)
    }

    /// Whether a check may send its request.
    public static func mayRequest(_ trigger: Trigger, checksOn: Bool, own: AppUpdateOwn, firstRun: Bool) -> Bool {
        guard own.isRelease else { return false }
        switch trigger {
        case .user: return true
        case .automatic: return checksOn && !firstRun
        }
    }
}

/// AppUpdateFollowUp is what a state leads to on its own: a notice and,
/// with `pref.downloadAppUpdates` on, the download. There is no other case:
/// an app update never rolls the cluster; only the question after a
/// relaunch can, and only on a yes.
public enum AppUpdateFollowUp: Equatable, Sendable {
    case notify(String)
    case download(String)

    public static func decide(_ state: AppUpdateState, downloadOn: Bool, notifyOn: Bool, notified: String?) -> [AppUpdateFollowUp] {
        guard case .available(let release, let download) = state else { return [] }
        var steps: [AppUpdateFollowUp] = []
        if let notice = AppUpdateNotice.decide(state, enabled: notifyOn, notified: notified) { steps.append(.notify(notice.release)) }
        if downloadOn, download == .idle { steps.append(.download(release)) }
        return steps
    }
}

/// AppUpdateNotice is the notification for a new app release, once per
/// release like `UpdateNotice`, under the same preference; the release it
/// names is kept in `AppPreferences.appUpdateNotifiedRelease`.
public enum AppUpdateNotice {
    public static func decide(_ state: AppUpdateState, enabled: Bool, notified: String?) -> UpdateNotice? {
        guard enabled, let release = state.offered, !release.isEmpty, case .available(_, .idle) = state else { return nil }
        if let notified, StatusDisplay.clip(notified) == release { return nil }
        return UpdateNotice(release: release, title: StatusDisplay.clip("k3sm.app \(release) is available"),
                            body: "Open Settings > Updates to download it.")
    }
}

/// AppUpdateRequest is the whole of what the check sends: a GET of one fixed
/// URL with a fixed user agent that names no version, no query string, no
/// cookie and no credential. Every hop, the first and each redirect, must be
/// https on a pinned host (`ReleaseIndex.allowedHosts`) with no port and no
/// user; a redirect target's own query (the CDN's signature) is GitHub's.
public enum AppUpdateRequest {
    public static let url = "https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m"
    public static let method = "GET"
    public static let userAgent = "k3sm-app"
    public static let headers = ["User-Agent": userAgent]

    public static func allowsHop(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased()
        else { return false }
        return ReleaseIndex.allowedHosts.contains(host)
    }
}
