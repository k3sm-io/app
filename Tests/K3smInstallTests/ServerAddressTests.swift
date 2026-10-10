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

@Suite("server address")
struct ServerAddressTests {
    struct ValidCase: Sendable, CustomTestStringConvertible {
        let input: String
        let argument: String
        let description: String
        var testDescription: String { input }
    }

    static let valid: [ValidCase] = [
        ValidCase(input: "studio.local", argument: "studio.local", description: "studio.local:9345"),
        ValidCase(input: "Studio.Local:9345", argument: "studio.local", description: "studio.local:9345"),
        ValidCase(input: "k3s-m1", argument: "k3s-m1", description: "k3s-m1:9345"),
        ValidCase(input: "192.168.0.50", argument: "192.168.0.50", description: "192.168.0.50:9345"),
        ValidCase(input: "10.0.0.1:9345", argument: "10.0.0.1", description: "10.0.0.1:9345"),
        ValidCase(input: "[fd00::1]", argument: "fd00::1", description: "[fd00::1]:9345"),
        ValidCase(input: "[FD00::1]:9345", argument: "fd00::1", description: "[fd00::1]:9345"),
        ValidCase(input: "[::1]", argument: "::1", description: "[::1]:9345"),
        ValidCase(input: "[2001:db8:0:0:0:0:0:1]", argument: "2001:db8:0:0:0:0:0:1", description: "[2001:db8:0:0:0:0:0:1]:9345"),
        ValidCase(input: "[::ffff:192.0.2.1]", argument: "::ffff:192.0.2.1", description: "[::ffff:192.0.2.1]:9345"),
        ValidCase(input: "a.b-c.d1", argument: "a.b-c.d1", description: "a.b-c.d1:9345"),
    ]

    @Test("accepted", arguments: valid)
    func accepted(_ c: ValidCase) throws {
        let address = try ServerAddress(parsing: c.input)
        #expect(address.argument == c.argument)
        #expect(address.description == c.description)
        #expect(address.port == ServerAddress.joinPort)
    }

    struct InvalidCase: Sendable, CustomTestStringConvertible {
        let input: String
        let want: ServerAddress.ParseError
        var testDescription: String { input.debugDescription }
    }

    static let invalid: [InvalidCase] = [
        InvalidCase(input: "", want: .empty),
        // Injection attempts: every shell, AppleScript and option byte is
        // outside the grammar's character set.
        InvalidCase(input: "host;rm -rf /", want: .invalidCharacter),
        InvalidCase(input: "$(id)", want: .invalidCharacter),
        InvalidCase(input: "`id`", want: .invalidCharacter),
        InvalidCase(input: "host'", want: .invalidCharacter),
        InvalidCase(input: "host\"", want: .invalidCharacter),
        InvalidCase(input: "host\\", want: .invalidCharacter),
        InvalidCase(input: "host --token x", want: .invalidCharacter),
        InvalidCase(input: "host\n", want: .invalidCharacter),
        InvalidCase(input: " host", want: .invalidCharacter),
        InvalidCase(input: "host|id", want: .invalidCharacter),
        InvalidCase(input: "host&", want: .invalidCharacter),
        InvalidCase(input: "https://host", want: .invalidCharacter),
        InvalidCase(input: "user@host", want: .invalidCharacter),
        InvalidCase(input: "hоst", want: .invalidCharacter), // Cyrillic o
        InvalidCase(input: "[fe80::1%en0]", want: .invalidCharacter),
        InvalidCase(input: "-oProxyCommand", want: .invalidHost),
        InvalidCase(input: "--server", want: .invalidHost),
        InvalidCase(input: "host-", want: .invalidHost),
        InvalidCase(input: "a..b", want: .invalidHost),
        InvalidCase(input: "host.", want: .invalidHost),
        InvalidCase(input: ".host", want: .invalidHost),
        InvalidCase(input: String(repeating: "a", count: 64) + ".com", want: .invalidHost),
        InvalidCase(input: "host.123", want: .invalidHost),
        InvalidCase(input: "ho]st", want: .invalidHost),
        InvalidCase(input: "1.2.3", want: .invalidIPv4),
        InvalidCase(input: "256.1.1.1", want: .invalidIPv4),
        InvalidCase(input: "01.2.3.4", want: .invalidIPv4),
        InvalidCase(input: "1.2.3.4.5", want: .invalidIPv4),
        InvalidCase(input: "::1", want: .invalidIPv6),
        InvalidCase(input: "fd00::1:9345", want: .invalidIPv6),
        InvalidCase(input: "[fd00::1", want: .invalidIPv6),
        InvalidCase(input: "[fd00::1]9345", want: .invalidIPv6),
        InvalidCase(input: "[fd00:::1]", want: .invalidIPv6),
        InvalidCase(input: "[1:2:3:4:5:6:7:8:9]", want: .invalidIPv6),
        InvalidCase(input: "[1::2::3]", want: .invalidIPv6),
        InvalidCase(input: "[12345::1]", want: .invalidIPv6),
        InvalidCase(input: "[g::1]", want: .invalidIPv6),
        InvalidCase(input: "[host]", want: .invalidIPv6),
        InvalidCase(input: "host:", want: .invalidPort),
        InvalidCase(input: "host:0", want: .invalidPort),
        InvalidCase(input: "host:09345", want: .invalidPort),
        InvalidCase(input: "host:65536", want: .invalidPort),
        InvalidCase(input: "host:123456", want: .invalidPort),
        InvalidCase(input: "host:6443", want: .unsupportedPort(6443)),
        InvalidCase(input: "[::1]:22", want: .unsupportedPort(22)),
    ]

    @Test("refused", arguments: invalid)
    func refused(_ c: InvalidCase) {
        #expect(throws: c.want) { try ServerAddress(parsing: c.input) }
    }

    @Test("every refusal has a message")
    func messages() {
        for c in Self.invalid {
            #expect(!c.want.message.isEmpty)
        }
    }
}
