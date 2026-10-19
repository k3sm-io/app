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

/// AppVersion is the version the app shows for itself (the About panel, the
/// status popover's version line without a payload release, Settings >
/// General, and `k3sm-mcp`'s server and `versions.app`), from two Info.plist keys
/// `hack/build-app.sh` writes:
///
/// - a release build (`--version x.y.z`) stamps `CFBundleShortVersionString`
///   and `CFBundleVersion` with `x.y.z` and no `K3smBuildVersion`; it shows
///   `x.y.z`, as before.
/// - a development build keeps both bundle versions at `0.0.0` (macOS takes
///   digits only there, and `0.0.0` is how the app knows it carries no
///   release) and stamps `K3smBuildVersion` with a Go-style pseudo-version
///   (`v0.0.0-0.20261016221530-2eda966a1b2c`, `+dirty` for a modified tree,
///   `v0.0.0-unknown` outside a git checkout); it shows that string.
///
/// A `K3smBuildVersion` that does not start with `v` or does not parse as a
/// `SemanticVersion` is ignored. Shown text is clipped like any other line.
public struct AppVersion: Equatable, Sendable {
    /// The Info.plist key a development build carries its pseudo-version in.
    public static let buildVersionKey = "K3smBuildVersion"
    /// The bundle's own short version key.
    public static let shortVersionKey = "CFBundleShortVersionString"

    /// The text shown for the app's version; nil when neither key carries one
    /// (a binary run outside a bundle).
    public let text: String?
    /// True when the text is a development build's pseudo-version.
    public let isDevelopment: Bool

    public init(shortVersion: String?, buildVersion: String?) {
        if let build = buildVersion, build.hasPrefix("v"), SemanticVersion(build) != nil {
            text = StatusDisplay.clip(build)
            isDevelopment = true
        } else if let short = shortVersion, SemanticVersion(short) != nil {
            text = StatusDisplay.clip(short)
            isDevelopment = false
        } else {
            text = nil
            isDevelopment = false
        }
    }

    /// Reads both keys from an Info.plist dictionary (`Bundle.infoDictionary`).
    public init(info: [String: Any]?) {
        self.init(
            shortVersion: info?[Self.shortVersionKey] as? String,
            buildVersion: info?[Self.buildVersionKey] as? String)
    }

    /// One line naming the app and its version: "k3sm.app v1.2.3",
    /// "k3sm.app v0.0.0-0.20261016221530-2eda966a1b2c", "k3sm.app unknown".
    public var title: String {
        guard let text else { return "k3sm.app unknown" }
        return "k3sm.app " + (text.hasPrefix("v") ? text : "v" + text)
    }

    /// The Info.plist key a release build carries its exact payload tag in
    /// (`hack/build-app.sh --payload-tag`): `v0.2.0-rc.1` for a release
    /// candidate, `v0.2.0` for the final. The short version cannot tell the
    /// two apart, because macOS takes digits only there and `vX.Y.Z-rc.N`
    /// builds `X.Y.Z`. The key is sealed by the bundle signature, so the app
    /// can trust what it reads; it is the payload release every comparison
    /// uses, the downgrade floor included.
    public static let payloadTagKey = "K3smPayloadTag"

    /// The exact payload tag the bundle carries: the `K3smPayloadTag` value
    /// when it is a release tag, `v` then `MAJOR.MINOR.PATCH` with an
    /// optional `-rc.N`, the grammar `build-app.sh` stamps (no build
    /// metadata, no other pre-release, no leading zeros), whose core is the
    /// bundle's short version. Nil when the key is absent or is anything
    /// else.
    public static func payloadTag(info: [String: Any]?) -> String? {
        guard let tag = info?[payloadTagKey] as? String,
              let short = info?[shortVersionKey] as? String,
              let version = releaseTagVersion(tag),
              "\(version.major).\(version.minor).\(version.patch)" == short
        else { return nil }
        return tag
    }

    /// The release the app carries as its payload, from the bundle's Info.plist.
    /// A bundle with `K3smPayloadTag` is read from that tag alone: a value
    /// `payloadTag(info:)` refuses yields nil, never the short-version
    /// fallback, so a release candidate is never taken for its final. A
    /// bundle built before the key falls back to the short version
    /// (`payloadRelease(shortVersion:)`); that fallback is kept for one
    /// release, and in it an rc and its final compare equal. Nil for
    /// `0.0.0` either way, a development build carrying no release.
    ///
    /// The missing-key fallback is for the running, installed bundle's own
    /// display only. A staged candidate bundle (a self-update) must carry a
    /// valid `K3smPayloadTag`: a caller deciding whether to accept one reads
    /// `payloadTag(info:)`, never this fallback, and treats nil from either
    /// as "no release", which a refusal decision handles fail-closed.
    public static func payloadRelease(info: [String: Any]?) -> SemanticVersion? {
        guard info?[payloadTagKey] != nil else {
            return payloadRelease(shortVersion: info?[shortVersionKey] as? String)
        }
        guard let tag = payloadTag(info: info), let version = SemanticVersion(tag) else { return nil }
        if version.major == 0, version.minor == 0, version.patch == 0 { return nil }
        return version
    }

    /// The release the app carries as its payload, from the bundle's short
    /// version alone: the reading for a bundle built before
    /// `K3smPayloadTag` (`payloadRelease(info:)` is the one the app uses).
    /// Nil when it does not parse, and nil for `0.0.0`, which is how a
    /// development build marks that it carries no release (a pseudo-version
    /// with a `0.0.0` core counts the same): every path that needs the
    /// payload's release then takes its "no payload" branch.
    public static func payloadRelease(shortVersion: String?) -> SemanticVersion? {
        guard let short = shortVersion, let version = SemanticVersion(short) else { return nil }
        if version.major == 0, version.minor == 0, version.patch == 0 { return nil }
        return version
    }

    /// The version a release tag names, when the tag is exactly
    /// `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-rc.N`, nil otherwise: the
    /// grammar of `hack/release/payload-release.sh check-tag` and
    /// `release.sh`, each of MAJOR, MINOR and PATCH at most nine digits and N
    /// at most four, none with a leading zero. The digit limits are checked
    /// here on the tag's own text, not left to `SemanticVersion`.
    public static func releaseTagVersion(_ tag: String) -> SemanticVersion? {
        guard tag.utf8.count <= 64, tag.hasPrefix("v") else { return nil }
        let core = tag.dropFirst().prefix { $0 != "-" }.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy({ (1...9).contains($0.count) }),
              let version = SemanticVersion(tag)
        else { return nil }
        switch version.prerelease.count {
        case 0:
            break
        case 2:
            let n = version.prerelease[1]
            guard version.prerelease[0] == "rc", (1...4).contains(n.count), n.allSatisfy(\.isASCIIDigit)
            else { return nil }
        default:
            return nil
        }
        // The canonical form round-trips, so build metadata and anything
        // else SemanticVersion accepts but drops is refused.
        return "v" + version.description == tag ? version : nil
    }

    /// The status popover's version line. With a payload release it compares
    /// the installed release with it ("this app carries 1.2.3, a newer
    /// release"); without one it names the installed release and the app
    /// itself ("Installed: 0.1.8 · k3sm.app v0.0.0-0.20261017002053-910af952ea03").
    public func versionLine(installed: SemanticVersion?, payload: SemanticVersion?) -> String {
        let shown = installed?.description ?? "unknown"
        guard let payload else { return "Installed: \(shown) · \(title)" }
        guard let current = installed else { return "Installed: \(shown) · this app carries \(payload)" }
        switch PayloadRelation(payload: payload, installed: current) {
        case .newer: return "Installed: \(current) · this app carries \(payload), a newer release"
        case .same: return "Installed: \(current) · up to date with this app"
        case .older: return "Installed: \(current) · this app carries an older release, \(payload)"
        }
    }

    /// AboutPanel is what the standard About panel is given in place of the
    /// bundle's own versions.
    public struct AboutPanel: Equatable, Sendable {
        /// Shown as "Version <applicationVersion>".
        public let applicationVersion: String
        /// The build number in parentheses after it; empty shows none.
        public let version: String
    }

    /// The About panel's versions for a development build (the
    /// pseudo-version, no build number, since `0.0.0` says nothing); nil for
    /// any other build, which keeps the standard panel ("Version 1.2.3 (1.2.3)").
    public var aboutPanel: AboutPanel? {
        guard isDevelopment, let text else { return nil }
        return AboutPanel(applicationVersion: text, version: "")
    }
}
