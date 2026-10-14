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

/// TeamIDPin is the Team ID compiled into this binary: the one trust source
/// for the designated requirement the root step pins. It is never read from
/// Info.plist or any other resource, which the signature seals but which a
/// reader of the bundle could mistake for a setting.
///
/// The committed value is the bare marker, so a developer build pins no team
/// and the window disables every privileged action with its reason. A release
/// build runs `hack/build-app.sh --team-id <ID>`, which compiles a copy of the
/// source where `TeamIDStamp.swift` carries the marker followed by the Team ID;
/// `hack/release/sign-and-notarize.sh` refuses a binary whose stamp names any
/// other team.
public enum TeamIDPin {
    /// The prefix every stamp starts with. The release scripts grep the
    /// binary for `<marker><TeamID>`.
    public static let marker = "k3sm-team-id-pin:"

    /// The team this binary pins, or nil for a developer build.
    public static var teamID: TeamID? { parse(TeamIDStamp.value) }

    /// Reads a stamp: the marker followed by exactly one Team ID, or nil.
    static func parse(_ stamp: String) -> TeamID? {
        guard stamp.hasPrefix(marker) else { return nil }
        return TeamID(String(stamp.dropFirst(marker.count)))
    }
}
