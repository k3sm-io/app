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

/// FileIdentity is a file system object's identity: its volume's UUID and
/// its inode. The swap engine records the identity of the installed bundle
/// and of the incoming one before the swap and decides afterwards from the
/// identity actually at the target, never from a path's say-so.
///
/// The volume is named by its UUID (`ATTR_VOL_UUID`), not by `st_dev`:
/// `st_dev` comes from the disk node and can change across a reboot, and a
/// changed identity would read as "something else is at the target", the
/// one reading that leads the reconcile to forget a swap. A volume with no
/// UUID is named by its `st_dev`. `dev` is kept for the record only and takes
/// no part in equality.
public struct FileIdentity: Codable, Sendable {
    /// The volume's UUID, or `dev:<st_dev>` for a volume without one.
    public let volume: String
    public let ino: UInt64
    /// The `st_dev` seen when the identity was taken; not compared.
    public let dev: Int64

    public init(volume: String, ino: UInt64, dev: Int64 = 0) {
        self.volume = volume
        self.ino = ino
        self.dev = dev
    }

    /// The identity of `path` itself (`lstat`, so a symlink is its own
    /// object), or nil when nothing is there.
    public static func of(path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(volume: SwapVolume.uuid(path: path) ?? "dev:\(st.st_dev)", ino: UInt64(st.st_ino), dev: Int64(st.st_dev))
    }

    /// The identity of `name` inside the open directory `dirFD`, without
    /// following a symlink.
    public static func of(dirFD: Int32, name: String) -> FileIdentity? {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileIdentity(volume: SwapVolume.uuid(dirFD: dirFD, name: name) ?? "dev:\(st.st_dev)", ino: UInt64(st.st_ino),
                            dev: Int64(st.st_dev))
    }
}

extension FileIdentity: Hashable {
    public static func == (a: FileIdentity, b: FileIdentity) -> Bool {
        a.volume == b.volume && a.ino == b.ino
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(volume)
        hasher.combine(ino)
    }
}

/// SwapVolume answers the two volume questions a swap asks, through
/// `getattrlist`: the volume's UUID, and whether it can exchange two names
/// in one step (`VOL_CAP_INT_RENAME_SWAP`).
public enum SwapVolume {
    private static func attributes(_ call: (inout attrlist, UnsafeMutableRawBufferPointer) -> Int32) -> (caps: vol_capabilities_attr_t, uuid: uuid_t)? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES) | attrgroup_t(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: 256)
        let ok = buffer.withUnsafeMutableBytes { call(&list, $0) == 0 }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw in
            // The reply: a u_int32_t length, then the attributes in bit order.
            let caps = raw.loadUnaligned(fromByteOffset: 4, as: vol_capabilities_attr_t.self)
            let uuid = raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<vol_capabilities_attr_t>.size, as: uuid_t.self)
            return (caps, uuid)
        }
    }

    /// The UUID of the volume holding `path`, or nil.
    public static func uuid(path: String) -> String? {
        attributes { list, buffer in getattrlist(path, &list, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW)) }
            .flatMap { name($0.uuid) }
    }

    /// The UUID of the volume holding `name` in `dirFD`, or nil.
    public static func uuid(dirFD: Int32, name: String) -> String? {
        attributes { list, buffer in getattrlistat(dirFD, name, &list, buffer.baseAddress, buffer.count, UInt(FSOPT_NOFOLLOW)) }
            .flatMap { self.name($0.uuid) }
    }

    private static func name(_ uuid: uuid_t) -> String? {
        let value = UUID(uuid: uuid)
        return value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) ? nil : value.uuidString
    }

    /// Whether the volume holding `path` supports `RENAME_SWAP`; nil when
    /// the volume does not say.
    public static func supportsRenameSwap(path: String) -> Bool? {
        guard let caps = attributes({ list, buffer in getattrlist(path, &list, buffer.baseAddress, buffer.count, 0) })?.caps else {
            return nil
        }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let bit = UInt32(VOL_CAP_INT_RENAME_SWAP)
        let valid = withUnsafeBytes(of: caps.valid) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        let capable = withUnsafeBytes(of: caps.capabilities) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        guard valid & bit != 0 else { return nil }
        return capable & bit != 0
    }
}

/// FileOps holds the few file operations the swap needs, each by file
/// descriptor or without following a symlink. Nothing here opens an existing
/// file for writing: a new file is created exclusively and a bundle is only
/// ever renamed as a whole directory or removed entry by entry.
enum FileOps {
    /// Opens `path` as a directory, refusing a symlink in the last component.
    static func openDirectory(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    /// Opens `name` inside `dirFD` as a directory, refusing a symlink.
    static func openDirectory(at dirFD: Int32, _ name: String) -> Int32? {
        let fd = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    /// Whether `name` inside `dirFD` is a directory (not a symlink to one).
    static func isDirectory(at dirFD: Int32, _ name: String) -> Bool {
        var st = stat()
        return fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// ReadCheck is what a file must be before its bytes are trusted.
    struct ReadCheck {
        /// The owner the file must have, or nil for any.
        var owner: uid_t?
        /// The exact permission bits (`st_mode & 0o777`), or nil for any.
        var mode: mode_t?
        /// The largest size read; a larger file is refused.
        var limit: Int
    }

    /// Reads a regular file without following a symlink, after checking its
    /// owner, mode and size on the open descriptor. Nil on any failure.
    static func read(_ path: String, check: ReadCheck) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= check.limit else { return nil }
        if let owner = check.owner, st.st_uid != owner { return nil }
        if let mode = check.mode, st.st_mode & 0o777 != mode { return nil }
        var data = Data(count: Int(st.st_size))
        let size = Int(st.st_size)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            var done = 0
            while done < size {
                let n = Darwin.read(fd, buffer.baseAddress! + done, size - done)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                done += n
            }
            return true
        }
        return ok ? data : nil
    }

    /// Writes `data` to `name` in `dirFD` the durable way: a new temporary
    /// file created exclusively with `mode`, its bytes, `fsync`, a rename
    /// over `name`, then `fsync` of the directory. Returns false on any
    /// failure, leaving `name` as it was.
    static func replaceDurably(dirFD: Int32, name: String, data: Data, mode: mode_t) -> Bool {
        let temp = name + ".tmp-" + randomName(length: 12)
        let fd = openat(dirFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { buffer -> Bool in
                var done = 0
                while done < buffer.count {
                    let n = write(fd, buffer.baseAddress! + done, buffer.count - done)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    done += n
                }
                return true
            }
        }
        ok = ok && fullSync(fd)
        close(fd)
        guard ok, renameat(dirFD, temp, dirFD, name) == 0 else {
            unlinkat(dirFD, temp, 0)
            return false
        }
        return fullSync(dirFD)
    }

    /// Flushes `fd` to permanent storage: `fcntl(F_FULLFSYNC)`, because on
    /// macOS `fsync` does not flush the drive's cache. A file system that
    /// refuses it gets `fsync`, and the fallback is logged.
    @discardableResult
    static func fullSync(_ fd: Int32) -> Bool {
        if fcntl(fd, F_FULLFSYNC) == 0 { return true }
        SwapLog.logger.notice("sync: F_FULLFSYNC refused, used fsync")
        return fsync(fd) == 0
    }

    /// Whether `name` in `dirFD`, and everything under it when it is a
    /// directory, is owned by this account and writable by no group and no
    /// other user. Nothing is followed; a symlink counts as itself.
    ///
    /// This guards against other users. It does not stop the same user: a
    /// process running as this account can change the tree between this
    /// check and the swap. The binding control against the same user is the
    /// post-swap verification and the cdhash-bound handshake, which judge
    /// the bundle that is actually in place and the app that actually
    /// launched, never this check.
    static func isPrivateTree(at dirFD: Int32, _ name: String) -> Bool {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else {
            return false
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return true }
        guard let fd = openDirectory(at: dirFD, name) else { return false }
        defer { close(fd) }
        return entries(fd).allSatisfy { isPrivateTree(at: fd, $0) }
    }

    /// Removes `name` from `dirFD`: a file is unlinked, a directory is
    /// emptied entry by entry through descriptors (never following a
    /// symlink, so nothing outside it is touched) and then removed. Returns
    /// whether `name` is gone.
    @discardableResult
    static func removeTree(at dirFD: Int32, _ name: String) -> Bool {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return unlinkat(dirFD, name, 0) == 0 }
        guard let fd = openDirectory(at: dirFD, name) else { return false }
        for entry in entries(fd) {
            removeTree(at: fd, entry)
        }
        close(fd)
        return unlinkat(dirFD, name, AT_REMOVEDIR) == 0
    }

    /// The names in the open directory `fd`, without `.` and `..`. The
    /// descriptor stays open and owned by the caller.
    static func entries(_ fd: Int32) -> [String] {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            return []
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// A random name of `length` ASCII letters and digits, from
    /// `arc4random_uniform` (the system's secure source, without modulo bias).
    static func randomName(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet[Int(arc4random_uniform(UInt32(alphabet.count)))] })
    }

    /// `count` random bytes from `arc4random_buf`, as lowercase hex.
    static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return hex(bytes)
    }

    /// Lowercase hex of `bytes`.
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
