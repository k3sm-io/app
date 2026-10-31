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

import Testing

import K3smStatus
@testable import K3smInstall

/// Exit 110, the root step's developer-mode refusal, reads as the one shared
/// sentence in every outcome mapper a developer-mode root step reaches.
@Suite("developer mode: the exit 110 sentence")
struct DeveloperModeOutcomeTests {
    static let refused = PrivilegedOutcome.failed(exitStatus: LifecycleExit.developerModeMissing)
    static let run = PrivilegedRun(outcome: refused, errorOutput: "k3sm app: refused: developer mode is off: /Library/k3sm.developer-mode does not exist")

    @Test("the sentence says the mode is off or failed its check, and how to turn it on on purpose")
    func sentence() {
        #expect(LifecycleExit.developerModeMissing == 110)
        #expect(CopyOutExit.developerModeMissing == 110)
        #expect(DeveloperMode.missingExit == 110)
        for text in [DeveloperMode.missingText, DeveloperMode.missingUninstallText] {
            #expect(text.hasPrefix("Developer mode is off on this Mac, or its marker failed its check, so nothing ran."))
        }
        #expect(DeveloperMode.missingText.contains("tick the Developer mode box"))
        #expect(DeveloperMode.missingUninstallText.contains("`sudo k3sm uninstall` in Terminal"))
    }

    @Test("every lifecycle verb, the managed update's included", arguments: LifecycleVerb.allCases)
    func lifecycle(_ verb: LifecycleVerb) {
        #expect(LifecycleOutcome.text(Self.refused, verb: verb) == DeveloperMode.missingText)
    }

    @Test("the LAN setting", arguments: [LifecycleVerb.lanOn, .lanOff])
    func lan(_ verb: LifecycleVerb) {
        let text = LANOutcome.text(PrivilegedRun(outcome: Self.refused), verb: verb, confirmed: .unknown)
        #expect(text == DeveloperMode.missingText)
        #expect(LANOutcome.text(Self.run, verb: verb, confirmed: .off).hasPrefix(DeveloperMode.missingText))
    }

    @Test("the image store", arguments: [LifecycleScriptBuilder.ImageVerb.prune, .pruneDryRun])
    func imageStore(_ verb: LifecycleScriptBuilder.ImageVerb) {
        #expect(ImageStoreDriver.classify(Self.run, verb: verb, node: "mac") == .ran(Self.refused, DeveloperMode.missingText))
    }

    @Test("the join token")
    @MainActor
    func joinToken() {
        #expect(JoinCommandDriver.failureText(PrivilegedRun(outcome: Self.refused)) == DeveloperMode.missingText)
        #expect(JoinCommandDriver.failureText(Self.run).hasPrefix(DeveloperMode.missingText))
    }

    @Test("the copy-out: update and repair point back to the first run, uninstall to Terminal")
    func copyOut() {
        #expect(OutcomeSummary.text(Self.refused, action: .update(.server)) == DeveloperMode.missingText)
        #expect(OutcomeSummary.text(Self.refused, action: .repair) == DeveloperMode.missingText)
        #expect(OutcomeSummary.text(Self.refused, action: .uninstall(purge: false)) == DeveloperMode.missingUninstallText)
        #expect(OutcomeSummary.text(Self.refused, action: .uninstall(purge: true)) == DeveloperMode.missingUninstallText)
    }
}
