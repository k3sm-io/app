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

/// Renamer performs the engine's renames, each relative to directory file
/// descriptors opened before the first one. It returns 0 or the errno.
public protocol Renamer: Sendable {
    /// Exchanges `from` in `fromDir` and `to` in `toDir` in one step
    /// (`renameatx_np` with `RENAME_SWAP`); both must exist.
    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32
    /// Moves `from` in `fromDir` to `to` in `toDir`, refusing to replace an
    /// existing `to` (`renameatx_np` with `RENAME_EXCL`).
    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32
}

/// SystemRenamer is the real `Renamer`.
public struct SystemRenamer: Renamer {
    public init() {}

    public func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        renameatx_np(fromDir, from, toDir, to, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    public func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        renameatx_np(fromDir, from, toDir, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
}

/// RenameOutcome is what a swap's errno means for the update.
public enum RenameOutcome: Equatable, Sendable {
    /// The bundles were exchanged.
    case done
    /// `EXDEV`: the staged copy is on another volume. The engine copies it
    /// onto the target's volume, verifies the copy and retries once.
    case crossDevice
    /// `ENOTSUP`: the volume cannot exchange two names in one step.
    case unsupportedVolume
    /// `EPERM` (macOS refused the rename: App Management, a MAC policy) or
    /// `EACCES` (this account cannot write the target's directory, as a
    /// standard user cannot write `/Applications`): the update needs the
    /// administrator path, which reads this outcome from the journal's
    /// reason and takes over the verified staged copy.
    case needsAdministrator
    /// `EROFS`: the target's volume is mounted read-only.
    case readOnlyVolume
    /// Any other errno, `ENOENT` included. There is no plain-rename
    /// fallback: the target always exists, so a missing name is an error.
    case failed(Int32)

    public init(errno code: Int32) {
        switch code {
        case 0: self = .done
        case EXDEV: self = .crossDevice
        case ENOTSUP: self = .unsupportedVolume
        case EPERM, EACCES: self = .needsAdministrator
        case EROFS: self = .readOnlyVolume
        default: self = .failed(code)
        }
    }

    /// The sentence the app shows for an outcome that stops the update, nil
    /// for the others.
    public var message: String? {
        switch self {
        case .unsupportedVolume: return "Move k3sm.app to Applications on the startup disk"
        case .needsAdministrator: return "Updating k3sm.app needs an administrator"
        case .readOnlyVolume: return "Move k3sm.app to Applications to get updates"
        case .failed: return "k3sm.app could not be replaced; it was left as it was"
        case .done, .crossDevice: return nil
        }
    }
}

/// DittoCopier copies a bundle to a new path, for the cross-volume case:
/// `/usr/bin/ditto --norsrc --noextattr --noqtn --noacl`, by absolute path
/// and never through a shell. The destination must not exist yet, so the
/// copy only ever creates files. A copy still running at the bound (a
/// stalled network volume) is terminated, then killed, and counts as failed.
enum DittoCopier {
    /// How long a copy may take.
    static let bound: Duration = .seconds(600)

    static func copy(from source: String, to destination: String) -> Bool {
        var st = stat()
        guard lstat(destination, &st) != 0, errno == ENOENT else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--norsrc", "--noextattr", "--noqtn", "--noacl", source, destination]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if process.isRunning, done.wait(timeout: .now() + Double(bound.components.seconds)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
