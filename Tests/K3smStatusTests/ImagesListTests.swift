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

@Suite("node images")
struct ImagesListTests {
    static func list(_ nodes: [String]) -> Data {
        Data(#"{"kind":"List","items":[\#(nodes.joined(separator: ","))]}"#.utf8)
    }

    static func node(_ name: String, images: String?) -> String {
        let status = images.map { #","status":{"images":\#($0)}"# } ?? ""
        return #"{"kind":"Node","metadata":{"name":"\#(name)"}\#(status)}"#
    }

    @Test("images group by digest across nodes, with every name clipped")
    func groupsNodeImagesByDigestAndClipsNames() throws {
        let a = Self.node("mac-a", images: #"""
            [{"names":["docker.io/library/nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","docker.io/library/nginx:1.27"],"sizeBytes":71000000},
             {"names":["ghcr.io/x/evil‮gnp.exe:1"],"sizeBytes":1024}]
            """#)
        let b = Self.node("mac-b", images: #"""
            [{"names":["docker.io/library/nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","docker.io/library/nginx:latest"],"sizeBytes":71000000}]
            """#)
        let read = try NodeListRead.decode(Self.list([a, b]))
        #expect(read.nodes.map(\.name) == ["mac-a", "mac-b"])
        guard case .listed(let images) = read.images else { Issue.record("not listed"); return }
        #expect(images.count == 2)
        let nginx = try #require(images.first { $0.digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" })
        #expect(nginx.key == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(nginx.names == ["docker.io/library/nginx:1.27", "docker.io/library/nginx:latest", "docker.io/library/nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        #expect(nginx.title == "docker.io/library/nginx:1.27")
        #expect(nginx.sizeBytes == 71_000_000)
        #expect(nginx.nodes == ["mac-a", "mac-b"])
        #expect(nginx.nodesText == "mac-a, mac-b")
        let other = try #require(images.first { $0.digest == nil })
        #expect(other.names == ["ghcr.io/x/evilgnp.exe:1"])
        #expect(other.key == ImagesList.rowKey("ghcr.io/x/evil\u{202E}gnp.exe:1"))
        #expect(other.key.hasPrefix("ghcr.io/x/evilgnp.exe:1#"))
        #expect(other.nodes == ["mac-a"])
    }

    static let hex = String(repeating: "0123456789abcdef", count: 4)

    @Test("only sha256 with 64 lowercase hex is a digest; any other name keys its row whole")
    func digestIsOnlySha256With64Hex() throws {
        #expect(ImagesList.digest(of: "r@sha256:" + Self.hex) == "sha256:" + Self.hex)
        #expect(ImagesList.digest(of: "evil@x") == nil)
        #expect(ImagesList.digest(of: "r@sha256:abc") == nil)
        #expect(ImagesList.digest(of: "r@sha512:" + Self.hex + Self.hex) == nil)
        #expect(ImagesList.digest(of: "r@sha256:" + Self.hex.uppercased()) == nil)
        #expect(ImagesList.digest(of: "r@sha256:" + String(Self.hex.dropLast()) + "g") == nil)
        #expect(ImagesList.digest(of: "r:1") == nil)
        let a = Self.node("mac-a", images: #"[{"names":["evil@x"],"sizeBytes":1},{"names":["good@x"],"sizeBytes":2}]"#)
        guard case .listed(let images) = try NodeListRead.decode(Self.list([a])).images else { Issue.record("not listed"); return }
        #expect(images.map(\.key) == ["evil@x", "good@x"])
        #expect(images.allSatisfy { $0.digest == nil })
    }

    @Test("a name the list cuts off keys its row by a hash, so two such names stay two rows")
    func longNamesKeyApart() {
        let base = "registry.local/" + String(repeating: "a", count: 200)
        let one = ImagesList.rowKey(base + "/one:1")
        let two = ImagesList.rowKey(base + "/two:1")
        #expect(one != two)
        #expect(one.count == StatusDisplay.maxLength && two.count == StatusDisplay.maxLength)
        #expect(StatusDisplay.clip(one) == one)
        #expect(ImagesList.rowKey("short:1") == "short:1")
        #expect(ImagesList.rowKey(base + "/one:1") == one)
    }

    @Test("a read keeps a selected image while it is listed and clears it otherwise")
    func staleImagesSelectionClears() {
        let image = NodeImage(key: "sha256:" + Self.hex, digest: "sha256:" + Self.hex, names: ["r:1"], sizeBytes: 1, nodes: ["a"])
        #expect(ImagesList.selection(after: image.key, in: .listed([image])) == image.key)
        #expect(ImagesList.selection(after: "gone", in: .listed([image])) == nil)
        #expect(ImagesList.selection(after: image.key, in: .notReported) == nil)
        #expect(ImagesList.selection(after: nil, in: .listed([image])) == nil)
        #expect(ImagesList.notReportedText == "No node reports its images yet.")
    }

    @Test("no node carrying the field is not reported, an empty field is an empty list")
    func notReported() throws {
        let none = try NodeListRead.decode(Self.list([Self.node("mac-a", images: nil), Self.node("mac-b", images: nil)]))
        #expect(none.images == .notReported)
        let empty = try NodeListRead.decode(Self.list([Self.node("mac-a", images: "[]"), Self.node("mac-b", images: nil)]))
        #expect(empty.images == .listed([]))
        let twoNodes = try NodeListRead.decode(try fixture("kubectl_nodes_two.json"))
        #expect(twoNodes.nodes == (try Nodes.decode(try fixture("kubectl_nodes_two.json"))))
    }

    @Test("an entry without names, a mistyped size or an invalid node name is left out or unknown")
    func malformedEntries() throws {
        let a = Self.node("mac-a", images: #"[{"names":[]},{"sizeBytes":5},{"names":["r:1"],"sizeBytes":"big"},{"names":["r:2"],"sizeBytes":true},{"names":["r:3"],"sizeBytes":-4}]"#)
        let bad = Self.node("Not_A_Name", images: #"[{"names":["r:9"],"sizeBytes":1}]"#)
        let read = try NodeListRead.decode(Self.list([a, bad]))
        guard case .listed(let images) = read.images else { Issue.record("not listed"); return }
        #expect(images.map(\.title) == ["r:1", "r:2", "r:3"])
        #expect(images.allSatisfy { $0.sizeBytes == nil })
    }

    @Test("three or more nodes show as a count; the search matches a shown name")
    func displayAndSearch() {
        let image = NodeImage(key: "sha256:b", digest: "sha256:b", names: ["redis:7", "redis@sha256:b"], sizeBytes: 1, nodes: ["a", "b", "c"])
        #expect(image.nodesText == "3 nodes")
        #expect(ImagesList.visible([image], query: "") == [image])
        #expect(ImagesList.visible([image], query: "REDIS") == [image])
        #expect(ImagesList.visible([image], query: "nginx").isEmpty)
    }

    @Test("a failed node-list run is a failure with its reason")
    func tabResult() {
        #expect(NodeListRead.tabResult(exitCode: 2, stdout: Data()) == .failed("k3sm kubectl exited 2"))
        #expect(NodeListRead.tabResult(exitCode: 0, stdout: Data("nope".utf8)) == .failed("the node list could not be read"))
        #expect(NodeListRead.tabResult(exitCode: 0, stdout: Data(#"{"kind":"PodList","items":[]}"#.utf8)) == .failed("kubectl returned a PodList, not a node list"))
    }
}
