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

@Suite("classify one workloads run")
struct WorkloadsReadingTests {
    @Test("a decoded list, empty or not, is listed")
    func listed() throws {
        let r = WorkloadsReading.classify(exitCode: 0, stdout: try fixture("kubectl_pods_empty.json"))
        #expect(r == .listed(Workloads(pods: [])))
        if case .listed(let w) = WorkloadsReading.classify(exitCode: 0, stdout: try fixture("kubectl_pods_running.json")) {
            #expect(w.pods.count == 3)
        } else {
            Issue.record("the live list did not classify as listed")
        }
    }

    @Test("a non-zero exit is a CLI error, never an empty cluster")
    func exitCode() throws {
        #expect(WorkloadsReading.classify(exitCode: 1, stdout: try fixture("kubectl_pods_running.json")) == .cliError("k3sm kubectl exited 1"))
    }

    @Test("another kind and garbage are CLI errors that say so")
    func wrongOutput() throws {
        #expect(WorkloadsReading.classify(exitCode: 0, stdout: try fixture("kubectl_services_list.json")) == .cliError("kubectl returned a List, not a pod list"))
        #expect(WorkloadsReading.classify(exitCode: 0, stdout: Data("error: no cluster".utf8)) == .cliError("the pod list could not be read"))
    }

    @Test("a hostile kind reaches the error text without its line breaks or format characters")
    func hostileKind() {
        let json = #"{"kind":"Evil\u202e\nList","items":[]}"#
        #expect(WorkloadsReading.classify(exitCode: 0, stdout: Data(json.utf8)) == .cliError("kubectl returned a Evil List, not a pod list"))
    }
}

@Suite("workloads display strings")
struct WorkloadsDisplayTests {
    @Test("runs as", arguments: [(WorkloadKind.nativeProcess, "Process"), (.linuxVM, "Linux VM"), (.other("wasm"), "wasm")])
    func runsAs(_ c: (WorkloadKind, String)) {
        #expect(WorkloadsDisplay.runsAs(c.0) == c.1)
    }

    @Test("cores")
    func cores() {
        #expect(WorkloadsDisplay.cores(nil) == "")
        #expect(WorkloadsDisplay.cores(0.25) == "0.25")
        #expect(WorkloadsDisplay.cores(2) == "2")
        #expect(WorkloadsDisplay.cores(1.5) == "1.5")
    }

    @Test("bytes")
    func bytes() {
        #expect(WorkloadsDisplay.bytes(nil) == "")
        #expect(WorkloadsDisplay.bytes(0) == "")
        #expect(WorkloadsDisplay.bytes(268_435_456) == "256 MB")
        #expect(WorkloadsDisplay.bytes(1_610_612_736) == "1.5 GB")
        #expect(WorkloadsDisplay.bytes(21_474_836_480) == "20 GB")
        #expect(WorkloadsDisplay.bytes(2048) == "2 KB")
    }

    @Test("age")
    func age() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(WorkloadsDisplay.age(nil, now: now) == "")
        #expect(WorkloadsDisplay.age(now.addingTimeInterval(-12), now: now) == "12s")
        #expect(WorkloadsDisplay.age(now.addingTimeInterval(-11 * 60), now: now) == "11 min")
        #expect(WorkloadsDisplay.age(now.addingTimeInterval(-5 * 3600), now: now) == "5 h")
        #expect(WorkloadsDisplay.age(now.addingTimeInterval(-6 * 86_400), now: now) == "6 d")
        #expect(WorkloadsDisplay.age(now.addingTimeInterval(60), now: now) == "0s")
    }

    @Test("group title")
    func groupTitle() {
        #expect(WorkloadsDisplay.groupTitle(namespace: "default", count: 1) == "default · 1 pod")
        #expect(WorkloadsDisplay.groupTitle(namespace: "ml", count: 4) == "ml · 4 pods")
    }
}

@Suite("the console's search and selection")
struct WorkloadsSelectionTests {
    static let pods = [
        testPod("web-7c9d", namespace: "shop", image: "ghcr.io/acme/Web:2"),
        testPod("db-0", namespace: "shop", image: "postgres:16"),
        testPod("hello-native", image: "registry.local/hello:1"),
        testPod("long", image: "registry.local/" + String(repeating: "a", count: 200) + "/hidden-tail:1"),
        testPod("bidi\u{202E}lave", image: "registry.local/bidi:1"),
    ]

    struct SearchCase: Sendable, CustomTestStringConvertible {
        let name: String
        let query: String
        let want: [String]
        var testDescription: String { name }
    }

    @Test("the search matches a pod's name or image, ignoring case", arguments: [
        SearchCase(name: "empty query keeps every pod", query: "", want: pods.map(\.name)),
        SearchCase(name: "by name", query: "DB", want: ["db-0"]),
        SearchCase(name: "by image", query: "postgres", want: ["db-0"]),
        SearchCase(name: "image case ignored", query: "acme/web", want: ["web-7c9d"]),
        SearchCase(name: "name and image both match", query: "hello", want: ["hello-native"]),
        SearchCase(name: "namespace is not searched", query: "shop", want: []),
        SearchCase(name: "no match", query: "redis", want: []),
        SearchCase(name: "a query never spans the name and the image", query: "7c9d ghcr", want: []),
        SearchCase(name: "the part of an image the list cuts off does not match", query: "hidden-tail", want: []),
        SearchCase(name: "a format character the list removes is not needed to match", query: "bidilave", want: ["bidi\u{202E}lave"]),
        SearchCase(name: "a format character in the query matches nothing shown", query: "bidi\u{202E}", want: []),
    ])
    func searchPredicate(_ c: SearchCase) {
        #expect(WorkloadsDisplay.visible(Self.pods, query: c.query).map(\.name) == c.want)
    }

    @Test("a row names the node its pod runs on, this Mac's by the tag")
    func workloadRowNamesItsNode() {
        #expect(WorkloadsDisplay.nodeLabel(testPod("p"), ownNode: "mac-a") == .unscheduled)
        #expect(WorkloadsDisplay.nodeLabel(testPod("p"), ownNode: "mac-a").text == "-")
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "mac-a"), ownNode: "mac-a") == .thisMac)
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "mac-a"), ownNode: "mac-a").text == "this Mac")
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "mac-b"), ownNode: "mac-a") == .node("mac-b"))
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "mac-b"), ownNode: nil).text == "mac-b")
        #expect(WorkloadsDisplay.nodeLabel(testPod("p", node: "mac-a"), ownNode: nil) == .node("mac-a"))
    }

    @Test("the search matches the node a pod runs on")
    func searchMatchesNode() {
        let pods = [testPod("a", node: "mac-a"), testPod("b", node: "studio-2"), testPod("c")]
        #expect(WorkloadsDisplay.visible(pods, query: "STUDIO", ownNode: "mac-a").map(\.name) == ["b"])
        #expect(WorkloadsDisplay.visible(pods, query: "this mac", ownNode: "mac-a").map(\.name) == ["a"])
        #expect(WorkloadsDisplay.visible(pods, query: "mac-a", ownNode: "mac-a").map(\.name) == ["a"])
        #expect(WorkloadsDisplay.visible(pods, query: "-", ownNode: "mac-a").map(\.name) == ["a", "b"])
    }

    struct SelectionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let selected: String?
        let pods: [Pod]?
        let want: SelectionChange
        var testDescription: String { name }
    }

    @Test("a poll keeps, picks or clears the selection", arguments: [
        SelectionCase(name: "nothing selected picks the first pod", selected: nil, pods: pods, want: .select("shop/web-7c9d")),
        SelectionCase(name: "a listed pod stays selected", selected: "default/hello-native", pods: pods, want: .keep),
        SelectionCase(name: "a pod gone from the list clears", selected: "default/gone", pods: pods, want: .clear),
        SelectionCase(name: "the same name in another namespace is another pod", selected: "default/db-0", pods: pods, want: .clear),
        SelectionCase(name: "a list that did not read clears", selected: "shop/db-0", pods: nil, want: .clear),
        SelectionCase(name: "an empty list with nothing selected clears", selected: nil, pods: [], want: .clear),
        SelectionCase(name: "no list with nothing selected clears", selected: nil, pods: nil, want: .clear),
    ])
    func selectionFallback(_ c: SelectionCase) {
        #expect(WorkloadsDisplay.selection(after: c.selected, in: c.pods) == c.want)
    }

    @Test("a pod's key is its namespace and name")
    func key() {
        #expect(testPod("db-0", namespace: "shop").key == "shop/db-0")
    }
}
