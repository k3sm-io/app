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
import Security

/// HandshakeMessage is what the relaunched app writes to the private
/// directory's handshake file once it is up: the request's token and its
/// own pid.
public struct HandshakeMessage: Codable, Equatable, Sendable {
    public let token: String
    public let pid: Int32

    public init(token: String, pid: Int32) {
        self.token = token
        self.pid = pid
    }
}

/// HandshakeCheck is the helper's side: it accepts a handshake only from the
/// process it launched, running the code it verified. All of these must hold:
///
/// - the file is a regular file owned by this account, mode 0600, small;
/// - its pid is the launched pid, and that pid still has the launched start
///   time;
/// - the running code of that pid (`SecCodeCopyGuestWithAttributes`) passes
///   `SecCodeCheckValidity` against the app requirement;
/// - its `kSecCodeInfoUnique` equals the cdhash of the target's main
///   executable, recorded from the static code before the launch;
/// - the token is the request's.
///
/// A handshake file from any other process fails one of these and is
/// ignored.
public struct HandshakeCheck: Sendable {
    public let paths: SwapPaths
    public let requirement: String

    public init(paths: SwapPaths, requirement: String) {
        self.paths = paths
        self.requirement = requirement
    }

    /// Whether the handshake file now holds an acceptable answer.
    public func accepts(token: String, launched: ProcessIdentity, cdhash: Data) -> Bool {
        guard let data = FileOps.read(paths.handshakePath, check: .init(owner: getuid(), mode: 0o600, limit: 4096)),
              let message = try? JSONDecoder().decode(HandshakeMessage.self, from: data),
              message.pid == launched.pid, launched.isRunning,
              Self.runningCDHash(pid: launched.pid, requirement: requirement) == cdhash,
              launched.isRunning
        else { return false }
        return Self.constantTimeEqual(message.token, token)
    }

    /// The cdhash of the code running as `pid`, after it satisfies
    /// `requirement`; nil otherwise.
    static func runningCDHash(pid: Int32, requirement: String) -> Data? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req,
              SecCodeCheckValidity(code, [], req) == errSecSuccess
        else { return nil }
        // The running guest's code on disk, through the documented bridge.
        // SecCodeCheckValidity above checked the dynamic code: the kernel
        // still holds it valid and it matches this static code, so the
        // static cdhash is the running one. The kernel's own view
        // (csops CS_OPS_CDHASH) is not in the public SDK and is not used.
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Removes a handshake file left from an earlier request.
    public func clear() {
        unlink(paths.handshakePath)
    }
}

/// HandshakeAnswer is the app's side: after a launch with `--handshake`,
/// once its own signature checks pass and its status item is up, the app
/// writes the request's token and its pid (temporary file, fsync, rename).
public enum HandshakeAnswer {
    /// Writes the answer for the request in `paths`' private directory.
    /// Returns false when there is no readable request or the write fails.
    @discardableResult
    public static func write(paths: SwapPaths, pid: Int32 = getpid()) -> Bool {
        let store = JournalStore(paths: paths)
        guard let journal = try? store.read(), !journal.state.isTerminal,
              let data = try? JSONEncoder().encode(HandshakeMessage(token: journal.request.token, pid: pid)),
              let dirFD = FileOps.openDirectory(paths.privateDirectory)
        else { return false }
        defer { close(dirFD) }
        return FileOps.replaceDurably(dirFD: dirFD, name: SwapPaths.handshakeName, data: data, mode: 0o600)
    }
}
