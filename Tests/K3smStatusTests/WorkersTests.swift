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

@Suite("decode workers and join target")
struct WorkersTests {
    @Test("a server with workers carries their names, roles and versions")
    func serverWithWorkers() throws {
        let report = try StatusReport.decode(try fixture("status_json_server-with-workers.json"))
        #expect(report.workers == [
            StatusWorker(name: "node-a", role: "server", version: "v1.36.2+k3sm.0.1.7"),
            StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
        ])
        #expect(report.workers?.map(\.k3smRelease) == [SemanticVersion("0.1.7"), SemanticVersion("0.1.6")])
        #expect(report.joinTarget == nil)
    }

    @Test("an empty list is no workers, an absent one is unknown")
    func emptyVersusAbsent() throws {
        #expect(try StatusReport.decode(try fixture("status_json_running.json")).workers == [])
        #expect(try StatusReport.decode(try fixture("status_json_unknown.json")).workers == nil)
    }

    @Test("an agent carries the join target")
    func agentJoinTarget() throws {
        let report = try StatusReport.decode(try fixture("status_json_agent-join-target.json"))
        #expect(report.joinTarget == "192.0.2.10:9345")
        #expect(report.workers == nil)
        #expect(try StatusReport.decode(try fixture("status_json_agent-waiting.json")).joinTarget == nil)
    }

    @Test("the k3sm release is the +k3sm. build metadata, never the Kubernetes version", arguments: [
        ("v1.36.2+k3sm.0.1.7", "0.1.7"), ("v1.36.2+k3sm.0.2.0-rc.1", "0.2.0-rc.1"),
    ])
    func release(_ version: String, _ want: String) {
        #expect(StatusWorker(name: "n", role: "agent", version: version).k3smRelease == SemanticVersion(want))
    }

    @Test("a version with no k3sm release is unknown", arguments: [
        nil, "", "v1.36.2", "v1.36.2+other.0.1.7", "v1.36.2+k3sm.", "v1.36.2+k3sm.dev",
    ] as [String?])
    func unknownRelease(_ version: String?) {
        #expect(StatusWorker(name: "n", role: "agent", version: version).k3smRelease == nil)
    }

    static func decode(_ extra: String) throws -> StatusReport {
        try StatusReport.decode(Data(#"{"schemaVersion":1,"verdict":"running","role":"server","summary":"s","rows":[],"#.utf8
            + Data(extra.utf8) + Data("}".utf8)))
    }

    @Test("tolerant decoding never fails the report")
    func tolerant() throws {
        #expect(try Self.decode(#""workers":null"#).workers == nil)
        #expect(try Self.decode(#""workers":"none""#).workers == nil)
        #expect(try Self.decode(#""workers":[{"role":"agent"}]"#).workers == nil)
        #expect(try Self.decode(#""workers":[7]"#).workers == nil)
        #expect(try Self.decode(#""workers":[{"name":"w","role":3,"version":9}]"#).workers == [StatusWorker(name: "w", role: "")])
        #expect(try Self.decode(#""workers":[{"name":"w","role":"agent","version":""}]"#).workers?.first?.version == nil)
        #expect(try Self.decode(#""joinTarget":7"#).joinTarget == nil)
    }
}
