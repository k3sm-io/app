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

/// QuitPolicy decides what Quit does. By default the app quits and k3sm keeps
/// running, as k3s keeps running when nothing is watching it. With the
/// General preference `AppPreferences.Key.stopOnQuit` on, a Quit while k3sm
/// runs first goes through the app's Stop action (its question, the
/// multi-node warning and the administrator prompt) and quits only once the
/// stop succeeded. A stop that fails, is refused, or is answered no keeps the
/// app open and says so; the user can quit again or turn the preference off.
/// A Quit because the session is ending (log out, restart, shut down) never
/// asks anything: it quits, and k3sm keeps running.
public enum QuitPolicy {
    /// What Quit does next.
    public enum Decision: Equatable, Sendable {
        /// Quit now, k3sm untouched.
        case quit
        /// Run the Stop action, then quit when it succeeded.
        case stopThenQuit
        /// Stay open, with this message for the alert.
        case stay(String)
    }

    /// The Settings toggle's label.
    public static let toggleLabel = "Stop k3sm when I quit the app"
    /// The line under the toggle.
    public static let paneNote = "When this is off, k3sm keeps running after the app quits."
    /// The alert's title when the app stays open.
    public static let stayTitle = "k3sm is still open"

    /// The decision when Quit is chosen. `state` is read from a status report
    /// taken at the Quit; an unreadable one keeps the app open, since the
    /// stop could not run on it.
    public static func decide(stopOnQuit: Bool, state: LifecycleState, sessionEnding: Bool = false) -> Decision {
        guard stopOnQuit, !sessionEnding else { return .quit }
        switch state {
        case .running:
            return .stopThenQuit
        case .stopped, .notInstalled:
            return .quit
        case .unreadable:
            return .stay("The app could not read the status of this Mac, so it did not stop k3sm. " + retry)
        }
    }

    /// The decision once the Stop action ended: true quits; false (it failed,
    /// was refused, or the administrator prompt was cancelled) and nil (the
    /// question was answered no) keep the app open.
    public static func afterStop(succeeded: Bool?) -> Decision {
        switch succeeded {
        case true?:
            return .quit
        case false?:
            return .stay("k3sm did not stop, so the app did not quit. " + retry)
        case nil:
            return .stay("k3sm was not stopped, so the app did not quit. " + retry)
        }
    }

    private static let retry = "Quit again to try again, or turn off \u{201C}\(toggleLabel)\u{201D} in Settings > General."
}
