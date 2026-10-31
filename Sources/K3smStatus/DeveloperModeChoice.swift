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

/// DeveloperModeChoice is what developer mode changes for the screens that
/// offer a root step: whether this build may run it, and which version its
/// payload installs as. Developer mode exists only in a developer build (no
/// Team ID pin): a pinned build is decided exactly as before, whatever the
/// first-run checkbox or the marker say. The app passes `developerMode` as
/// the first-run checkbox on the review step and as the marker (it counts)
/// everywhere else; the root step checks the marker again before it runs.
public enum DeveloperModeChoice {
    /// Whether this build may run the checked root step: a pinned build
    /// always, a developer build only in developer mode.
    public static func rootStep(pinned: Bool, developerMode: Bool) -> Bool {
        pinned || developerMode
    }

    /// The version the root step installs the app's payload as. The
    /// payload's release when the bundle carries one; else, in developer
    /// mode on a developer build whose payload holds a k3sm
    /// (`payloadCLI`), the build's own pseudo-version (`AppVersion`, the
    /// `K3smBuildVersion` stamp); nil otherwise, which keeps every install,
    /// update and repair from the payload unavailable as before.
    public static func payload(release: SemanticVersion?, build: AppVersion, pinned: Bool, developerMode: Bool,
                               payloadCLI: Bool) -> SemanticVersion? {
        if let release { return release }
        guard !pinned, developerMode, payloadCLI, build.isDevelopment, let text = build.text else { return nil }
        return SemanticVersion(text)
    }
}
