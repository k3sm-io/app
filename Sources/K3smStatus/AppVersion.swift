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

/// AppVersion is the version the app shows for itself (the About panel and
/// `k3sm-mcp`'s server and `versions.app`), from two Info.plist keys
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
