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

@Suite("install in Terminal from a build with no Team ID pin")
struct TerminalInstallTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let dev = SemanticVersion("0.0.0")!
    /// The payload's CLI as the app quotes it (`ShellQuote`).
    static let payload = TerminalScript.Payload(quotedCLI: "'/Applications/k3sm.app/Contents/Resources/payload/k3sm'")
    /// A token-shaped fixture, built at run time so no file holds one whole.
    static let token = "K10" + String(repeating: "ab12", count: 16) + "::fixture:" + String(repeating: "f", count: 32)

    static func installGolden(_ command: String) -> String {
        """
        #!/bin/sh
        set -e
        echo 'Running: \(command.replacingOccurrences(of: "'", with: #"'\''"#))'
        \(command)
        echo 'k3sm is installed; you can close this window and return to k3sm.app.'

        """
    }

    @Test("an unsigned build installs in Terminal from a fixed script, and a join's token never enters it")
    func developerBuildInstallsInTerminal() {
        // The script runs one install command and nothing else: the install
        // script (plain, pinned to a release, plain for a development 0.0.0),
        // or the payload's own install when the app carries one.
        let plain = "curl -fsSL https://k3sm.io/install.sh | sh"
        let pinned = "curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.7 sh"
        let local = "sudo '/Applications/k3sm.app/Contents/Resources/payload/k3sm' install"
        let cases: [(SemanticVersion?, TerminalScript.Payload?, String)] = [
            (nil, nil, plain), (Self.dev, nil, plain), (Self.v017, nil, pinned),
            (Self.v017, Self.payload, local), (Self.dev, Self.payload, local), (nil, Self.payload, local),
        ]
        for (version, payload, command) in cases {
            let script = TerminalScript.install(version: version, payload: payload)
            #expect(script == Self.installGolden(command), "\(String(describing: version)) \(payload != nil)")
            let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#!") && !$0.hasPrefix("echo ") }
            #expect(commands == ["set -e", Substring(command)], "only the install command runs")
        }
        #expect(TerminalScript.install(version: nil, payload: nil) == """
            #!/bin/sh
            set -e
            echo 'Running: curl -fsSL https://k3sm.io/install.sh | sh'
            curl -fsSL https://k3sm.io/install.sh | sh
            echo 'k3sm is installed; you can close this window and return to k3sm.app.'

            """)
        #expect(TerminalScript.fileName.hasSuffix(".command") && !TerminalScript.fileName.contains("/"))

        // The payload path counts only inside the running bundle, on a regular k3sm file.
        let bundle = "/Applications/k3sm.app"
        #expect(TerminalScript.payloadCLIPath(payloadDirectory: bundle + "/Contents/Resources/payload", bundle: bundle,
                                              cliIsRegularFile: true) == bundle + "/Contents/Resources/payload/k3sm")
        #expect(TerminalScript.payloadCLIPath(payloadDirectory: bundle + "/Contents/Resources/payload", bundle: bundle,
                                              cliIsRegularFile: false) == nil)
        #expect(TerminalScript.payloadCLIPath(payloadDirectory: "/tmp/payload", bundle: bundle, cliIsRegularFile: true) == nil)
        #expect(TerminalScript.payloadCLIPath(payloadDirectory: "/Applications/k3sm.app.evil/payload", bundle: bundle,
                                              cliIsRegularFile: true) == nil)
        #expect(TerminalScript.payloadCLIPath(payloadDirectory: bundle + "/../x/payload", bundle: bundle, cliIsRegularFile: true) == nil)

        // An unsigned build offers Install in Terminal as the review's primary, for both choices.
        for payload in [nil, Self.payload] {
            let start = FirstRunFlow.review(path: .start, server: nil, serverArgument: nil, developerBuild: true,
                                            payload: Self.v017, payloadCLI: payload)
            #expect(start.installButton == nil)
            #expect(start.terminalButton == "Install in Terminal")
            #expect(start.terminalScript == TerminalScript.install(version: Self.v017, payload: payload))
            #expect(start.terminalCommand == TerminalScript.installCommand(version: Self.v017, payload: payload))
            let join = FirstRunFlow.review(path: .join, server: "studio.local:9345", serverArgument: "studio.local",
                                           developerBuild: true, payload: Self.v017, payloadCLI: payload)
            #expect(join.installButton == nil)
            #expect(join.terminalButton == "Install in Terminal")
            #expect(join.terminalScript == TerminalScript.join(serverArgument: "studio.local", payload: payload, version: Self.v017))
            #expect(join.terminalScript?.contains("K10") == false)
        }
        // A development 0.0.0 is no release: nothing pins it, and the review names none.
        let devStart = FirstRunFlow.review(path: .start, server: nil, serverArgument: nil, developerBuild: true, payload: Self.dev)
        #expect(devStart.terminalCommand == plain)
        #expect(!devStart.lines.contains { $0.contains("0.0.0") })
        // A signed build keeps the administrator step and opens no Terminal.
        for path in FirstRunPath.allCases {
            let signed = FirstRunFlow.review(path: path, server: "studio.local:9345", serverArgument: "studio.local",
                                             developerBuild: false, payload: Self.v017, payloadCLI: Self.payload)
            #expect(signed.installButton != nil && signed.terminalButton == nil && signed.terminalScript == nil)
            #expect(signed.terminalCommand == nil)
        }

        // A join installs as an agent only: the token is read in Terminal with echo
        // off and piped to sudo into a root-only file, removed on exit; the script never holds one.
        let tokenSteps = """
            trap 'stty echo 2>/dev/null; sudo -n rm -f /var/root/k3sm-join-token 2>/dev/null' EXIT
            echo 'Paste the join token, then press Return. It is not shown.'
            stty -echo
            IFS= read -r token
            stty echo
            echo
            echo 'Running: sudo sh -c '\\''umask 077; cat > /var/root/k3sm-join-token'\\'''
            printf '%s\\n' "$token" | sudo sh -c 'umask 077; cat > /var/root/k3sm-join-token'
            token=
            """
        let joinLocal = TerminalScript.join(serverArgument: "studio.local", payload: Self.payload, version: Self.v017)
        #expect(joinLocal == """
            #!/bin/sh
            set -e
            \(tokenSteps)
            echo 'Running: sudo '\\''/Applications/k3sm.app/Contents/Resources/payload/k3sm'\\'' install --agent --server studio.local --token-file /var/root/k3sm-join-token'
            sudo '/Applications/k3sm.app/Contents/Resources/payload/k3sm' install --agent --server studio.local --token-file /var/root/k3sm-join-token
            echo 'This Mac joined the cluster; you can close this window and return to k3sm.app.'

            """)
        let joinDownload = TerminalScript.join(serverArgument: "studio.local", payload: nil, version: Self.v017)
        #expect(joinDownload == """
            #!/bin/sh
            set -e
            cd "$(dirname "$0")"
            echo 'Running: curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.7 K3SM_INSTALL_DOWNLOAD_ONLY=1 sh'
            curl -fsSL https://k3sm.io/install.sh | K3SM_INSTALL_VERSION=v0.1.7 K3SM_INSTALL_DOWNLOAD_ONLY=1 sh
            echo 'Running: tar -xzf k3sm_0.1.7_darwin_arm64.tar.gz'
            tar -xzf k3sm_0.1.7_darwin_arm64.tar.gz
            \(tokenSteps)
            echo 'Running: sudo ./k3sm install --agent --server studio.local --token-file /var/root/k3sm-join-token'
            sudo ./k3sm install --agent --server studio.local --token-file /var/root/k3sm-join-token
            echo 'This Mac joined the cluster; you can close this window and return to k3sm.app.'

            """)
        let joinDev = TerminalScript.join(serverArgument: "studio.local", payload: nil, version: Self.dev)
        #expect(joinDev?.contains("K3SM_INSTALL_VERSION") == false)
        #expect(joinDev?.contains("tar -xzf k3sm_*_darwin_arm64.tar.gz") == true)
        for script in [joinLocal, joinDownload, joinDev] {
            #expect(script?.contains("K10") == false)
            #expect(script?.contains(Self.token) == false)
            #expect(script?.contains("--token ") == false)
            // Never a plain server install on the join path.
            #expect(script?.contains("| sh\n") == false && script?.contains("k3sm' install\n") == false)
        }
        // A host outside the address grammar builds no script at all.
        #expect(TerminalScript.join(serverArgument: "a.local; rm -rf /", payload: nil, version: nil) == nil)
        #expect(TerminalScript.join(serverArgument: "-x", payload: nil, version: nil) == nil)
        #expect(TerminalScript.join(serverArgument: nil, payload: Self.payload, version: nil) == nil)

        // While Terminal runs it, the screen says so.
        #expect(FirstRunFlow.terminalInstallingLine == "Installing in Terminal: enter your password there when asked")

        // The guided panel runs its install command the same way, and only that command.
        let missing = GuidedSteps.plan(for: .cliMissing, rootStep: false, role: .server, payload: Self.v017)
        #expect(missing?.terminalScript == TerminalScript.install(version: Self.v017, payload: nil))
        let missingLocal = GuidedSteps.plan(for: .cliMissing, rootStep: false, role: .server, payload: Self.v017, payloadCLI: Self.payload)
        #expect(missingLocal?.terminalCommand == local)
        #expect(missingLocal?.terminalScript == TerminalScript.install(version: Self.v017, payload: Self.payload))
        let missingDev = GuidedSteps.plan(for: .cliMissing, rootStep: false, role: .server, payload: Self.dev)
        #expect(missingDev?.terminalCommand == plain)
        let behind = GuidedSteps.plan(for: .versionMismatch(payload: Self.v017, installed: SemanticVersion("0.1.6")!, relation: .newer),
                                      rootStep: false, role: .server, payload: Self.v017)
        #expect(behind?.terminalScript == TerminalScript.install(version: Self.v017, payload: nil))
        let stopped = GuidedSteps.plan(for: .installedStopped(nil), rootStep: false, role: .server, payload: Self.v017)
        #expect(stopped?.terminalCommand == GuidedSteps.startCommand && stopped?.terminalScript == nil)
        let worker = GuidedSteps.plan(for: .versionMismatch(payload: Self.v017, installed: SemanticVersion("0.1.6")!, relation: .newer),
                                      rootStep: false, role: .agent, payload: Self.v017)
        #expect(worker?.terminalScript == nil, "a worker's update runs on the control plane, not here")
        for state in [HealthState.cliMissing, .cliUntrusted("x")] {
            #expect(GuidedSteps.plan(for: state, rootStep: true, role: .server, payload: nil)?.terminalScript == nil)
            #expect(GuidedSteps.plan(for: state, rootStep: true, role: .server, payload: Self.v017)?.terminalScript == nil)
        }
    }

    @Test("the review waits for the install: one flight per check, the check at arrival, never two at once")
    func installWatchFliesAndChecks() {
        // Only an unsigned build's review, with the window shown, waits.
        #expect(InstallWatch.waits(developerBuild: true, firstRunShown: true, step: .review, windowVisible: true))
        #expect(!InstallWatch.waits(developerBuild: false, firstRunShown: true, step: .review, windowVisible: true))
        #expect(!InstallWatch.waits(developerBuild: true, firstRunShown: true, step: .review, windowVisible: false))
        #expect(!InstallWatch.waits(developerBuild: true, firstRunShown: false, step: .review, windowVisible: true))
        for step in FirstRunStep.allCases where step != .review {
            #expect(!InstallWatch.waits(developerBuild: true, firstRunShown: true, step: step, windowVisible: true))
        }

        // The cadence is the flight: 5 s from the left end to the right.
        #expect(InstallWatch.flightTime == 5)
        #expect(Help.FirstRun.installPath.text.contains("every \(Int(InstallWatch.flightTime)) seconds"))
        let t0 = 1000.0
        var watch = InstallWatch(now: t0)
        let width = 400.0
        func pose(_ t: Double, reduce: Bool = false) -> InstallPathPose { InstallPath.pose(watch, at: t, width: width, reduceMotion: reduce) }
        let left = InstallPath.point(0, width: width), right = InstallPath.point(1, width: width)
        #expect(left.x == InstallPath.markSize / 2 && right.x == width - InstallPath.markSize / 2)
        #expect(pose(t0).x == left.x && pose(t0).y == left.y && !pose(t0).landed)
        #expect(abs(pose(t0 + 2.5).x - (left.x + right.x) / 2) < 1e-9)
        #expect(pose(t0 + 5).x == right.x && pose(t0 + 5).y == right.y)
        #expect(pose(t0 + 1).x < pose(t0 + 2).x, "it flies left to right")
        // The path stays in its row, and the mark turns along it.
        for i in 0...100 {
            let p = InstallPath.point(Double(i) / 100, width: width)
            #expect(p.y >= InstallPath.markSize / 2 - InstallPath.amplitude && p.y <= InstallPath.height)
        }
        #expect(abs(pose(t0).heading) > 1, "the wave starts climbing, so the mark is turned")

        // The check fires exactly at arrival, not before.
        #expect(watch.arrival == t0 + 5)
        let r1 = watch.arrive(now: t0 + 4.999)
        #expect(!r1)
        let r2 = watch.arrive(now: t0 + 5)
        #expect(r2)
        #expect(watch.checking && pose(t0 + 6).landed && pose(t0 + 6).x == right.x)
        // No overlap: neither an arrival nor Check Again starts a second check.
        let r3 = watch.arrive(now: t0 + 10)
        #expect(!r3)
        let r4 = watch.checkNow(now: t0 + 10)
        #expect(!r4)
        // Nothing installed: the next flight starts from the left when the check returns.
        let r5 = watch.end(state: .notInstalled, now: t0 + 5.4)
        #expect(!r5)
        #expect(!watch.checking && watch.arrival == t0 + 10.4 && pose(t0 + 5.4).x == left.x)
        // Check Again lands it at once and restarts the flight after the check.
        let r6 = watch.checkNow(now: t0 + 7)
        #expect(r6)
        #expect(pose(t0 + 7).landed && pose(t0 + 7).x == right.x)
        let r7 = watch.end(state: nil, now: t0 + 7.2)
        #expect(!r7)
        #expect(watch.arrival == t0 + 12.2)
        let r8 = watch.end(state: .healthy, now: t0 + 8)
        #expect(!r8, "ending with no check running changes nothing")

        // Installed and up moves the first run on; installed but not up yet waits, then moves on.
        var up = InstallWatch(now: 0)
        let r9 = up.arrive(now: 5)
        let r10 = up.end(state: .healthy, now: 5.1)
        #expect(r9 && r10)
        var mismatch = InstallWatch(now: 0)
        let r11 = mismatch.arrive(now: 5)
        let ahead = HealthState.versionMismatch(payload: Self.v017, installed: SemanticVersion("0.1.8")!, relation: .older)
        let r11b = mismatch.end(state: ahead, now: 5)
        #expect(r11 && r11b)
        var starting = InstallWatch(now: 0)
        let r12 = starting.arrive(now: 5)
        let r13 = starting.end(state: .partlyRunning(down: ["io.k3sm.netd"]), now: 5)
        #expect(r12 && !r13)
        let r14 = starting.arrive(now: 10)
        let r15 = starting.end(state: .cliMissing, now: 10)
        #expect(r14 && !r15)
        let r16 = starting.checkNow(now: 5 + InstallWatch.settleLimit)
        #expect(r16)
        let r17 = starting.end(state: .partlyRunning(down: ["io.k3sm.netd"]), now: 5 + InstallWatch.settleLimit)
        #expect(r17)

        // Reduce Motion: the still mark at the right end, on the same cadence.
        var still = InstallWatch(now: 0)
        for t in [0.0, 2.5, 4.9] {
            let p = InstallPath.pose(still, at: t, width: width, reduceMotion: true)
            #expect(p.landed && p.x == right.x && p.heading == 0)
        }
        let r18 = still.arrive(now: 4.9)
        let r19 = still.arrive(now: 5)
        #expect(!r18 && r19)
    }
}
