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

/// DeveloperMode is the install-time choice that stops the signature checks
/// so a k3sm built from source can be installed and run as root by a
/// developer build of the app. `k3sm install --developer-mode on` records it
/// as a root-owned marker file outside the install root, and an install of a
/// signed release removes it. The marker's presence is the whole record: its
/// content is never read.
///
/// The marker counts only when it passes the checks the installed CLI gets:
/// not a symlink, a regular file, owned by root, not writable by group or
/// others, and with no ACL. A marker failing any of them counts as absent,
/// so the signature checks stay on.
public enum DeveloperMode {
    /// The marker's path. k3sm defines the same path; the app's gate compares them.
    public static let markerPath = "/Library/k3sm.developer-mode"

    /// The fixed warning shown wherever developer mode is offered or on.
    public static let warning = "Developer mode: k3sm will not verify who signed this app or the k3sm it installs and runs as root. Anyone who can replace those files gets root. Use it only on a Mac you build k3sm on. Installing a signed release turns it off."

    /// The exit status of a root step that found the marker missing or
    /// failing a check (`LifecycleExit.developerModeMissing`).
    public static var missingExit: Int32 { LifecycleExit.developerModeMissing }

    /// Whether `lstat` of the marker (`facts`, nil when it does not exist)
    /// shows a marker that counts.
    public static func isOn(facts: InstalledCLITrust.PathFacts?) -> Bool {
        guard let f = facts else { return false }
        return !f.isSymlink && f.isRegularFile && f.ownerUID == 0 && f.mode & 0o022 == 0 && !f.hasACL
    }

    /// The shell lines that refuse with `missingExit` unless the marker at
    /// `markerPath` counts, with every directory above it (from `/`) a real
    /// directory held to the same owner, mode and ACL checks. The primitives
    /// are the ones `InstalledCLIPreamble` checks the CLI with. Every
    /// checked path must be owned by one of `owners`; only the tests pass
    /// anything but root. Ends in a newline.
    static func shellCheck(markerPath: String = markerPath, owners: [UInt32] = [0]) -> String {
        let q = ShellQuote.quote
        let all = InstalledCLIPreamble.checkedPaths(cliPath: markerPath)
        let ancestors = all.dropLast().map(q).joined(separator: " ")
        let ownerTest = owners.map { "! -user \($0)" }.joined(separator: " ")
        return #"""
            dm_off() {
            	echo "k3sm app: refused: developer mode is off: $1" >&2
            	exit \#(missingExit)
            }
            dm_nl='
            '
            dm_held() {
            	bad=$(/usr/bin/find "$1" -maxdepth 0 \( \#(ownerTest) -o -perm -0020 -o -perm -0002 \) -print) || dm_off "$1 could not be checked"
            	if [ -n "$bad" ]; then dm_off "$1 is not owned by root, or is writable by group or others"; fi
            	listing=$(/bin/ls -led "$1") || dm_off "$1 could not be checked"
            	case "${listing%% *}" in *+) dm_off "$1 carries an ACL" ;; esac
            	case "$listing" in *"$dm_nl"*) dm_off "$1 carries an ACL" ;; esac
            }
            for p in \#(ancestors); do
            	if [ -L "$p" ]; then dm_off "$p is a symlink"; fi
            	if [ ! -d "$p" ]; then dm_off "$p is not a directory"; fi
            	dm_held "$p"
            done
            marker=\#(q(markerPath))
            if [ -L "$marker" ]; then dm_off "$marker is a symlink"; fi
            if [ ! -e "$marker" ]; then dm_off "$marker does not exist"; fi
            if [ ! -f "$marker" ]; then dm_off "$marker is not a regular file"; fi
            dm_held "$marker"

            """#
    }
}
