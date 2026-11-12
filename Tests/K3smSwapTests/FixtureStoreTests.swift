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
import Synchronization
import Testing

/// The fixture store with a fake signer and checker: nothing is signed.
@Suite struct FixtureStoreTests {
    @Test func signsOncePerKeyAndCopiesOtherwise() throws {
        let signs = Mutex<[String]>([])
        let checks = Mutex<Int>(0)
        let store = FixtureStore(directory: FixtureTrees.directory(named: "storetest-" + UUID().uuidString.prefix(8)),
                                 signer: { path in signs.withLock { $0.append(path) }; return 0 },
                                 checker: { _ in checks.withLock { $0 += 1 }; return true })
        let out = store.directory + "/out"
        func build(_ text: String) -> (String) -> Void {
            { path in FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) }
        }
        for n in 0..<5 {
            try store.place(key: "a", name: "item", at: out + "/a\(n)", build: build("a"))
        }
        #expect(signs.withLock { $0.count } == 1, "one sign for one key across five places")
        #expect(checks.withLock { $0 } == 1, "the first copy of a key is checked, once")
        try store.place(key: "b", name: "item", at: out + "/b0", build: build("b"))
        try store.place(key: "b", name: "item", at: out + "/b1", build: build("b"))
        #expect(signs.withLock { $0.count } == 2, "another key signs on its own")
        for n in 0..<5 {
            #expect(FileManager.default.contents(atPath: out + "/a\(n)") == Data("a".utf8))
        }
        #expect(FileManager.default.contents(atPath: out + "/b1") == Data("b".utf8))
        #expect(throws: FixtureError.self) { try store.place(key: "a", name: "item", at: out + "/a0", build: build("a")) }
        #expect(signs.withLock { $0.count } == 2, "a refused place signs nothing")
    }

    @Test func aCopyThatDoesNotVerifyFailsTheTest() {
        let store = FixtureStore(directory: FixtureTrees.directory(named: "storetest-" + UUID().uuidString.prefix(8)),
                                 signer: { _ in 0 }, checker: { _ in false })
        #expect(throws: FixtureError.self) {
            try store.place(key: "a", name: "item", at: store.directory + "/out/a") { path in
                FileManager.default.createFile(atPath: path, contents: Data("a".utf8))
            }
        }
    }
}
