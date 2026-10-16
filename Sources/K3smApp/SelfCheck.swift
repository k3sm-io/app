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
import K3smHost
import K3smInstall
import K3smStatus
import Security

/// SelfCheck gathers what the window needs before it enables a privileged
/// action: the Team ID compiled into this binary, whether this bundle's own
/// signature satisfies the designated requirement built from it, and whether
/// the user is an administrator.
enum SelfCheck {
    /// The admin group's gid on macOS.
    private static let adminGID: gid_t = 80

    /// The Team ID compiled into this binary (`TeamIDPin`), or nil for a
    /// developer build. Info.plist is never consulted for it.
    static func teamID() -> TeamID? {
        TeamIDPin.teamID
    }

    /// The account running the app (the passwd entry of `getuid()`, not the
    /// console session's owner), for `k3sm install --user`: the admin
    /// kubeconfig goes to that account. Nil when it is root or not a plain
    /// name.
    static func consoleUser() -> ConsoleUser? {
        guard let entry = getpwuid(getuid()) else { return nil }
        return ConsoleUser(String(cString: entry.pointee.pw_name))
    }

    /// The payload version: the bundle's own short version, which the build
    /// stamps with the same release version as the payload.
    static func payloadVersion(in bundle: Bundle = .main) -> SemanticVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
    }

    /// Verifies the whole bundle (nested code and every sealed resource,
    /// the payload included) against the Developer ID requirement for `team`.
    static func signatureValid(bundleURL: URL = Bundle.main.bundleURL, team: TeamID) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        let text = DesignatedRequirement.developerID(teamID: team) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Reports whether this process's user is in the admin group.
    static func userIsAdmin() -> Bool {
        let count = getgroups(0, nil)
        guard count > 0 else { return false }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let filled = getgroups(count, &groups)
        guard filled > 0 else { return false }
        return groups.prefix(Int(filled)).contains(adminGID)
    }

    /// Evaluates every check into the window's availability.
    static func availability() -> PrivilegedAvailability {
        let team = teamID()
        let valid = team.map { signatureValid(team: $0) } ?? false
        return PrivilegedAvailability.evaluate(teamID: team, signatureValid: valid, userIsAdmin: userIsAdmin())
    }

    /// Whether the app will run the installed CLI as root, or ask it which
    /// verbs it has: `InstalledCLI.trust`, the check the MCP server makes too.
    /// A developer build pins no team, so it checks the paths only; it offers
    /// no lifecycle verb either way.
    static func installedCLITrust(team: TeamID?) -> InstalledCLITrust {
        InstalledCLI.trust(team: team)
    }

    /// The startup health check's file facts: whether `/Library/k3sm` and
    /// its CLI exist (`lstat`, so a symlinked CLI counts as present and then
    /// fails its trust check).
    static func installFiles() -> (rootExists: Bool, cliPresent: Bool) {
        (InstalledCLI.pathFacts(K3smCLI.installRoot) != nil, InstalledCLI.pathFacts(K3smCLI.path) != nil)
    }

    /// The CLI environment for this user, from the passwd entry rather than
    /// the inherited environment.
    static func cliEnvironment() -> [String: String] {
        InstalledCLI.environment()
    }
}
