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
import K3smStatus
import SwiftUI

/// NodeSettingsPaneView is the Settings window's Cluster or Storage pane:
/// the node's install settings from the last full status read, as
/// `NodeSettingsPanes` decides them. Every value is selectable text; a value
/// worth pasting has a Copy button; a value only root can read shows the
/// lock and the needs-administrator sentence. Read-only: there are no edit
/// controls, and the foot says the settings change with `k3sm install`.
/// Opening the pane reads the full report again, as the Network pane does.
struct NodeSettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var app: AppModel

    var body: some View {
        let facts = pane == .storage ? NodeSettingsPanes.storage(app.lanReport) : NodeSettingsPanes.cluster(app.lanReport)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(pane == .storage ? "Data and updates" : "This node").font(.headline)
                if facts.showsLock {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        .accessibilityLabel(StatusDisplay.needsAdminText)
                        .help(Help.InstallSettings.restricted)
                }
            }
            if !facts.lines.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(facts.lines) { line in
                        GridRow {
                            Text(verbatim: line.label).foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            row(line)
                        }
                    }
                }
            }
            if let note = facts.note {
                Text(verbatim: note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !facts.lines.isEmpty {
                Text(verbatim: NodeSettingsPanes.editingNote).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: SettingsWindowController.paneWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard app.screen == .status else { return }
            Task { _ = await app.readFullReport() }
        }
    }

    /// One value: the lock for a restricted one, the text (selectable), and
    /// Copy when the line offers it.
    private func row(_ line: SettingLine) -> some View {
        HStack(spacing: 8) {
            if line.restricted {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .accessibilityLabel(StatusDisplay.needsAdminText)
                    .help(Help.InstallSettings.restricted)
            }
            Text(verbatim: line.value)
                .font(line.copyText == nil ? .body : .system(.body, design: .monospaced))
                .foregroundStyle(line.restricted ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if let copy = line.copyText {
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                }
                .controlSize(.small)
                .help(Help.InstallSettings.copy)
            }
        }
    }
}
