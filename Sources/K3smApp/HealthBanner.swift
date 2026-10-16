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

import AppKit
import K3smInstall
import K3smStatus
import SwiftUI

/// HealthBanner runs across the top of the console while the health check
/// finds k3sm on this Mac not healthy: the state's one sentence and a button
/// that names the next step and opens the guided panel (`GuidedPanelView`).
struct HealthBanner: View {
    @ObservedObject var app: AppModel
    let plan: GuidedPlan

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
                .accessibilityHidden(true)
            Text(verbatim: plan.banner).font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(plan.bannerButton) { app.openGuided() }
                .controlSize(.small)
                .help(Help.Guided.banner)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// GuidedPanelView is the sheet the banner opens: the plan's title, its
/// numbered steps, the Terminal command where the app cannot run the step,
/// one primary button through the existing path (and Repair beside it on a
/// partly running Mac), the step's progress while
/// it runs and the line it ended on.
struct GuidedPanelView: View {
    @ObservedObject var app: AppModel
    let plan: GuidedPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: plan.title).font(.title2).bold()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).").monospacedDigit().foregroundStyle(Palette.ink2)
                        Text(verbatim: step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let command = plan.terminalCommand {
                terminal(command)
            }
            if plan.primary == .update, let block = app.guidedUpdateBlock {
                updateBlock(block)
            }
            progress
            HStack {
                if plan.opensLogs {
                    Button("Open Logs") { MenuActions.openLogs(role: app.role) }
                        .help(Help.Guided.openLogs)
                }
                Spacer()
                Button("Close") { app.closeGuided() }
                    .keyboardShortcut(.cancelAction)
                    .help(Help.Guided.close)
                if let action = plan.secondary {
                    let reason = app.guidedDisabledReason(action)
                    Button(action.title + (action.needsRootStep ? "…" : "")) { app.runGuided(action) }
                        .disabled(reason != nil || app.guidedRun.isRunning)
                        .help(Help.Guided.primary(action, disabledReason: reason))
                }
                if plan.offersRefresh {
                    Button(GuidedAction.refresh.title) { app.runGuided(.refresh) }
                        .disabled(app.guidedRun.isRunning || app.running)
                        .help(Help.Guided.refresh)
                }
                if let action = plan.primary {
                    let reason = app.guidedDisabledReason(action)
                    Button(action.title + (action.needsRootStep ? "…" : "")) { app.runGuided(action) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reason != nil || app.guidedRun.isRunning)
                        .help(Help.Guided.primary(action, disabledReason: reason))
                }
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
    }

    /// The exact command, selectable, with Copy and Open Terminal.
    private func terminal(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .help(Help.Guided.copyCommand)
                Button("Open Terminal") { NSWorkspace.shared.open(MenuActions.terminal) }
                    .help(Help.Guided.openTerminal)
            }
        }
    }

    /// Why Update cannot run yet; for the control plane, the confirmation
    /// the app-carried update asks for.
    @ViewBuilder
    private func updateBlock(_ block: GuidedUpdateBlock) -> some View {
        Text(verbatim: block.text).font(.callout).foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
        if block == .confirmWorkers, let payload = app.payloadVersion {
            ForEach(UpdatePolicy.serverChecks, id: \.self) { Text(verbatim: "• " + $0).font(.callout) }
            Toggle("Every worker runs k3sm " + payload.description + " or newer", isOn: $app.workersConfirmed)
                .help(Help.Guided.workersConfirmed)
        }
    }

    /// The step as it runs (the lifecycle driver's progress line, or the
    /// copy-out log for Update and Repair), then the line it ended on.
    @ViewBuilder
    private var progress: some View {
        switch app.guidedRun {
        case .idle:
            EmptyView()
        case .running(let action):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: app.outcomeMessage.map(StatusDisplay.errorText) ?? "Working…")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if action == .update || action == .repair, !app.logTail.isEmpty {
                RootStepLog(text: app.logTail)
            }
        case .finished(_, let succeeded, _):
            if let line = app.guidedRun.line {
                Label {
                    Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: succeeded ? RowTone.healthy.symbolName : RowTone.attention.symbolName)
                        .foregroundStyle(succeeded ? Palette.ok : Palette.warn)
                }
                .font(.callout)
            }
        }
    }
}
