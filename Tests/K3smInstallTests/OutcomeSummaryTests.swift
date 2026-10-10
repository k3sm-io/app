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

@testable import K3smInstall

@Suite("outcome summary")
struct OutcomeSummaryTests {
    static let join = CopyOutAction.join(try! ServerAddress(parsing: "studio.local"))

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let outcome: PrivilegedOutcome
        let action: CopyOutAction
        let contains: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "success", outcome: .succeeded, action: .startServer, contains: "Done."),
        Case(name: "cancelled prompt", outcome: .cancelled, action: .startServer, contains: "Nothing was changed"),
        Case(name: "no prompt", outcome: .couldNotStart, action: .update, contains: "could not be shown"),
        Case(name: "lock held", outcome: .failed(exitStatus: CopyOutExit.busy), action: .startServer, contains: "Another k3sm install"),
        Case(name: "bad signature", outcome: .failed(exitStatus: CopyOutExit.signatureRejected), action: .update, contains: "signature check"),
        Case(name: "unsafe tree", outcome: .failed(exitStatus: CopyOutExit.refusedTree), action: .update, contains: "not safe"),
        Case(name: "unsafe path", outcome: .failed(exitStatus: CopyOutExit.refusedPath), action: .update, contains: "not safe"),
        Case(name: "no token", outcome: .failed(exitStatus: CopyOutExit.missingToken), action: join, contains: "Paste the token"),
        Case(name: "join failure asks for a fresh token", outcome: .failed(exitStatus: 1), action: join, contains: "fresh one"),
        Case(name: "install failure points at the log", outcome: .failed(exitStatus: 1), action: .startServer, contains: "exit status 1"),
    ]

    @Test("text", arguments: cases)
    func text(_ c: Case) {
        #expect(OutcomeSummary.text(c.outcome, action: c.action).contains(c.contains))
    }
}
