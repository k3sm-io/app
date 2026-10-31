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

import Darwin
import Foundation
import K3smInstall

/// HelperChain is the location check of the helper's root mode
/// (`--admin-swap`): the helper runs as root only from the root-owned copy
/// the administrator path's script makes under the copy-out staging root.
public enum HelperChain {
    /// What the check reads of one path, without following a symlink.
    public struct Entry: Equatable, Sendable {
        public let isSymlink: Bool
        public let owner: uid_t
        public let mode: mode_t

        public init(isSymlink: Bool, owner: uid_t, mode: mode_t) {
            self.isSymlink = isSymlink
            self.owner = owner
            self.mode = mode
        }
    }

    /// `lstat` of a path, or nil when it cannot be read.
    public static func lstatEntry(_ path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Entry(isSymlink: (st.st_mode & S_IFMT) == S_IFLNK, owner: st.st_uid, mode: st.st_mode)
    }

    /// Whether `path` is under `AppSwapRoot.helperStagePrefix`, absolute with
    /// no empty, `.` or `..` component, and every directory from
    /// `CopyOutPlan.stagingRoot` down to it, and `path` itself, is owned by
    /// root, not a symlink, and writable by no group and no other user.
    /// `entry` reads each path; the helper passes `lstatEntry`.
    public static func isRootOwned(_ path: String, entry: (String) -> Entry? = lstatEntry) -> Bool {
        let stagingRoot = CopyOutPlan.stagingRoot
        guard path.hasPrefix(AppSwapRoot.helperStagePrefix), AdminSwapEngine.isCanonicalAbsolute(path) else { return false }
        var current = path
        while current.count >= stagingRoot.count {
            guard let e = entry(current), !e.isSymlink, e.owner == 0, e.mode & 0o022 == 0 else { return false }
            if current == stagingRoot { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}
