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
import Testing

@testable import K3smStatus

@Suite("help tags")
struct HelpCatalogTests {
    @Test("every help tag in the catalog follows the standard")
    func helpCatalogFollowsTheStandard() {
        #expect(Help.all.count > 50)
        for tag in Help.all {
            let problems = HelpStandard.problems(tag)
            #expect(problems.isEmpty, "\(tag.control): \"\(tag.text)\": \(problems.joined(separator: "; "))")
        }
    }

    @Test("the standard refuses each way a tag can break it")
    func standardRefusesBadTags() {
        let bad: [(String, String?, String)] = [
            ("Refresh", "Refresh", "repeats its label"),
            ("Reset to defaults…", "Reset to Defaults…", "repeats its label"),
            ("Shows the details column.", nil, "one sentence ends with a period"),
            ("Show The Details Column", nil, "not sentence case"),
            ("show the details column", nil, "does not start with a capital"),
            ("Open one two three four five six seven eight nine ten eleven twelve", nil, "words, more than"),
            ("Pick one:", nil, "ends with \":\""),
            ("Loading…", nil, "ends with an ellipsis"),
            (" Show the details", nil, "leading or trailing space"),
            ("", nil, "empty"),
        ]
        for (text, label, want) in bad {
            let problems = HelpStandard.problems(HelpTag(text, control: "fixture", label: label))
            #expect(problems.contains { $0.contains(want) }, "\"\(text)\" should be refused for \(want), got \(problems)")
        }
    }

    @Test("the standard accepts a shortcut, two sentences, names and acronyms")
    func standardAcceptsGoodTags() {
        let good = [
            "Show the details column (Command-Option-I)",
            "Delete this pod. Its owner recreates it.",
            "CPU used, from metrics-server, against allocatable",
            "k3sm on this Mac, in Terminal",
            "Copy namespace/name, the form kubectl takes",
        ]
        for text in good {
            #expect(HelpStandard.problems(HelpTag(text, control: "fixture")).isEmpty, "\(text)")
        }
    }

    @Test("every row action the console builds has its own tag")
    func everyActionHasItsTag() {
        let verbs = ["restart", "delete", "service-delete", "model-unload", "model-load", "model-delete",
                     "build-cancel", "build-delete", "builder-start", "builder-reset-start", "builder-stop",
                     "builder-reset", "builder-prune-plan", "builder-prune", "cleanup", "delete-claim",
                     "delete-volumes"]
        #expect(Set(Help.Actions.byVerb.keys) == Set(verbs))
        let locals = ["copy-name", "copy-namespace-name", "open-shell", "summarize-logs", "copy-endpoint",
                      "copy-curl", "copy-ip", "copy-dns", "open", "copy-url", "show-log"]
        #expect(Set(Help.Actions.byLocalID.keys) == Set(locals))
        let summarize = LocalMenuItem(id: "summarize-logs:web", title: "Summarize Logs: web",
                                      action: .copy("unused"))
        #expect(Help.Actions.tag(for: summarize) == Help.Actions.byLocalID["summarize-logs"])
        let unknown = LocalMenuItem(id: "new-thing", title: "New Thing", action: .copy("unused"))
        #expect(Help.Actions.tag(for: unknown) == Help.Actions.other)
    }

    @Test("dynamic tags: a disabled control's reason wins, otherwise the catalog's text")
    func dynamicTags() {
        #expect(Help.Strip.update(.available(tag: "v0.2.0", disabledReason: "Not now.")) == "Not now.")
        #expect(Help.Strip.update(.available(tag: "v0.2.0", disabledReason: nil))
            == "Update every node to k3sm v0.2.0, the server last")
        #expect(HelpStandard.problems(HelpTag(Help.Strip.update(.available(tag: "v0.2.0", disabledReason: nil)),
                                              control: "update")).isEmpty)
        #expect(Help.Strip.update(.updating) == UpdateOffer.updating.disabledReason)
        #expect(Help.Update.cancel(reason: nil) == Help.Update.cancel.text)
        #expect(Help.Update.cancel(reason: "Wait.") == "Wait.")
        #expect(Help.General.tour(available: false) == Help.General.tourUnavailable)
        #expect(Help.Strip.details(shown: true) == Help.Strip.hideDetails)
        #expect(Help.Inspector.detail("Manifest") == Help.Inspector.manifest)
        #expect(Help.Panel.tile(PanelTile(label: "data root", value: "1 GB")).text.contains("k3sm's data"))
        #expect(Set(ConsoleSection.allCases.map { Help.Strip.tab($0).text }).count == ConsoleSection.allCases.count)
    }
}
