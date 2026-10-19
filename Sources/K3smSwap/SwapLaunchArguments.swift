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

/// SwapLaunchArguments reads the arguments the swap helper launches the app
/// with, from the app's own argument list (executable first), in the style
/// of `LaunchPolicy.isBackground`. A tag is taken only when it is a release
/// tag; anything else is ignored.
public struct SwapLaunchArguments: Equatable, Sendable {
    /// The app answers the helper's handshake once it is up.
    public static let handshake = "--handshake"
    /// The release this launch replaced: `--updated-from <tag>`.
    public static let updatedFrom = "--updated-from"
    /// The release that did not start, so this one is back:
    /// `--update-failed <tag>`. Anything that can launch the app can pass
    /// it, so a consumer that suppresses that release's offer must first
    /// read the journal and find it `rolledBack` (or stopped with a reason)
    /// for exactly that tag.
    public static let updateFailed = "--update-failed"

    /// Whether the app must write the handshake.
    public let answersHandshake: Bool
    /// The tag the app was updated from.
    public let updatedFromTag: String?
    /// The tag that failed to start.
    public let updateFailedTag: String?

    public init(arguments: [String]) {
        let args = Array(arguments.dropFirst())
        answersHandshake = args.contains(Self.handshake)
        updatedFromTag = Self.value(after: Self.updatedFrom, in: args)
        updateFailedTag = Self.value(after: Self.updateFailed, in: args)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, SwapTag.isReleaseTag(args[i + 1]) else { return nil }
        return args[i + 1]
    }
}
