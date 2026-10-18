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

import K3smStatus
@testable import K3smInstall

/// A root step's standard output is kept only when its script asks for it:
/// the image verbs keep it in the run, the join token mint returns it as a
/// secret through the capturing call alone, and every other step keeps
/// nothing. The capturing call refuses any script that did not ask, before
/// anything runs.
@Suite("root step output opt-in")
struct RootScriptTests {
    static let team = TeamID("ABCDE12345")!
    static let image = LifecycleScriptBuilder.renderImage(.pruneDryRun, teamID: team)
    static let mint = JoinTokenMint.render(.workerToken, teamID: team)
    static let stop = LifecycleScriptBuilder.render(LifecycleScriptBuilder.FixedVerb.stop, teamID: team)

    /// Every rendered root step that does not ask for a secret result.
    static var notSecret: [RootScript] {
        var scripts = LifecycleScriptBuilder.FixedVerb.allCases.map { LifecycleScriptBuilder.render($0, teamID: team) }
        scripts += [.pruneDryRun, .prune].map { LifecycleScriptBuilder.renderImage($0, teamID: team) }
        scripts.append(LifecycleScriptBuilder.renderUpdateApply(teamID: team, options: .defaults, release: ReleaseTag("v0.1.8")!))
        return scripts
    }

    @Test("the opt-ins: image verbs keep, the mint is a secret, the rest discard")
    func optIns() {
        #expect(Self.image.result == .kept && Self.image.capturesOutput && !Self.image.returnsSecret)
        #expect(Self.mint.result == .secret && Self.mint.returnsSecret && !Self.mint.capturesOutput)
        #expect(Self.stop.result == .discarded && !Self.stop.capturesOutput && !Self.stop.returnsSecret)
        for script in Self.notSecret { #expect(!script.returnsSecret) }
        #expect(RootScript(text: "", prompt: "", readsInput: false).result == .discarded)
        #expect(RootScript(text: "", prompt: "", readsInput: false, capturesOutput: true).result == .kept)
    }

    @Test("a non-capturing step keeps no output")
    func discardedKeepsNothing() {
        let (run, secret) = PrivilegedCapture.succeeded(Self.stop, result: "stopped\r" + sentinelToken)
        #expect(run == PrivilegedRun(outcome: .succeeded))
        #expect(run.output == nil)
        #expect(secret == nil)
    }

    @Test("an image verb keeps its output in the run, capped, and no secret")
    func imageKeeps() {
        let (run, secret) = PrivilegedCapture.succeeded(Self.image, result: "{\"images\":[]}")
        #expect(run.output == "{\"images\":[]}")
        #expect(!run.outputTruncated)
        #expect(secret == nil)
        let long = String(repeating: "x", count: PrivilegedRun.maxOutputBytes + 1)
        let (cut, _) = PrivilegedCapture.succeeded(Self.image, result: long)
        #expect(cut.output?.utf8.count == PrivilegedRun.maxOutputBytes)
        #expect(cut.outputTruncated)
    }

    @Test("the mint's output is a secret and never rides the run")
    func mintSecret() {
        let (run, secret) = PrivilegedCapture.succeeded(Self.mint, result: sentinelToken)
        #expect(run == PrivilegedRun(outcome: .succeeded))
        #expect(secret == sentinelToken)
    }

    @Test("the capturing call refuses a script without the opt-in before running it")
    func refusesWithoutOptIn() {
        for script in Self.notSecret + [Self.stop, Self.image] {
            let ran = Mutex(false)
            let result = PrivilegedCapture.capture(script) { _ in
                ran.withLock { $0 = true }
                return (PrivilegedRun(outcome: .succeeded), sentinelToken)
            }
            #expect(result == .failure(.notCapturable))
            #expect(!ran.withLock { $0 }, "the capturing call ran a script that did not ask for its output")
        }
    }

    @Test("a runner's default capture refuses a script without the opt-in")
    func defaultRunnerRefuses() async {
        struct Plain: PrivilegedRunner {
            func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome { .succeeded }
        }
        #expect(await Plain().runAsRootCapturingOutput(Self.image) == .failure(.notCapturable))
        #expect(await Plain().runAsRootCapturingOutput(Self.mint) == .failure(.notSucceeded(PrivilegedRun(outcome: .couldNotStart))))
    }

    @Test("a secret script is refused by the non-capturing run before it runs")
    func secretRefusedByPlainRun() {
        #expect(PrivilegedCapture.refusal(forRunning: Self.mint) == .secretNotRunnable)
        let ran = Mutex(false)
        let run = PrivilegedCapture.run(Self.mint) { _ in
            ran.withLock { $0 = true }
            return PrivilegedRun(outcome: .succeeded)
        }
        #expect(run == PrivilegedRun(outcome: .couldNotStart))
        #expect(!ran.withLock { $0 }, "the non-capturing run ran the mint and would drop its token")
        for script in Self.notSecret + [Self.stop, Self.image] {
            #expect(PrivilegedCapture.refusal(forRunning: script) == nil)
            #expect(PrivilegedCapture.run(script) { _ in PrivilegedRun(outcome: .succeeded) } == PrivilegedRun(outcome: .succeeded))
        }
    }

    @Test("a runner's default error-reporting run refuses a secret script before runAsRoot")
    func defaultReportingRefusesSecret() async {
        final class Counting: PrivilegedRunner, @unchecked Sendable {
            let calls = Mutex(0)
            func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
                calls.withLock { $0 += 1 }
                return .succeeded
            }
        }
        let runner = Counting()
        #expect(await runner.runAsRootReportingError(Self.mint, input: nil) == PrivilegedRun(outcome: .couldNotStart))
        #expect(runner.calls.withLock { $0 } == 0, "runAsRoot ran the mint")
        #expect(await runner.runAsRootReportingError(Self.stop, input: nil) == PrivilegedRun(outcome: .succeeded))
        #expect(runner.calls.withLock { $0 } == 1)
    }

    @Test("the mint path still captures: success, failure, and the size limit")
    func mintCaptures() {
        let ok = PrivilegedCapture.capture(Self.mint) { PrivilegedCapture.succeeded($0, result: sentinelToken) }
        #expect(ok == .success(sentinelToken))
        let failed = PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "boom")
        #expect(PrivilegedCapture.capture(Self.mint) { _ in (failed, nil) } == .failure(.notSucceeded(failed)))
        #expect(PrivilegedCapture.capture(Self.mint) { PrivilegedCapture.succeeded($0, result: nil) } == .failure(.outputRefused))
        let big = String(repeating: "a", count: capturedOutputLimit + 1)
        #expect(PrivilegedCapture.capture(Self.mint) { PrivilegedCapture.succeeded($0, result: big) } == .failure(.outputRefused))
        let edge = String(repeating: "a", count: capturedOutputLimit)
        #expect(PrivilegedCapture.capture(Self.mint) { PrivilegedCapture.succeeded($0, result: edge) } == .success(edge))
    }
}
