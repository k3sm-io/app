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
import K3smStatus

/// SwapPaths is every location a self-update touches, derived from the
/// account's passwd entry (`getpwuid(getuid())`) and a few compiled-in names,
/// never from an argument, the environment or the request file:
///
/// - the private directory `~/Library/Application Support/io.k3sm.app/update/`
///   (0700): the request file that is also the journal, the handshake file,
///   the lock, and the swap helper's verified copy;
/// - the previous root `~/Library/Application Support/io.k3sm.app/previous/`:
///   the one kept copy of the bundle the last update replaced, named
///   `k3sm-<tag>.previous`, with no `.app` extension and outside
///   `/Applications`, so LaunchServices never registers it;
/// - the staging grammar `<target dir>/.k3sm.app.update-<8+ letters and
///   digits>/k3sm.app`, a hidden sibling on the target's own volume;
/// - the targets: `/Applications/k3sm.app` and `~/Applications/k3sm.app`.
///
/// Tests inject the home and the Applications roots; the helper and the app
/// use `forCurrentUser()`.
public struct SwapPaths: Equatable, Sendable {
    /// The bundle name every target and staged copy carries.
    public static let bundleName = "k3sm.app"
    /// The staging directory name's prefix; a random suffix of at least
    /// eight letters and digits follows it.
    public static let stagingPrefix = ".k3sm.app.update-"
    /// The private directory's file names.
    public static let requestName = "request.json"
    public static let handshakeName = "handshake"
    public static let lockName = "lock"
    public static let helperName = "k3sm-app-update"
    /// The helper inside the app bundle.
    public static let bundledHelperPath = "Contents/Helpers/k3sm-app-update"
    /// The previous copy's name pattern: `k3sm-<tag>.previous`.
    public static let previousPrefix = "k3sm-"
    public static let previousSuffix = ".previous"

    /// The account's home directory.
    public let home: String
    /// The directories a target may sit in, each holding `k3sm.app`.
    public let applicationsRoots: [String]

    /// Paths for an injected home and Applications roots (tests).
    public init(home: String, applicationsRoots: [String]) {
        self.home = home
        self.applicationsRoots = applicationsRoots
    }

    /// Paths for the account running this process, from its passwd entry;
    /// nil when there is none or its home is not an absolute path.
    public static func forCurrentUser() -> SwapPaths? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        guard home.hasPrefix("/"), home.count > 1, !home.contains("/../") else { return nil }
        return SwapPaths(home: home, applicationsRoots: ["/Applications", home + "/Applications"])
    }

    /// The app's support directory, which holds `update` and `previous`.
    public var supportDirectory: String { home + "/Library/Application Support/io.k3sm.app" }
    /// The private 0700 directory.
    public var privateDirectory: String { supportDirectory + "/update" }
    /// The previous root.
    public var previousDirectory: String { supportDirectory + "/previous" }
    public var requestPath: String { privateDirectory + "/" + Self.requestName }
    public var handshakePath: String { privateDirectory + "/" + Self.handshakeName }
    public var lockPath: String { privateDirectory + "/" + Self.lockName }
    /// Where the app copies the helper before it runs it.
    public var helperCopyPath: String { privateDirectory + "/" + Self.helperName }
    /// The engine's own record of the previous copy it kept
    /// (`PreviousRecord`).
    public var previousRecordPath: String { privateDirectory + "/" + Self.previousRecordName }
    public static let previousRecordName = "previous.json"

    /// The targets a request may name, exactly.
    public var allowedTargets: [String] { applicationsRoots.map { $0 + "/" + Self.bundleName } }

    /// The previous copy's name for a bundle carrying `tag`.
    public static func previousName(tag: String) -> String {
        previousPrefix + tag + previousSuffix
    }

    /// The tag a previous copy's name carries, when the name is exactly
    /// `k3sm-<release tag>.previous`.
    public static func tag(ofPreviousName name: String) -> String? {
        guard name.hasPrefix(previousPrefix), name.hasSuffix(previousSuffix) else { return nil }
        let tag = String(name.dropFirst(previousPrefix.count).dropLast(previousSuffix.count))
        return SwapTag.isReleaseTag(tag) ? tag : nil
    }

    /// Whether `name` is a staging directory name: the prefix and 8 to 32
    /// ASCII letters or digits, nothing else (so no `/`, no `..`).
    public static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(stagingPrefix) else { return false }
        let suffix = name.utf8.dropFirst(stagingPrefix.utf8.count)
        return (8...32).contains(suffix.count) && suffix.allSatisfy { b in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
        }
    }

    /// A new staging directory name: the prefix and 12 random letters and
    /// digits.
    public static func newStagingName() -> String {
        stagingPrefix + FileOps.randomName(length: 12)
    }

    /// The staging directory for `target` (an allowed target) and a staging
    /// name: `<target dir>/<name>`. The staged bundle is `k3sm.app` in it.
    /// This is the one place the staging location is defined; the download
    /// that fills it uses it too.
    public static func stagingDirectory(target: String, name: String) -> String {
        (target as NSString).deletingLastPathComponent + "/" + name
    }

    /// TargetRefusal is why a bundle location cannot be updated in place.
    public enum TargetRefusal: Equatable, Sendable {
        /// Not one of the allowed targets.
        case notAllowed
        /// The bundle runs from an App Translocation mount.
        case translocated
        /// The bundle's volume is mounted read-only (the disk image).
        case readOnly
        /// The target or a directory above it is a symlink, or it is not a
        /// directory.
        case notADirectory
        /// The target's volume cannot exchange two names in one step
        /// (`VOL_CAP_INT_RENAME_SWAP`).
        case unsupportedVolume
        /// The previous root (under the home folder) is on another volume
        /// than the target, so the old bundle could not leave the
        /// Applications directory by a rename. The volume itself is fine;
        /// the fix is not a different file system.
        case previousOnOtherVolume

        /// The sentence the app shows for this refusal.
        public var message: String {
            switch self {
            case .notAllowed, .translocated, .readOnly, .notADirectory:
                return "Move k3sm.app to Applications to get updates"
            case .unsupportedVolume:
                return "Move k3sm.app to Applications on the startup disk"
            case .previousOnOtherVolume:
                return "k3sm.app and your home folder are on different disks, so updates cannot keep the old copy"
            }
        }
    }

    /// Why the target's volume cannot take a swap, or nil when it can: the
    /// volume must support `RENAME_SWAP`, and the previous root must be on
    /// the same volume (compared by volume UUID), because the old bundle
    /// leaves the Applications directory by a rename, and a rename never
    /// crosses volumes. Checked before the app quits, by the app before it
    /// starts the helper and by the helper before it waits, so a volume that
    /// cannot take the swap is never discovered after the app is gone.
    ///
    /// Refusing a target on another volume than the home folder, rather than
    /// keeping the previous copy on the target's volume, keeps the one
    /// previous location outside every Applications folder and owned by this
    /// account; on a second volume it would have to sit in a folder the app
    /// creates at that volume's root.
    public func volumeRefusal(target path: String) -> TargetRefusal? {
        let parent = (path as NSString).deletingLastPathComponent
        guard SwapVolume.supportsRenameSwap(path: parent) == true else { return .unsupportedVolume }
        let previousSide = FileManager.default.fileExists(atPath: supportDirectory) ? supportDirectory : home + "/Library"
        guard let targetVolume = SwapVolume.uuid(path: parent), let previousVolume = SwapVolume.uuid(path: previousSide),
              targetVolume == previousVolume
        else { return .previousOnOtherVolume }
        return nil
    }

    /// Why `path` cannot be updated in place, or nil when it can: it must be
    /// exactly an allowed target, not under an `AppTranslocation` directory,
    /// on a volume not mounted read-only, and a real directory whose parent
    /// resolves to itself (no symlink anywhere above it).
    public func refusal(target path: String) -> TargetRefusal? {
        if path.contains("/AppTranslocation/") { return .translocated }
        var fs = statfs()
        if statfs(path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnly }
        guard allowedTargets.contains(path) else { return .notAllowed }
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else { return .notADirectory }
        defer { free(resolved) }
        guard String(cString: resolved) == parent else { return .notADirectory }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .notADirectory }
        return nil
    }
}

/// SwapTag is the release tag grammar a self-update reads and writes: the
/// exact grammar of `K3smPayloadTag` (`vMAJOR.MINOR.PATCH` with an optional
/// `-rc.N`), which also makes it safe as a file name.
public enum SwapTag {
    /// Whether `tag` is a release tag.
    public static func isReleaseTag(_ tag: String) -> Bool {
        AppVersion.releaseTagVersion(tag) != nil
    }
}
