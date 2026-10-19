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

/// LaunchError is why a launch did not produce a running process.
public enum LaunchError: Error, Equatable, Sendable {
    case failed
}

/// AppLauncher launches the bundle at a path with arguments and names the
/// process it started. The real one, `WorkspaceLauncher`, lives in the
/// helper executable, so this library imports no AppKit.
public protocol AppLauncher: Sendable {
    func launch(bundleAt path: String, arguments: [String]) throws(LaunchError) -> ProcessIdentity
}
