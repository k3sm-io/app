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

import K3smInstall
import K3smStatus
import SwiftUI

/// NetworkPane is the Settings window's Network pane: the "Allow
/// connections from other devices" switch (`LANSection`, moved here from
/// the info popover), then the current state, the listeners it controls,
/// those it never closes and this node's address (`NetworkPaneFacts`), then
/// the Thunderbolt interconnect's state (`InterconnectSetting`). The
/// report is the last full status read; opening the pane reads it again, so
/// the switch is never judged on a stale read.
struct NetworkPane: View {
    @ObservedObject var app: AppModel
    @ObservedObject var nodes: TabLoader<NodeListRead>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections").font(.headline)
            LANSection(model: app)
            ForEach(NetworkPaneFacts.lines(report: app.lanReport, nodes: nodes.value?.nodes), id: \.self) { line in
                Text(verbatim: line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.lanReport == nil {
                Text("The status of this Mac has not been read yet.").font(.callout).foregroundStyle(.secondary)
            }
            if let interconnect = InterconnectSetting.decide(app.lanReport) {
                InterconnectSection(setting: interconnect)
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
}

/// LANSection is the "Allow connections from other devices" checkbox. It
/// shows the recorded setting from the last full status read, tri-state: an
/// unknown value draws as a dash and cannot be clicked. A click runs the verb
/// opposite to the value shown; the checkbox moves only when the status read
/// after the change confirms it. One decision (`AppModel.lanToggle`, over
/// `LANToggle`) and one administrator-prompt path (`AppModel.performLAN`).
struct LANSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let toggle = model.lanToggle()
        if toggle.visible {
            VStack(alignment: .leading, spacing: 4) {
                if toggle.value == .unknown {
                    HStack(spacing: 6) {
                        Image(systemName: "minus.square")
                        Text(LANToggle.title)
                        Text("(unknown)").foregroundStyle(.secondary)
                    }
                } else {
                    Toggle(LANToggle.title, isOn: Binding(
                        get: { toggle.value == .on },
                        set: { _ in
                            if let verb = toggle.clickVerb { model.performLAN(verb) }
                        }))
                        .toggleStyle(.checkbox)
                        .disabled(!toggle.enabled)
                        .help(Help.Network.lan)
                }
                Text(LANToggle.subtitle).font(.callout).foregroundStyle(.secondary)
                if let reason = toggle.disabledReason {
                    Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(toggle.notes, id: \.self) { note in
                    Text(verbatim: note).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// InterconnectSection is the Thunderbolt interconnect checkbox. It shows
/// the state from the last full status read and cannot be clicked: the app
/// has no privileged step for it, so the note names the Terminal command.
/// An unknown state draws as a dash, as the LAN switch's does.
struct InterconnectSection: View {
    let setting: InterconnectSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Interconnect").font(.headline).padding(.top, 6)
            if setting.state == .unknown {
                HStack(spacing: 6) {
                    Image(systemName: "minus.square")
                    Text(InterconnectSetting.title)
                    Text("(unknown)").foregroundStyle(.secondary)
                }
                .help(Help.Network.interconnect)
            } else {
                Toggle(InterconnectSetting.title, isOn: .constant(setting.state == .on))
                    .toggleStyle(.checkbox)
                    .disabled(!setting.changeable)
                    .help(Help.Network.interconnect)
            }
            ForEach(setting.lines, id: \.self) { line in
                Text(verbatim: line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: setting.note).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
