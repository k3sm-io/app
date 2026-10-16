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

/// LocalActions performs a row's `LocalAction`: the text on the general
/// pasteboard, the address in the default browser, or a pod's shell in
/// Terminal (`MenuActions.openShell`), or a container's log summarized on
/// this Mac (`summarize`, set by the Workloads tab's model). Only http and
/// https addresses are opened, though `K3smStatus` builds no other.
@MainActor
enum LocalActions {
    /// Runs Summarize Logs; the Workloads tab's model sets it.
    static var summarize: ((LogSummaryTarget) -> Void)?

    static func perform(_ action: LocalAction) {
        switch action {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .open(let url):
            guard url.scheme == "http" || url.scheme == "https" else { return }
            NSWorkspace.shared.open(url)
        case .openShell(let shell):
            MenuActions.openShell(shell)
        case .summarizeLogs(let target):
            summarize?(target)
        }
    }
}

/// ActionConfirmationDialog is the console's one confirmation: shown while
/// the runner holds a pending request, whichever tab, row, menu or key
/// asked for it, with the request's own wording.
struct ActionConfirmationDialog: ViewModifier {
    @ObservedObject var runner: ActionRunner

    func body(content: Content) -> some View {
        content.confirmationDialog(
            runner.pending?.confirmation.title ?? "",
            isPresented: Binding(get: { runner.pending != nil }, set: { if !$0 { runner.cancel() } }),
            titleVisibility: .visible,
            presenting: runner.pending
        ) { request in
            let c = request.confirmation
            Button(c.verbTitle, role: c.destructive ? .destructive : nil) { runner.runPending() }
            Button(c.cancelTitle, role: .cancel) { runner.cancel() }
        } message: { request in
            Text(verbatim: request.confirmation.message)
        }
    }
}

/// RowActionsMenu is a row's context menu: the row's `ActionMenu`, the same
/// list the inspector shows. A row that offers nothing gets no menu.
/// `select` runs before an item asks, so the row the action is about is
/// the one the inspector shows.
struct RowActionsMenu: ViewModifier {
    let menu: ActionMenu
    @ObservedObject var runner: ActionRunner
    let select: () -> Void

    func body(content: Content) -> some View {
        if menu.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(menu.local) { item in
                    Button(item.title) {
                        select()
                        LocalActions.perform(item.action)
                    }
                }
                if !menu.local.isEmpty, !menu.items.isEmpty { Divider() }
                ForEach(menu.items) { item in
                    Button(item.title, role: item.destructive ? .destructive : nil) {
                        select()
                        runner.ask(item.request)
                    }
                    .disabled(runner.busy || runner.pending != nil)
                }
            }
        }
    }
}

/// BulkActionsSlot is a tab's toolbar slot for actions over many rows: one
/// button per item, and the last bulk action's line on this tab (its row
/// key is `ActionMenu.bulkRowKey`) until the tab's next good read clears
/// it; nothing while the tab offers none and has no line.
struct BulkActionsSlot: View {
    let items: [ActionMenuItem]
    let section: ConsoleSection
    @ObservedObject var runner: ActionRunner

    var body: some View {
        let report = runner.report(section: section, rowKey: ActionMenu.bulkRowKey)
        if !items.isEmpty || report != nil {
            HStack(spacing: 8) {
                if let report {
                    Text(verbatim: report.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(report.failed ? Palette.bad : Palette.ink2)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 320, alignment: .trailing)
                        .help(report.text)
                }
                ForEach(items) { item in
                    Button(item.title) { runner.ask(item.request) }
                        .controlSize(.small)
                        .disabled(runner.busy || runner.pending != nil)
                }
            }
        }
    }
}

/// LoaderBulkActions is a tab's bulk slot whose actions come from its own
/// read: it observes the loader, so a new list re-offers them.
struct LoaderBulkActions<Value: Sendable>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<Value>

    var body: some View {
        BulkActionsSlot(items: app.bulkActions, section: app.section, runner: app.actions)
    }
}

/// RowActions is the inspector's actions block for one row, on every tab:
/// a row of its local actions (copies, open in browser), which ask
/// nothing, then a button per `ActionMenu` item (the row's context menu's list), the
/// running note, and the last action's line when it ran on this row.
/// Nothing for a row that offers no action and has no line.
struct RowActions: View {
    let menu: ActionMenu
    let section: ConsoleSection
    let rowKey: String?
    @ObservedObject var runner: ActionRunner

    /// The block for `section`'s selected row.
    static func selected(_ section: ConsoleSection, app: AppModel) -> RowActions {
        let row = app.selection.selection(in: section)
        return RowActions(menu: row.map(app.rowMenu) ?? .empty, section: section, rowKey: row?.key, runner: app.actions)
    }

    var body: some View {
        let report = runner.report(section: section, rowKey: rowKey)
        if !menu.isEmpty || report != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !menu.isEmpty {
                    if !menu.local.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(menu.local) { item in
                                Button(item.title) { LocalActions.perform(item.action) }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(menu.items) { item in
                            Button(item.title) { runner.ask(item.request) }
                                .disabled(runner.busy || runner.pending != nil)
                        }
                        if runner.busy {
                            Text("running…").font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
                        }
                    }
                }
                if let report {
                    Text(verbatim: report.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(report.failed ? Palette.bad : Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
    }
}
