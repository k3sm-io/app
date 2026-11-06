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

/// UpdateChannelOutcome says what a `k3sm update channel <value>` exit means. The
/// CLI's exits are its own (`cmd/k3sm/updatechannel.go`, `setUpdateChannel`): 0 set
/// and checked; 1 the write did not complete (a timeout can follow a write the server kept), whether no cluster client, Forbidden or a
/// CRD the server does not serve yet, which only its error text tells apart; 2 usage,
/// as from a k3sm with no such verb; 3 written, and the check after it failed. Every
/// other status falls to `LifecycleOutcome.text`'s shared table.
public enum UpdateChannelOutcome {
    /// The sentence for `status`, or nil when the shared table's is the one.
    public static func text(status: Int32, channel: UpdateChannel) -> String? {
        switch status {
        case LifecycleExit.failed:
            return "k3sm could not confirm setting the update channel to \(channel.rawValue): the cluster could not be reached, refused the write, "
                + "or does not serve the setting yet. The setting may or may not have been applied; the picker shows what the cluster reports. "
                + "No update started. Try again in a minute; if it keeps failing, check the server's k3sm version and log."
        case LifecycleExit.channelSetNotVerified:
            return "The update channel is set to \(channel.rawValue), but the check after it failed, so what it offers is not verified. "
                + "No update started. Run `sudo k3sm update check` in Terminal, or wait for the server's next check."
        default:
            return nil
        }
    }
}

/// UpdateChannelPrecondition decides, from a status report read just now, whether
/// `channel` may be written: the picker must still be enabled on the live report
/// (`UpdateChannelPicker`), and the channel must be a change.
public enum UpdateChannelPrecondition {
    public static func check(_ channel: UpdateChannel, live: StatusReport?, progress: UpdateProgress) -> LifecyclePrecondition.Verdict {
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not change the update channel.")
        }
        // The driver holds a Team ID, so this build is not a developer build.
        let picker = UpdateChannelPicker.decide(report: live, progress: progress, developerBuild: false)
        guard picker.enabled else {
            return .refused((picker.reason.map { $0 + " " } ?? "") + "Nothing was changed.")
        }
        guard picker.selection != channel else {
            return .refused("The update channel is already \(channel.rawValue). Nothing was changed.")
        }
        return .proceed
    }
}

/// UpdateChannelDriver runs a channel change from a click to its outcome: read the
/// status and refuse unless the change can still be made, ask, read and check again,
/// then hand the channel's fixed script to the administrator prompt. Every run is a
/// fresh prompt, and it starts no roll.
///
/// It holds a `TeamID`, not a `TrustPolicy`: only a build that pins a Developer ID
/// can run this step, whatever developer mode says.
public struct UpdateChannelDriver: Sendable {
    public enum Result: Equatable, Sendable {
        /// Refused before any prompt; the sentence says why.
        case refused(String)
        /// The user answered no.
        case declined
        /// The root step ran, or the prompt was dismissed; the sentence is the outcome.
        case ran(PrivilegedOutcome, String)
    }

    let teamID: TeamID
    let readStatus: @Sendable () async -> StatusReport?
    let confirm: @MainActor @Sendable (LifecycleConfirmation) async -> Bool
    let runner: any PrivilegedRunner

    public init(
        teamID: TeamID,
        readStatus: @escaping @Sendable () async -> StatusReport?,
        confirm: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> Bool,
        runner: any PrivilegedRunner
    ) {
        self.teamID = teamID
        self.readStatus = readStatus
        self.confirm = confirm
        self.runner = runner
    }

    /// Sets `channel`. `progress` is the app's update tracker at the click.
    public func perform(_ channel: UpdateChannel, progress: UpdateProgress = UpdateProgress()) async -> Result {
        let first = await readStatus()
        if case .refused(let why) = UpdateChannelPrecondition.check(channel, live: first, progress: progress) { return .refused(why) }
        guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
        guard await confirm(LifecycleConfirmation(verb: .updateChannel(channel), report: first)) else { return .declined }
        if case .refused(let why) = UpdateChannelPrecondition.check(channel, live: await readStatus(), progress: progress) { return .refused(why) }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.renderUpdateChannel(channel, teamID: teamID), input: nil)
        return Self.classify(run, channel: channel)
    }

    /// Reads one finished root step. A refused write adds the CLI's own error
    /// text, cleaned, which is what tells Forbidden from a CRD not yet served.
    public static func classify(_ run: PrivilegedRun, channel: UpdateChannel) -> Result {
        let text = LifecycleOutcome.text(run.outcome, verb: .updateChannel(channel))
        if run.outcome == .failed(exitStatus: LifecycleExit.failed), let cli = run.errorOutput.map(StatusDisplay.errorText), !cli.isEmpty {
            return .ran(run.outcome, text + " " + cli)
        }
        return .ran(run.outcome, text)
    }
}
