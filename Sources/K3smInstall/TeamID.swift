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

/// TeamID is an Apple Developer Team ID: exactly ten uppercase ASCII letters
/// or digits. It is the one value the designated requirement is built from.
public struct TeamID: Hashable, Sendable, CustomStringConvertible {
    /// The Info.plist key the release signing step stamps with the Team ID.
    /// An ad-hoc developer build has no such key.
    public static let infoPlistKey = "K3smTeamID"

    public let value: String

    /// Accepts a Team ID, or returns nil for anything that is not one.
    public init?(_ value: String) {
        guard value.utf8.count == 10,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) })
        else { return nil }
        self.value = value
    }

    public var description: String { value }
}

/// DesignatedRequirement is the code requirement root checks the staged copy
/// of the app against before running anything from it: an Apple-anchored
/// Developer ID Application certificate issued to the k3sm team. Mac App
/// Store, Apple Development and ad-hoc signatures all fail it.
public enum DesignatedRequirement {
    /// The requirement text for a Developer ID Application signature from
    /// `teamID`. The Team ID grammar admits no quote or backslash, so the value
    /// cannot break out of its string.
    public static func developerID(teamID: TeamID) -> String {
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(teamID.value)\""
    }
}
