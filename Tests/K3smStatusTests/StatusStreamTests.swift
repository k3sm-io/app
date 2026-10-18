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

/// StatusFakeLauncher stands in for `CLIStream` under `StatusStream`: it
/// records every start and kill, and the test sends each line and exit.
@MainActor
final class StatusFakeLauncher: WatchLauncher {
    final class Process: WatchProcess {
        let arguments: [String]
        var events: WatchEvents?
        var killed = false
        init(arguments: [String]) { self.arguments = arguments }
        func kill() { killed = true }
    }

    private(set) var processes: [Process] = []
    private(set) var lists = 0

    func launch(arguments: [String], events: WatchEvents) -> any WatchProcess {
        let process = Process(arguments: arguments)
        process.events = events
        processes.append(process)
        return process
    }

    func list(arguments: [String], completion: @escaping @MainActor @Sendable (Int32?, Data) -> Void) {
        lists += 1
    }

    /// The newest process: the one the stream holds.
    var newest: Process? { processes.last }

    func send(_ text: String) { newest?.events?.lines([Data(text.utf8)]) }
    func send(_ line: Data) { newest?.events?.lines([line]) }
    func exit(_ exit: WatchExit) { newest?.events?.exit(exit) }
}

/// A one-shot report, with or without the stream's capability.
func streamReport(capabilities: [String], verdict: String = "running") throws -> StatusReport {
    let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
    let json = #"{"schemaVersion":1,"capabilities":[\#(caps)],"verdict":"\#(verdict)","role":"server","summary":"","rows":[]}"#
    return try StatusReport.decode(Data(json.utf8))
}

/// A report frame as the CLI writes it.
func reportFrame(verdict: String = "running") -> String {
    #"{"kind":"report","schemaVersion":1,"report":{"schemaVersion":1,"capabilities":["watch-json"],"verdict":"\#(verdict)","role":"server","summary":"s","rows":[]}}"#
}

func errorFrame(_ code: String) -> String {
    #"{"kind":"error","schemaVersion":1,"code":"\#(code)","message":"a sentence"}"#
}

let closingFrame = #"{"kind":"closing","schemaVersion":1,"code":"lifetime","message":"the stream ends; start a new one"}"#

@Suite("the status stream: k3sm status --watch -o json, its frames and its fallbacks")
@MainActor
struct StatusStreamTests {
    /// A stream that knows its k3sm offers `watch-json`, started, with every
    /// report it hands on recorded.
    @MainActor
    final class Rig {
        let clock = VirtualClock()
        let launcher = StatusFakeLauncher()
        let stream: StatusStream
        var reports: [StatusReport] = []
        var oneShots = 0

        init(capable: Bool = true) throws {
            stream = StatusStream(launcher: launcher, clock: clock, jitter: { 1 })
            stream.onReport = { [unowned self] in self.reports.append($0) }
            stream.onOneShot = { [unowned self] in self.oneShots += 1 }
            stream.start()
            stream.noteCapabilities(try streamReport(capabilities: capable ? ["watch-json"] : []))
        }

        /// Started and live: the first report came.
        static func live() throws -> Rig {
            let rig = try Rig()
            rig.launcher.send(reportFrame())
            return rig
        }
    }

    @Test("the producer's golden first frame decodes as a report frame")
    func goldenDecodes() throws {
        var framer = WatchLineFramer()
        let lines = framer.append(try fixture("status_stream_first_frame.golden"))
        #expect(lines.count == 1)
        guard case .report(let report) = StatusFrame.parse(try #require(lines.first)) else {
            Issue.record("the golden frame did not parse as a report")
            return
        }
        #expect(report.verdict == .running)
        #expect(report.capabilities == ["watch-json"])
        #expect(report.rows.map(\.name) == ["server", "apiserver", "node", "heartbeat", "runtimed"])

        let rig = try Rig()
        rig.launcher.send(try #require(lines.first))
        #expect(rig.reports == [report])
        #expect(rig.stream.state == .live)
        #expect(rig.launcher.newest?.arguments == ["status", "--watch", "-o", "json"])
    }

    @Test("a k3sm without watch-json gets no stream; the trigger keeps running")
    func noCapabilityNoStream() throws {
        let rig = try Rig(capable: false)
        #expect(rig.launcher.processes.isEmpty)
        #expect(rig.stream.state == .unsupported)
        #expect(StatusStream.reportTriggerRuns(consoleShown: true, stream: rig.stream.state))
        // Only the first decoded report decides, once per run.
        rig.stream.noteCapabilities(try streamReport(capabilities: ["watch-json"]))
        rig.stream.start()
        #expect(rig.launcher.processes.isEmpty)

        // Before any report has decoded, nothing is started either.
        let launcher = StatusFakeLauncher()
        let undecided = StatusStream(launcher: launcher, clock: VirtualClock())
        undecided.start()
        #expect(undecided.state == .detecting)
        #expect(launcher.processes.isEmpty)
    }

    @Test("a closing frame restarts the stream at once, with no backoff, still live")
    func closingRestartsAtOnce() throws {
        let rig = try Rig.live()
        rig.clock.advance(by: .seconds(31 * 60))
        let first = try #require(rig.launcher.newest)
        rig.launcher.send(closingFrame)
        #expect(rig.launcher.processes.count == 2)
        #expect(first.killed)
        #expect(rig.stream.state == .live)
        #expect(!StatusStream.reportTriggerRuns(consoleShown: true, stream: rig.stream.state))
        // The old process's exit 0 after its closing frame changes nothing.
        first.events?.exit(.exited(status: 0, errors: ""))
        #expect(rig.stream.state == .live)
        #expect(rig.launcher.processes.count == 2)
    }

    @Test("an exit without closing backs off and gives the reads back to the trigger")
    func exitWithoutClosingFallsBack() throws {
        let rig = try Rig.live()
        #expect(!StatusStream.reportTriggerRuns(consoleShown: true, stream: rig.stream.state))
        rig.launcher.exit(.exited(status: 1, errors: "killed"))
        #expect(rig.stream.state == .retrying)
        #expect(StatusStream.reportTriggerRuns(consoleShown: true, stream: rig.stream.state))
        #expect(rig.launcher.processes.count == 1)
        rig.clock.advance(by: .milliseconds(900))
        #expect(rig.launcher.processes.count == 1)
        rig.clock.advance(by: .milliseconds(100))
        #expect(rig.launcher.processes.count == 2)
        // The trigger keeps the reads until the new process sends a report.
        #expect(rig.stream.state == .retrying)
        rig.launcher.send(reportFrame())
        #expect(rig.stream.state == .live)
        // A second quick death waits longer (the ceiling doubles).
        rig.launcher.exit(.exited(status: 0, errors: ""))
        rig.clock.advance(by: .milliseconds(1500))
        #expect(rig.launcher.processes.count == 2)
        rig.clock.advance(by: .milliseconds(500))
        #expect(rig.launcher.processes.count == 3)
    }

    @Test("a closing frame from a process younger than 30 s ends like a crash")
    func youngClosingBacksOff() throws {
        let rig = try Rig.live()
        rig.launcher.send(closingFrame)
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.stream.state == .retrying)
    }

    @Test("auth-refused and exit 7 are authFailed and never retried")
    func authFailureNoRetry() throws {
        let rig = try Rig.live()
        rig.launcher.send(errorFrame("auth-refused"))
        #expect(rig.stream.state == .authFailed("a sentence"))
        #expect(rig.launcher.newest?.killed == true)
        #expect(StatusStream.reportTriggerRuns(consoleShown: true, stream: rig.stream.state))
        rig.launcher.exit(.exited(status: 7, errors: ""))
        rig.clock.advance(by: .seconds(600))
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.stream.line == "the cluster refused the admin kubeconfig: a sentence")

        let seven = try Rig()
        seven.launcher.exit(.exited(status: 7, errors: ""))
        #expect(seven.stream.state == .authFailed(""))
        seven.clock.advance(by: .seconds(600))
        #expect(seven.launcher.processes.count == 1)
        #expect(seven.stream.line == "the cluster refused the admin kubeconfig")

        // A report that shows the kubeconfig row ok after refused starts it again.
        seven.stream.noteCredential(.refused(remedy: "k3sm kubeconfig --write"))
        #expect(seven.launcher.processes.count == 1)
        seven.stream.noteCredential(.accepted)
        #expect(seven.launcher.processes.count == 2)
        #expect(seven.stream.state == .connecting)
    }

    @Test("frame-too-large asks for one one-shot read and keeps the stream")
    func frameTooLargeReadsOnce() throws {
        let rig = try Rig.live()
        rig.launcher.send(errorFrame("frame-too-large"))
        #expect(rig.oneShots == 1)
        #expect(rig.stream.state == .live)
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.launcher.newest?.killed == false)
    }

    @Test("an unknown frame kind or code is ignored, not fatal")
    func unknownFramesIgnored() throws {
        let rig = try Rig.live()
        rig.launcher.send(#"{"kind":"daemons","schemaVersion":1,"daemons":[]}"#)
        rig.launcher.send(errorFrame("a-code-from-the-future"))
        rig.launcher.send(#"{"kind":"closing","schemaVersion":1,"code":"#)
        rig.launcher.send("not json")
        #expect(rig.stream.state == .live)
        #expect(rig.stream.problem == nil)
        #expect(rig.launcher.processes.count == 1)
        #expect(rig.launcher.newest?.killed == false)
        rig.launcher.send(reportFrame(verdict: "degraded"))
        #expect(rig.reports.map(\.verdict) == [.running, .degraded])
    }

    @Test("apiserver-unreachable, watch-forbidden and no-credentials keep the stream and show the code")
    func problemCodesKeepStreaming() throws {
        for code in ["apiserver-unreachable", "watch-forbidden", "no-credentials"] {
            let rig = try Rig.live()
            rig.launcher.send(errorFrame(code))
            #expect(rig.stream.state == .live)
            #expect(rig.stream.problem?.rawValue == code)
            #expect(rig.stream.line?.contains("(\(code))") == true)
            rig.launcher.send(reportFrame(verdict: "degraded"))
            #expect(rig.reports.count == 2)
            #expect(rig.launcher.processes.count == 1)
        }
    }

    @Test("a report frame this build cannot read degrades the stream until the next start")
    func unreadableReportDegrades() throws {
        let rig = try Rig.live()
        rig.launcher.send(#"{"kind":"report","schemaVersion":2,"report":{"schemaVersion":2,"verdict":"running"}}"#)
        #expect(rig.stream.state == .degraded)
        #expect(rig.launcher.newest?.killed == true)
        rig.clock.advance(by: .seconds(600))
        #expect(rig.launcher.processes.count == 1)
    }

    @Test("a wake replaces a held process once; a stop kills it")
    func wakeAndStop() throws {
        let rig = try Rig.live()
        rig.stream.wake()
        #expect(rig.launcher.processes.count == 2)
        #expect(rig.launcher.processes[0].killed)
        rig.stream.stop()
        #expect(rig.stream.state == .idle)
        #expect(rig.launcher.processes[1].killed)
        #expect(rig.launcher.lists == 0)
    }
}
