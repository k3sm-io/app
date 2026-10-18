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

/// LaunchPolicy reads how the app was launched from its own arguments.
public enum LaunchPolicy {
    /// The launch contract with the k3sm CLI: after `k3sm install`, a join
    /// and `k3sm start`, the CLI launches the app with this argument so the
    /// status item appears with the window hidden, as at login.
    public static let backgroundArgument = "--background"

    /// Whether `arguments` (the process's, executable first) carry the exact
    /// `backgroundArgument` token; a near miss is ignored.
    public static func isBackground(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(backgroundArgument)
    }
}
