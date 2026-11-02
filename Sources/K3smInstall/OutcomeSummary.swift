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

/// OutcomeSummary turns a finished root step into the one sentence the window
/// shows under the log.
public enum OutcomeSummary {
    /// The sentence for `plan`'s finished step, read beside the copy-out log
    /// it left: a Repair k3sm refused because the installed k3sm cannot
    /// resolve names the install script (`UnresolvableInstall`); every other
    /// outcome is `text(_:action:)`'s.
    public static func text(_ outcome: PrivilegedOutcome, plan: CopyOutPlan, log: String) -> String {
        if UnresolvableInstall.refused(outcome, action: plan.action, log: log) {
            return RepairRefusal.installedUnresolvable(payload: plan.payloadVersion).text
        }
        return text(outcome, action: plan.action)
    }

    public static func text(_ outcome: PrivilegedOutcome, action: CopyOutAction) -> String {
        switch outcome {
        case .succeeded:
            return "Done."
        case .cancelled:
            return "Cancelled. Nothing was changed."
        case .couldNotStart:
            return "The administrator prompt could not be shown. Nothing was changed."
        case .failed(let status):
            switch status {
            case CopyOutExit.busy:
                return "Another k3sm install is running on this Mac. Try again when it finishes."
            case CopyOutExit.signatureRejected:
                return "This copy of k3sm failed its signature check, so nothing was run. Download k3sm again."
            case CopyOutExit.refusedTree, CopyOutExit.refusedPath:
                return "The app bundle or a k3sm path was not safe to use, so nothing was run. The log says which."
            case CopyOutExit.missingToken:
                return "No join token arrived. Paste the token again."
            case CopyOutExit.developerModeMissing:
                if case .uninstall = action { return DeveloperMode.missingUninstallText }
                return DeveloperMode.missingText
            default:
                if case .join = action {
                    return "The join failed (exit \(status)). A join token expires in minutes: run `k3sm token create` on the server for a fresh one and try again."
                }
                return "k3sm stopped with exit status \(status). The log above says why."
            }
        }
    }
}
