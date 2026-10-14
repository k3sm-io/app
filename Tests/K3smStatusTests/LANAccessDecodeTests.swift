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

/// The `network` field of `k3sm status -o json`, decoded tolerantly: absent
/// is on with no setting recorded, an unrecognized value is unknown (never
/// off), and a role with no switch has none.
@Suite("LAN access decoder")
struct LANAccessDecodeTests {
    /// A minimal report with `network` set to the given JSON text, or no
    /// `network` field when nil.
    static func report(network: String?, role: String = "server", verdict: String = "running") throws -> StatusReport {
        let field = network.map { #","network":\#($0)"# } ?? ""
        let json = #"{"schemaVersion":1,"verdict":"\#(verdict)","role":"\#(role)","summary":"s","rows":[{"name":"\#(role)","state":"running","detail":"d"}]\#(field)}"#
        return try StatusReport.decode(Data(json.utf8))
    }

    @Test("an absent network field reads as on with no setting recorded")
    func absent() throws {
        let network = try Self.report(network: nil).network
        #expect(network == .absentField)
        #expect(network.setting == .on)
        #expect(!network.recorded)
        #expect(!network.fieldPresent)
    }

    @Test("on and off decode as the setting", arguments: [("on", LANSetting.on), ("off", .off)])
    func explicit(_ word: String, _ want: LANSetting) throws {
        let network = try Self.report(network: #"{"lan":"\#(word)","recorded":true,"covers":["nodeports"],"alwaysOn":["mesh"]}"#).network
        #expect(network.setting == want)
        #expect(network.recorded)
        #expect(network.covers == ["nodeports"])
        #expect(network.alwaysOn == ["mesh"])
        #expect(network.applied == nil)
    }

    @Test("an unrecognized value is unknown, never off", arguments: [
        #"{"lan":"maybe","recorded":true}"#,
        #"{"lan":"OFF","recorded":true}"#,
        #"{"lan":"","recorded":true}"#,
        #"{"lan":false,"recorded":true}"#,
        #"{"recorded":true}"#,
        #""off""#,
        "null",
        "[]",
        "7",
    ])
    func unrecognized(_ field: String) throws {
        let report = try Self.report(network: field)
        #expect(report.network.setting == .unknown)
        #expect(report.network.setting != .off)
        #expect(report.network.fieldPresent)
    }

    @Test("a refused change and its applied state decode from the app's fixture")
    func appliedFixture() throws {
        let report = try StatusReport.decode(fixture("lan-access-refused.json"))
        #expect(report.network.setting == .off)
        #expect(report.network.recorded)
        #expect(report.network.covers == ["nodeports", "loadbalancers", "ingress"])
        #expect(report.network.alwaysOn == ["apiserver", "join", "mesh"])
        let applied = try #require(report.network.applied)
        #expect(applied.setting == .on)
        #expect(applied.error.hasPrefix("ingress: bind 10.0.0.5:80"))
    }

    @Test("a mistyped list or applied report degrades, never fails the report")
    func mistyped() throws {
        let network = try Self.report(network: #"{"lan":"off","recorded":"yes","covers":7,"alwaysOn":"mesh","applied":{"lan":3}}"#).network
        #expect(network.setting == .off)
        #expect(network.recorded)
        #expect(network.covers.isEmpty)
        #expect(network.alwaysOn == nil)
        #expect(network.applied == nil)
    }

    @Test("a role with no switch has none", arguments: [
        ("server", "not-installed", false),
        ("witness", "running", false),
        ("", "running", false),
        ("server", "running", true),
        ("agent", "degraded", true),
    ])
    func roles(_ role: String, _ verdict: String, _ has: Bool) throws {
        let json = #"{"schemaVersion":1,"verdict":"\#(verdict)","role":"\#(role)","summary":"s","rows":[]}"#
        #expect(try StatusReport.decode(Data(json.utf8)).hasLANSwitch == has)
    }

    @Test("the CLI's error text is stripped of control characters and truncated")
    func errorText() {
        #expect(StatusDisplay.errorText("bind\u{1B}[31m failed\r\n\tagain\u{202E}x\u{0}") == "bind [31m failed againx")
        #expect(StatusDisplay.errorText("  \n ") == "")
        let long = StatusDisplay.errorText(String(repeating: "e", count: 1000))
        #expect(long.count == StatusDisplay.maxErrorLength)
        #expect(long.hasSuffix("…"))
        for scalar in StatusDisplay.errorText("a\u{7}\u{85}\u{2028}\u{200B}\u{2066}b").unicodeScalars {
            #expect(![.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory))
        }
    }
}
