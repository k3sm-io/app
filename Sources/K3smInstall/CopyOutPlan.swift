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

import K3smStatus

/// CopyOutAction is what the root step runs once the staged copy verifies.
public enum CopyOutAction: Hashable, Sendable {
    /// Install a server on this Mac (first run, "Start a cluster").
    case startServer
    /// Install a worker that joins `server`; the join token arrives on stdin.
    case join(ServerAddress)
    /// Re-run the install over an existing one (the in-place upgrade).
    case update
    /// Remove k3sm; `purge` also deletes its data.
    case uninstall(purge: Bool)

    /// The sentence the administrator prompt shows. Fixed text per action:
    /// nothing typed by the user or read from the CLI appears in it.
    public var prompt: String {
        switch self {
        case .startServer: return "k3sm wants to install a k3sm server on this Mac."
        case .join: return "k3sm wants to install k3sm on this Mac and join it to a cluster."
        case .update: return "k3sm wants to update the k3sm installed on this Mac."
        case .uninstall(purge: false): return "k3sm wants to uninstall k3sm from this Mac and keep its data."
        case .uninstall(purge: true): return "k3sm wants to uninstall k3sm from this Mac and delete its data."
        }
    }

    /// Whether the root step reads the join token from stdin.
    public var readsToken: Bool {
        if case .join = self { return true }
        return false
    }
}

/// CopyOutPlan is the root step as data: which app bundle to copy, where root
/// stages it, which signature it must carry, and what runs afterwards. Root
/// runs nothing from the bundle in /Applications, which an admin user can
/// rewrite; it copies the whole bundle into a fresh root-owned directory,
/// verifies the copy, and runs only the copy.
public struct CopyOutPlan: Hashable, Sendable {
    /// The root-owned directory every staged copy lives under.
    public static let stagingRoot = "/Library/k3sm.staging"
    /// The lock that serializes copy-outs, so one run's start-up sweep can
    /// never remove another run's staged copy.
    public static let lockPath = "/Library/k3sm.staging.lock"
    /// The directory of the root-created log the app tails.
    public static let logDirectory = "/Library/Logs/k3sm"
    /// The log one copy-out writes; each run truncates it.
    public static let logPath = "/Library/Logs/k3sm/copy-out.log"
    /// The staged bundle's name inside its staging directory.
    public static let stagedBundleName = "k3sm.app"
    /// The CLI inside a bundle, relative to the bundle root.
    public static let payloadCLI = "Contents/Resources/payload/k3sm"
    /// The join token's file name inside the staging directory.
    public static let tokenFileName = "join-token"

    /// The absolute path of the app bundle to copy.
    public let bundlePath: String
    /// The payload's version, which names the staging directory.
    public let payloadVersion: SemanticVersion
    /// The team whose Developer ID signature the copy must carry.
    public let teamID: TeamID
    public let action: CopyOutAction

    /// PlanError says why a plan was refused before any script was rendered.
    public enum PlanError: Error, Equatable, Sendable {
        case bundlePathNotAbsolute
        case bundlePathNotAnApp
        case bundlePathNotCanonical
        case bundlePathHasControlCharacter
    }

    /// Creates a plan. The bundle path must be absolute, canonical (no empty,
    /// `.` or `..` component) and end in `.app`; control characters are
    /// refused outright even though the script would quote them.
    public init(bundlePath: String, payloadVersion: SemanticVersion, teamID: TeamID, action: CopyOutAction) throws(PlanError) {
        guard bundlePath.hasPrefix("/") else { throw .bundlePathNotAbsolute }
        guard !bundlePath.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .bundlePathHasControlCharacter
        }
        let components = bundlePath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw .bundlePathNotCanonical
        }
        guard let last = components.last, last.count > 4, last.hasSuffix(".app") else { throw .bundlePathNotAnApp }
        self.bundlePath = bundlePath
        self.payloadVersion = payloadVersion
        self.teamID = teamID
        self.action = action
    }

    /// The `mktemp -d` template for this run's staging directory:
    /// `<stagingRoot>/<version>.XXXXXXXX`, made unique by mktemp as root.
    public var stagingTemplate: String {
        "\(Self.stagingRoot)/\(payloadVersion).XXXXXXXX"
    }

    /// The code requirement the staged copy must satisfy.
    public var designatedRequirement: String {
        DesignatedRequirement.developerID(teamID: teamID)
    }
}
