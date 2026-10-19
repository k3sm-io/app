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

import AppKit
import CoreServices
import Foundation
import K3smSwap

/// WorkspaceLauncher is the real `AppLauncher`: `LSRegisterURL` on the
/// target, so LaunchServices reads the new bundle, then
/// `NSWorkspace.openApplication` with `createsNewApplicationInstance` off,
/// so no second instance starts (never `open -n`). The completion arrives on
/// a background queue and is bridged with a semaphore.
struct WorkspaceLauncher: AppLauncher {
    /// How long the launch may take before it counts as failed.
    static let launchBound: Duration = .seconds(30)

    init() {}

    func launch(bundleAt path: String, arguments: [String]) throws(LaunchError) -> ProcessIdentity {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        _ = LSRegisterURL(url as CFURL, true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.arguments = arguments
        configuration.activates = false
        configuration.addsToRecentItems = false
        let result = LaunchResult()
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            result.set(app?.processIdentifier)
            done.signal()
        }
        let seconds = Double(Self.launchBound.components.seconds)
        guard done.wait(timeout: .now() + seconds) == .success, let pid = result.get(),
              let identity = ProcessIdentity.of(pid: pid)
        else { throw .failed }
        return identity
    }
}

/// LaunchResult carries the launched pid from the completion handler's
/// queue to the waiting thread.
private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?

    func set(_ value: Int32?) {
        lock.lock()
        pid = value
        lock.unlock()
    }

    func get() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }
}
