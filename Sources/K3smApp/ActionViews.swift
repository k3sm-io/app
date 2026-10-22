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
/// pasteboard, the address in the default browser, a pod's shell in
/// Terminal (`MenuActions.openShell`), a container's log summarized on
/// this Mac (`summarize`, set by the Workloads tab's model), or a build's
/// log sheet (`showBuildLog`, set by `AppModel`). Only http and https
/// addresses are opened, though `K3smStatus` builds no other.
@MainActor
enum LocalActions {
    /// Runs Summarize Logs; the Workloads tab's model sets it.
    static var summarize: ((LogSummaryTarget) -> Void)?
    /// Opens a build's log sheet; `AppModel` sets it, since the sheet is its state.
    static var showBuildLog: (@MainActor (BuildLogTarget) -> Void)?

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
        case .showBuildLog(let target):
            showBuildLog?(target)
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
    var extra: [RowMenuExtra] = []
    let select: () -> Void

    func body(content: Content) -> some View {
        if menu.isEmpty && extra.isEmpty {
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
                if !extra.isEmpty, !(menu.local.isEmpty && menu.items.isEmpty) { Divider() }
                ForEach(extra) { item in
                    Button(item.title) {
                        select()
                        item.perform()
                    }
                    .disabled(!item.enabled)
                }
            }
        }
    }
}

/// RowMenuExtra is a context-menu item that does not go through the action
/// runner: a behind node's Update, which runs the one update plan through
/// `AppModel.performUpdate` and the checked root step.
struct RowMenuExtra: Identifiable {
    let id: String
    let title: String
    let enabled: Bool
    let perform: @MainActor () -> Void
}

/// BulkActionsSlot is a tab's actions over many rows, at the trailing edge
/// of the tab's header row (`TabHeader.placement`): one button per item,
/// and the last bulk action's line on this tab (its row key is
/// `ActionMenu.bulkRowKey`) beside them until the tab's next good read
/// clears it; nothing while the tab offers none and has no line.
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
                        .help(Help.Actions.fullLine(report.text))
                }
                ForEach(items) { item in
                    Button(item.title) { runner.ask(item.request) }
                        .controlSize(.small)
                        .disabled(runner.busy || runner.pending != nil)
                        .help(Help.Actions.tag(for: item))
                }
            }
        }
    }
}

/// TabHeaderRow is a tab's own header row (`TabHeader.Placement.ownRow`):
/// its bulk actions right-aligned, drawn only while `TabHeader.showsRow`
/// says it holds something, so a tab with nothing to offer keeps no empty row.
struct TabHeaderRow: View {
    let items: [ActionMenuItem]
    let section: ConsoleSection
    @ObservedObject var runner: ActionRunner

    var body: some View {
        let hasLine = runner.report(section: section, rowKey: ActionMenu.bulkRowKey) != nil
        if TabHeader.showsRow(section, hasActions: !items.isEmpty, hasLine: hasLine) {
            HStack(spacing: CGFloat(TabHeader.spacing)) {
                Spacer()
                BulkActionsSlot(items: items, section: section, runner: runner)
            }
            .tabHeaderRow()
        }
    }
}

extension View {
    /// A tab's header row: the one height and padding every tab's uses (`TabHeader`).
    func tabHeaderRow() -> some View {
        frame(height: CGFloat(TabHeader.height))
            .padding(.horizontal, CGFloat(TabHeader.horizontalPadding))
            .padding(.top, CGFloat(TabHeader.topPadding))
    }
}

/// RowActions is the inspector's actions block for one row, on every tab:
/// one Actions menu holding the row's context menu's list (its local
/// actions, which ask nothing, then an `ActionMenu` item each), the
/// running note, and the last action's line when it ran on this row. One
/// control instead of a button per item: the inspector is narrow, and a
/// row of eight buttons truncated every title.
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
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(menu.local) { item in
                                Button(item.title) {
                                    LocalActions.perform(item.action)
                                }
                            }
                            if !menu.local.isEmpty, !menu.items.isEmpty { Divider() }
                            ForEach(menu.items) { item in
                                Button(item.title, role: item.destructive ? .destructive : nil) {
                                    runner.ask(item.request)
                                }
                                .disabled(runner.busy || runner.pending != nil)
                            }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                        .fixedSize()
                        .help(Help.Inspector.actions)
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
