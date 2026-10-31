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

/// TrustPolicy is what the root step checks the installed CLI and the staged
/// app bundle against. A release build pins a Developer ID Team ID and every
/// check is the designated requirement built from it. A developer build pins
/// no team; it runs the root step only in developer mode, where the
/// signature checks stop and a root-owned marker (`DeveloperMode`) is what
/// every step after the first install requires instead.
///
/// The policy reaches only the code that checks the installed CLI or the
/// staged bundle (`InstalledCLIPreamble`, `RootScriptBuilder.stagedCopy`,
/// `LifecycleScriptBuilder`, `JoinTokenMint`, `CopyOutPlan` and the drivers
/// that render them). Everything that must hold a Developer ID requirement
/// whatever the build (the version set's roll, the app's own update, the
/// release index) keeps a `TeamID` and never sees this type.
public enum TrustPolicy: Hashable, Sendable {
    /// Every check is the Developer ID requirement for this team.
    case developerID(TeamID)
    /// Developer mode: no signature requirement; the marker is checked instead.
    case developer

    /// The code requirement a signature must satisfy, or nil in developer
    /// mode, where `codesign` checks only that the signature is intact.
    public var requirementClause: String? {
        switch self {
        case .developerID(let team): return DesignatedRequirement.developerID(teamID: team)
        case .developer: return nil
        }
    }

    /// Whether this is developer mode.
    public var isDeveloper: Bool { self == .developer }

    /// The policy this build runs the root step under, or nil when it runs
    /// none. A pinned build is always `.developerID(pin)`, whatever the
    /// marker says: a release never enters developer mode. An unpinned build
    /// is `.developer` only while `developerModeOn`, the marker and every
    /// directory above it passing `DeveloperMode.isOn(markerPath:owners:facts:)`.
    public static func current(pin: TeamID?, developerModeOn: Bool) -> TrustPolicy? {
        if let pin { return .developerID(pin) }
        return developerModeOn ? .developer : nil
    }
}
