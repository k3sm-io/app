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

@Suite("copy-out plan and root script")
struct CopyOutTests {
    static let team = TeamID("ABCDE12345")!
    static let version = SemanticVersion("0.2.0")!
    static let user = ConsoleUser("alice")!

    static func plan(_ action: CopyOutAction, bundle: String = "/Applications/k3sm.app") throws -> CopyOutPlan {
        try CopyOutPlan(bundlePath: bundle, payloadVersion: version, teamID: team, user: user, action: action)
    }

    struct PathCase: Sendable, CustomTestStringConvertible {
        let path: String
        let want: CopyOutPlan.PlanError?
        var testDescription: String { path.debugDescription }
    }

    static let pathCases: [PathCase] = [
        PathCase(path: "/Applications/k3sm.app", want: nil),
        PathCase(path: "/Users/alice/Applications/k3sm.app", want: nil),
        PathCase(path: "/Applications/it's $(id) `x`.app", want: nil),
        PathCase(path: "Applications/k3sm.app", want: .bundlePathNotAbsolute),
        PathCase(path: "", want: .bundlePathNotAbsolute),
        PathCase(path: "/Applications/../tmp/k3sm.app", want: .bundlePathNotCanonical),
        PathCase(path: "/Applications/./k3sm.app", want: .bundlePathNotCanonical),
        PathCase(path: "/Applications//k3sm.app", want: .bundlePathNotCanonical),
        PathCase(path: "/Applications/k3sm.app/", want: .bundlePathNotCanonical),
        PathCase(path: "/Applications/k3sm", want: .bundlePathNotAnApp),
        PathCase(path: "/Applications/.app", want: .bundlePathNotAnApp),
        PathCase(path: "/", want: .bundlePathNotCanonical),
        PathCase(path: "/Applications/k3sm\n.app", want: .bundlePathHasControlCharacter),
        PathCase(path: "/Applications/k3sm\u{0}.app", want: .bundlePathHasControlCharacter),
    ]

    @Test("bundle path validation", arguments: pathCases)
    func bundlePath(_ c: PathCase) {
        if let want = c.want {
            #expect(throws: want) { try Self.plan(.startServer, bundle: c.path) }
        } else {
            #expect(throws: Never.self) { try Self.plan(.startServer, bundle: c.path) }
        }
    }

    @Test("staging naming and requirement")
    func planData() throws {
        let p = try Self.plan(.startServer)
        #expect(CopyOutPlan.stagingRoot == "/Library/k3sm.staging")
        #expect(p.stagingTemplate == "/Library/k3sm.staging/0.2.0.XXXXXXXX")
        #expect(p.designatedRequirement.hasSuffix(#"leaf[subject.OU] = "ABCDE12345""#))
    }

    static let actions: [CopyOutAction] = [
        .startServer,
        .join(try! ServerAddress(parsing: "studio.local")),
        .update(.server),
        .update(.agent(joinServer: try! ServerAddress(parsing: "studio.local"))),
        .repair,
        .uninstall(purge: false),
        .uninstall(purge: true),
    ]

    @Test("every rendered script is valid sh", arguments: actions)
    func syntax(_ action: CopyOutAction) throws {
        let script = RootScriptBuilder.render(try Self.plan(action))
        #expect(try shell(["-n", "-c", script.text]).status == 0)
        #expect(try shell(["-n", "-c", script.command(inputPath: "/dev/null")]).status == 0)
    }

    @Test("every rendered script verifies before it runs anything", arguments: actions)
    func order(_ action: CopyOutAction) throws {
        let text = RootScriptBuilder.render(try Self.plan(action)).text
        func at(_ needle: String) throws -> String.Index {
            try #require(text.range(of: needle)?.lowerBound, "missing \(needle)")
        }
        let sweep = try at("/usr/bin/find \"$root\" -mindepth 1")
        let copy = try at("/usr/bin/ditto --norsrc --noextattr --noqtn --noacl")
        let refuse = try at("-perm +6022")
        let chown = try at("/usr/sbin/chown -R root:wheel")
        let verify = try at("/usr/bin/codesign --verify --strict --deep")
        let run = try at("\"$k3sm\" ")
        #expect(sweep < copy && copy < refuse && refuse < chown && chown < verify && verify < run)
        #expect(text.contains("trap finish EXIT"))
        #expect(text.contains("echo \"copy-out: exit $status\""))
    }

    @Test("the action lines")
    func actionLines() throws {
        let start = RootScriptBuilder.render(try Self.plan(.startServer)).text
        #expect(start.contains(#""$k3sm" 'install' '--from-staging' "$stage" '--user' 'alice'"#))
        #expect(!start.contains("--agent"))

        let join = RootScriptBuilder.render(try Self.plan(.join(try ServerAddress(parsing: "[fd00::1]:9345"))))
        #expect(join.readsInput)
        #expect(join.text.contains(#"( umask 077 && /bin/cat > "$stage"/'join-token' )"#))
        #expect(join.text.contains(#"'--agent' '--server' 'fd00::1' '--token-file' "$stage"/'join-token'"#))

        #expect(!RootScriptBuilder.render(try Self.plan(.startServer)).readsInput)
        #expect(RootScriptBuilder.render(try Self.plan(.uninstall(purge: false))).text.contains("\"$k3sm\" 'uninstall'\n"))
        #expect(RootScriptBuilder.render(try Self.plan(.uninstall(purge: true))).text.contains("\"$k3sm\" 'uninstall' '--purge' '--yes' '--user' 'alice'\n"))
    }

    @Test("a hostile bundle path is interpolated only as one quoted word")
    func hostilePath() throws {
        let path = "/Applications/it's $(touch /tmp/pwned) `id`.app"
        let text = RootScriptBuilder.render(try Self.plan(.startServer, bundle: path)).text
        #expect(text.contains("--noacl " + ShellQuote.quote(path) + " \"$stage\"/'k3sm.app'\n"))
        let unquoted = text.replacingOccurrences(of: ShellQuote.quote(path), with: "")
        #expect(!unquoted.contains("$(touch"))
    }

    @Test("the requirement is passed as one quoted word")
    func requirementWord() throws {
        let p = try Self.plan(.update(.server))
        let text = RootScriptBuilder.render(p).text
        #expect(text.contains("--deep " + ShellQuote.quote("-R=" + p.designatedRequirement) + " "))
    }

    @Test("the command line wraps the script in the lock and a scrubbed environment")
    func commandLine() throws {
        let script = RootScriptBuilder.render(try Self.plan(.join(try ServerAddress(parsing: "studio.local"))))
        let fifo = "/private/var/folders/xy/T/k3sm-input.AbC123/input"
        let line = script.command(inputPath: fifo)
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/lockf -k -t 0 '/Library/k3sm.staging.lock' /bin/sh -c '"))
        #expect(line.hasSuffix(" < " + ShellQuote.quote(fifo)))
        // The sh -c word carries the script byte for byte.
        let word = ShellQuote.quote(script.text)
        #expect(try shell(["-c", "printf '%s' " + word]).output == script.text)
    }

    @Test("prompts are fixed text", arguments: actions)
    func prompts(_ action: CopyOutAction) throws {
        let script = RootScriptBuilder.render(try Self.plan(action))
        #expect(script.prompt.hasPrefix("k3sm wants to "))
        #expect(!script.prompt.contains("studio"))
    }

    struct LogCase: Sendable, CustomTestStringConvertible {
        let name: String
        let log: String
        let want: CopyOutOutcome
        var testDescription: String { name }
    }

    static let logCases: [LogCase] = [
        LogCase(name: "empty", log: "", want: .unfinished),
        LogCase(name: "in progress", log: "copy-out: copying the app bundle\n", want: .unfinished),
        LogCase(name: "success", log: "copy-out: running k3sm install\ncopy-out: exit 0\n", want: .succeeded),
        LogCase(name: "signature refused", log: "copy-out: refused: ...\ncopy-out: exit 77\n\n", want: .failed(77)),
        LogCase(name: "status line not last", log: "copy-out: exit 0\nmore output\n", want: .unfinished),
        LogCase(name: "garbage status", log: "copy-out: exit zero\n", want: .unfinished),
        LogCase(name: "CLI output mimicking a status", log: "k3sm: copy-out: exit 0\n", want: .unfinished),
    ]

    @Test("log outcome", arguments: logCases)
    func outcome(_ c: LogCase) {
        #expect(CopyOutOutcome(log: c.log) == c.want)
    }
}
