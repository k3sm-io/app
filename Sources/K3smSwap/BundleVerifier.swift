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
import K3smStatus
import Security

/// VerifiedBundle is what a verification established about a bundle.
public struct VerifiedBundle: Equatable, Sendable {
    /// The bundle's exact `K3smPayloadTag`; nil only when the caller did not
    /// require one and the bundle carries none (a kept previous copy built
    /// before the key).
    public let tag: String?
    /// The release that tag names.
    public let version: SemanticVersion?
    /// The main executable's code directory hash (`kSecCodeInfoUnique`).
    public let cdhash: Data
    /// The bundle directory's identity when it was checked.
    public let identity: FileIdentity
}

/// BundleVerifyError is why a bundle was refused.
public enum BundleVerifyError: Error, Equatable, Sendable {
    /// No bundle at the path, or it is a symlink.
    case missing
    /// The signature is invalid or does not satisfy the requirement.
    case signature(OSStatus)
    /// The sealed Info.plist's `CFBundleIdentifier` is not the app's, or its
    /// `CFBundleExecutable` is missing or not a plain file name.
    case bundleIdentifier
    /// The sealed Info.plist carries no valid `K3smPayloadTag`.
    case payloadTag
    /// The main executable's compiled Team ID stamp is missing, ambiguous,
    /// or not authorized to replace this app.
    case teamStamp
}

/// BundleVerifier checks a bundle before the swap engine renames or launches
/// it. The real one is `StaticCodeVerifier`.
public protocol BundleVerifier: Sendable {
    /// Verifies the bundle at `path`. With `requireTag` a bundle without a
    /// valid `K3smPayloadTag` is refused; without it (a kept previous copy,
    /// which may predate the key) a missing key is allowed, a malformed one
    /// is not.
    func verify(bundleAt path: String, requireTag: Bool) throws(BundleVerifyError) -> VerifiedBundle
}

/// StaticCodeVerifier verifies a bundle on disk:
///
/// 1. `SecStaticCodeCheckValidity` with all architectures, nested code and
///    strict validation, against the requirement text it was built with;
/// 2. the sealed Info.plist's `CFBundleIdentifier` is
///    `AppUpdateTrust.bundleIdentifier`;
/// 3. the sealed Info.plist carries a valid `K3smPayloadTag`
///    (`AppVersion.payloadTag(info:)`, never the short-version fallback),
///    unless the caller allows a bundle that predates the key;
/// 4. the main executable holds exactly one Team ID stamp, read as
///    `hack/check-team-pin.sh` reads it, which
///    `AppUpdateTrust.authorizesReplacement` accepts against the running
///    build's own pin.
///
/// It returns the main executable's cdhash, which the handshake binds to.
public struct StaticCodeVerifier: BundleVerifier {
    /// The code requirement text.
    public let requirement: String
    /// The Team ID compiled into the running build (`TeamIDPin.teamID`); nil
    /// for a developer build, which authorizes nothing.
    public let runningTeam: TeamID?

    public init(requirement: String, runningTeam: TeamID?) {
        self.requirement = requirement
        self.runningTeam = runningTeam
    }

    /// The largest main executable read for the stamp.
    static let executableLimit = 512 * 1024 * 1024

    public func verify(bundleAt path: String, requireTag: Bool) throws(BundleVerifyError) -> VerifiedBundle {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, let identity = FileIdentity.of(path: path) else {
            throw .missing
        }
        let checked = try Self.checkSignature(path: path, requirement: requirement)
        guard let plist = checked.info, plist["CFBundleIdentifier"] as? String == AppUpdateTrust.bundleIdentifier else {
            throw .bundleIdentifier
        }
        let tag = AppVersion.payloadTag(info: plist)
        if tag == nil, requireTag || plist[AppVersion.payloadTagKey] != nil { throw .payloadTag }
        guard let exe = plist["CFBundleExecutable"] as? String, !exe.isEmpty, !exe.contains("/"), exe != ".", exe != ".."
        else { throw .bundleIdentifier }
        guard let bytes = FileOps.read(path + "/Contents/MacOS/" + exe, check: .init(limit: Self.executableLimit)),
              AppUpdateTrust.authorizesReplacement(running: runningTeam, staged: TeamStamp.read(bytes))
        else { throw .teamStamp }
        // The identity again: the directory checked is the one recorded.
        guard FileIdentity.of(path: path) == identity else { throw .missing }
        return VerifiedBundle(tag: tag, version: tag.flatMap(SemanticVersion.init), cdhash: checked.cdhash, identity: identity)
    }

    /// The validity check against `requirement`, returning the sealed
    /// Info.plist and the main executable's cdhash.
    static func checkSignature(path: String, requirement: String) throws(BundleVerifyError) -> (info: [String: Any]?, cdhash: Data) {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw .signature(status) }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard status == errSecSuccess, let req else { throw .signature(status) }
        // No network: the notarization ticket is read from the bundle
        // (stapled) or the local cache, so a check never waits on a server.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
            | SecCSFlags.noNetworkAccess.rawValue)
        status = SecStaticCodeCheckValidity(code, flags, req)
        guard status == errSecSuccess else { throw .signature(status) }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(code, [], &info)
        guard status == errSecSuccess, let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data
        else { throw .signature(status) }
        return (dict[kSecCodeInfoPList as String] as? [String: Any], unique)
    }

    /// The cdhash of the code at `path` (a bundle or a loose Mach-O) after it
    /// satisfies `requirement`, or nil.
    public static func cdhash(path: String, requirement: String) -> Data? {
        try? checkSignature(path: path, requirement: requirement).cdhash
    }
}

/// TeamStamp reads the Team ID pin compiled into an executable the way
/// `hack/check-team-pin.sh` does: every occurrence of `TeamIDPin.marker` and
/// the printable bytes after it; the bare marker may appear at most once,
/// and exactly one occurrence may carry a suffix, which must be a Team ID.
public enum TeamStamp {
    /// The stamp's Team ID, or nil for none, an ambiguous one or a malformed
    /// one.
    public static func read(_ bytes: Data) -> TeamID? {
        let marker = Array(TeamIDPin.marker.utf8)
        var bare = 0
        var stamps: [String] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= marker.count, let first = marker.first else { return }
            var i = 0
            let end = b.count - marker.count
            while i <= end {
                if b[i] == first && marker.indices.allSatisfy({ b[i + $0] == marker[$0] }) {
                    var j = i + marker.count
                    while j < b.count, (0x20...0x7E).contains(b[j]) { j += 1 }
                    if j == i + marker.count {
                        bare += 1
                    } else {
                        stamps.append(String(decoding: b[(i + marker.count)..<j], as: UTF8.self))
                    }
                    i = j
                } else {
                    i += 1
                }
            }
        }
        guard bare <= 1, stamps.count == 1 else { return nil }
        return TeamID(stamps[0])
    }
}

/// InstalledRelease is the release the bundle at the target carries, read
/// from its Info.plist: the floor a staged bundle must be strictly above,
/// and the tag its previous copy is named by. A bundle built before
/// `K3smPayloadTag` counts by its short version, as the app's own reading
/// does (`AppVersion.payloadRelease(info:)`); a development build carries no
/// release and is never updated.
public struct InstalledRelease: Equatable, Sendable {
    public let tag: String
    public let version: SemanticVersion

    /// Reads `<bundle>/Contents/Info.plist` without following a symlink.
    public static func read(bundleAt path: String) -> InstalledRelease? {
        guard let data = FileOps.read(path + "/Contents/Info.plist", check: .init(limit: 1024 * 1024)),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = AppVersion.payloadRelease(info: info)
        else { return nil }
        let tag = AppVersion.payloadTag(info: info) ?? "v" + version.description
        guard SwapTag.isReleaseTag(tag) else { return nil }
        return InstalledRelease(tag: tag, version: version)
    }
}
