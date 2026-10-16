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

/// InstalledCLI is the check the app and the MCP server make before every
/// run of the installed CLI, and the environment they run it with.
public enum InstalledCLI {
    /// Whether the installed CLI may be run: `/Library/k3sm/k3sm` and every
    /// directory above it are root-owned, not group or other writable, carry
    /// no ACL and are not symlinks, and the binary satisfies the Developer ID
    /// requirement for `team`. The same checks the lifecycle root script
    /// repeats as root before it runs.
    ///
    /// A developer build pins no team, so it checks the paths only.
    public static func trust(team: TeamID?) -> InstalledCLITrust {
        InstalledCLITrust.evaluate(
            cliPath: K3smCLI.path,
            facts: pathFacts,
            signatureValid: { team.map { binarySignatureValid(path: K3smCLI.path, team: $0) } ?? true })
    }

    /// `lstat` of one path, or nil when it cannot be read.
    public static func pathFacts(_ path: String) -> InstalledCLITrust.PathFacts? {
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

    /// The CLI environment for this process's user, from the passwd entry
    /// rather than the inherited environment.
    public static func environment() -> [String: String] {
        guard let entry = getpwuid(getuid()) else {
            return K3smCLI.environment(home: "", user: "")
        }
        return K3smCLI.environment(home: String(cString: entry.pointee.pw_dir), user: String(cString: entry.pointee.pw_name))
    }

    /// This process's user's home directory from the passwd entry, nil when
    /// it has none.
    public static func home() -> String? {
        guard let entry = getpwuid(getuid()) else { return nil }
        return String(cString: entry.pointee.pw_dir)
    }
}
