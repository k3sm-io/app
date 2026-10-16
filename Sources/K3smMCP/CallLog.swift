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

/// CallLog appends one line per `tools/call` to a user-owned file: the time,
/// the tool, the outcome and how long it took. It never records an
/// argument, a result or anything the cluster printed, and a call whose tool
/// name is not one of `ToolName` is recorded as `tool=unknown`, so nothing an
/// agent sent reaches the file. The file is set to 0600 on every open
/// (`fchmod`, whatever the umask or an earlier mode), never followed through
/// a symlink, appended only while it is a regular file this user owns, and
/// moved aside to `<path>.1` once it passes `maxBytes`. A write
/// that fails is dropped: the log never fails a call.
public struct CallLog: Sendable {
    /// Where the log goes, under the home directory.
    public static let relativePath = "Library/Logs/k3sm-mcp.log"
    /// The size past which the file is moved aside before the next line.
    public static let maxBytes = 1 << 20

    public let path: String
    let maxBytes: Int
    let now: @Sendable () -> Date

    public init(path: String, maxBytes: Int = CallLog.maxBytes, now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.maxBytes = maxBytes
        self.now = now
    }

    /// The log for the user whose home is `home`, nil when `home` is not an
    /// absolute path.
    public static func forHome(_ home: String) -> CallLog? {
        guard home.hasPrefix("/") else { return nil }
        return CallLog(path: (home as NSString).appendingPathComponent(relativePath))
    }

    /// One line, without its line break.
    public static func line(at date: Date, tool: ToolName?, outcome: CallOutcome, milliseconds: Int) -> String {
        "\(date.formatted(.iso8601)) tool=\(tool?.rawValue ?? "unknown") outcome=\(outcome.rawValue) ms=\(max(0, milliseconds))"
    }

    /// Appends one call's line.
    public func append(tool: ToolName?, outcome: CallOutcome, milliseconds: Int) {
        let text = Self.line(at: now(), tool: tool, outcome: outcome, milliseconds: milliseconds) + "\n"
        guard var fd = open() else { return }
        var st = stat()
        if fstat(fd, &st) == 0, Int(st.st_size) >= maxBytes {
            Darwin.close(fd)
            _ = rename(path, path + ".1")
            guard let reopened = open() else { return }
            fd = reopened
        }
        defer { Darwin.close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Opens the file for appending, creating it 0600; nil when it is a
    /// symlink, not a regular file, or owned by another user.
    private func open() -> Int32? {
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else {
            Darwin.close(fd)
            return nil
        }
        // O_CREAT's mode applies only to a new file and is narrowed by the
        // umask; an existing file keeps its own. Set 0600 either way.
        guard fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
