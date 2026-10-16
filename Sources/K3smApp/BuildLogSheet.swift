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
import K3smHost
import K3smInstall
import K3smStatus
import SwiftUI

/// BuildLogModel is a build log sheet's `BuildLogRead` as the view observes
/// it, with the app's run: `k3sm build logs <id>`, or `-f` while the build
/// runs, through the trust-checked CLI with `OutputLimit.buildLog`, its
/// output shown as it arrives. `AppModel`'s `BuildLogSlot` stops the read
/// when the sheet closes or another log replaces it; the cancellation kills
/// the CLI (`CLIProcess`).
@MainActor
final class BuildLogModel: ObservableObject {
    let read: BuildLogRead

    init(read: BuildLogRead) {
        self.read = read
        read.changed = { [weak self] in self?.objectWillChange.send() }
    }

    var id: BuildRecordID { read.target.id }
    var title: String { read.target.title }
    var dataCount: Int { read.data.count }
    var text: String { BuildLog.text(read.data) }
    var status: String { BuildLog.status(read.end, follow: read.target.follow, id: read.target.id, empty: read.data.isEmpty) }

    /// Starts the read through the trusted CLI.
    func start(environment: [String: String], teamID: TeamID?) {
        let deadline = read.target.follow ? PollSchedule.buildLogDeadline : PollSchedule.listDeadline
        read.start { arguments, onOutput in
            let cli = TrustedCLI<CLIOutcome>(
                check: { await Task.detached { SelfCheck.installedCLITrust(team: teamID) }.value },
                execute: { arguments in
                    await CLIProcess.run(
                        path: K3smCLI.path, arguments: arguments, environment: environment,
                        deadline: deadline, limit: OutputLimit.buildLog, keepErrors: true, onOutput: onOutput)
                })
            return Self.end(of: await cli.run(arguments))
        }
    }

    nonisolated private static func end(of result: TrustedCLI<CLIOutcome>.Result) -> BuildLog.End {
        switch result {
        case .refused(let why): return .refused(why)
        case .ran(.refused(let why)): return .refused(why)
        case .ran(.missing): return .missing
        case .ran(.exited(let status, _)): return .exited(status)
        case .ran(.truncated): return .truncated
        case .ran(.killed), .ran(.failedToLaunch): return .stopped
        }
    }
}

/// BuildLogSheet shows one build's stored log: the title, the log in a
/// monospaced block cleaned by `StatusDisplay.body`, the line saying how the
/// read stands, and Close, which stops the read.
struct BuildLogSheet: View {
    @ObservedObject var log: BuildLogModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Log of " + StatusDisplay.clip(log.title)).font(.system(size: 14, weight: .semibold))
            Text(verbatim: log.id.value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.dimText)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: log.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash))
                .onChange(of: log.dataCount) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                Text(verbatim: log.status).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                    .help(Help.Inspector.buildLogClose)
            }
        }
        .padding(18)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
    }
}
