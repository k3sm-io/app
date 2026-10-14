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
    /// verbs it has: `/Library/k3sm/k3sm` and every directory above it are
    /// root-owned, not group or other writable and not symlinks, and the
    /// binary satisfies the Developer ID requirement for `team`. The same
    /// checks the lifecycle root script repeats as root before it runs.
    ///
    /// A developer build pins no team, so it checks the paths only; it offers
    /// no lifecycle verb either way.
    static func installedCLITrust(team: TeamID?) -> InstalledCLITrust {
        InstalledCLITrust.evaluate(
            cliPath: K3smCLI.path,
            facts: pathFacts,
            signatureValid: { team.map { binarySignatureValid(path: K3smCLI.path, team: $0) } ?? true })
    }

    /// `lstat` of one path, or nil when it cannot be read.
    static func pathFacts(_ path: String) -> InstalledCLITrust.PathFacts? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return InstalledCLITrust.PathFacts(
            isSymlink: type == S_IFLNK, isDirectory: type == S_IFDIR, isRegularFile: type == S_IFREG,
            ownerUID: st.st_uid, mode: UInt16(st.st_mode & 0o7777), hasACL: hasACL(path))
    }

    /// Whether a path (not what a symlink points at) carries an extended ACL
    /// with at least one entry. An unreadable ACL counts as present.
    static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }

    /// Verifies one binary against the Developer ID requirement for `team`.
    static func binarySignatureValid(path: String, team: TeamID) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        let text = DesignatedRequirement.developerID(teamID: team) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The CLI environment for this user, from the passwd entry rather than
    /// the inherited environment.
    static func cliEnvironment() -> [String: String] {
        guard let entry = getpwuid(getuid()) else {
            return K3smCLI.environment(home: "", user: "")
        }
        return K3smCLI.environment(home: String(cString: entry.pointee.pw_dir), user: String(cString: entry.pointee.pw_name))
    }
}
