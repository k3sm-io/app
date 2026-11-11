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

/// DemoTourHost is what `DemoTourSequence` drives: the app's tour runner,
/// or a fake in a test.
@MainActor
public protocol DemoTourHost: AnyObject {
    /// Waits, bounded, for the console to come on screen; whether it did.
    func consoleShown() async -> Bool
    /// Clears what would hide the tour's rows, before the first step.
    func prepare()
    /// Runs one step other than `windowFrame`; nil when it succeeded,
    /// otherwise why it failed.
    func run(_ step: DemoTour.Step) async -> String?
    /// Sets the window frame; the frame line to print, or why it failed.
    func setFrame(_ frame: DemoTour.Frame) async -> (line: String?, failure: String?)
    /// Writes one line on standard output.
    func say(_ line: String)
}

/// DemoTourSequence is the order a tour runs in: wait for the console, say
/// the ready line, prepare, then each step until `end`, saying the frame
/// line after a `windowFrame` step.
@MainActor
public enum DemoTourSequence {
    /// Runs the entries on `host`; nil when the tour ended, otherwise the
    /// failure line for standard error.
    public static func run(entries: [DemoTour.Entry], host: DemoTourHost) async -> String? {
        guard await host.consoleShown() else {
            return "k3sm demo tour: the console did not come on screen within \(Int(DemoTour.consoleWait)) s (is k3sm installed and running?)"
        }
        host.say(DemoTour.readyLine)
        host.prepare()
        for (n, entry) in entries.enumerated() {
            let reason: String?
            if case .windowFrame(let f) = entry.step {
                let result = await host.setFrame(f)
                if let line = result.line { host.say(line) }
                reason = result.failure
            } else {
                reason = await host.run(entry.step)
            }
            if let reason { return DemoTour.failureLine(index: n + 1, step: entry.step, reason: reason) }
            if entry.step == .end { break }
        }
        return nil
    }
}
