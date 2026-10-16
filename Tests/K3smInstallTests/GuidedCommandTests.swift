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

import K3smInstall
import K3smStatus
import Testing

@Suite("guided panel commands")
struct GuidedCommandTests {
    @Test("a developer build's Terminal commands are the verbs the root step runs")
    func terminalCommandsMatchTheVerbs() {
        #expect(GuidedSteps.startCommand == "sudo k3sm " + LifecycleVerb.start.command)
        #expect(GuidedSteps.restartCommand == "sudo k3sm " + LifecycleVerb.restart.command)
        #expect(LifecycleScriptBuilder.arguments(for: .start).first == "start")
        #expect(LifecycleScriptBuilder.arguments(for: .restart).first == "restart")
        #expect(UpdateOffer.developerBuildReason.contains("`\(GuidedSteps.managedUpdateCommand)`"))
        #expect(GuidedAction.start.title == LifecycleVerb.start.title)
        #expect(GuidedAction.restart.title == LifecycleVerb.restart.title)
    }
}
