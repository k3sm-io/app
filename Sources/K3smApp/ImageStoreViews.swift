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

/// ImageStoreModel runs the Images tab's writes, Untag, Prune and Mirror,
/// one at a time through `ImageStoreDriver` and the checked root step on
/// this Mac. It holds the sheet on screen (the Mirror field or the prune's
/// preview), the Mirror field's text, and the last write's line, and
/// asks for the registry's list and the node list again after each write
/// that ran.
@MainActor
final class ImageStoreModel: ObservableObject {
    /// The sheet the Images tab shows.
    enum Sheet: Equatable {
        case pull
        case prune(ImagePrunePreview, node: String)
    }

    /// The last write's line.
    struct Line: Equatable {
        let text: String
        let failed: Bool
    }

    @Published var sheet: Sheet?
    @Published var pullText = ""
    @Published private(set) var running = false
    @Published private(set) var line: Line?
    /// Reads the Images tab's lists again after a write.
    var refresh: (@MainActor () async -> Void)?

    private let teamID: TeamID?
    private let runner: any PrivilegedRunner

    init(teamID: TeamID?, runner: any PrivilegedRunner) {
        self.teamID = teamID
        self.runner = runner
    }

    private func driver() -> ImageStoreDriver? {
        teamID.map { ImageStoreDriver(teamID: $0, runner: runner, confirm: { Self.confirm($0) }) }
    }

    func openPull() {
        guard !running else { return }
        pullText = ""
        sheet = .pull
    }

    func closeSheet() {
        sheet = nil
    }

    /// Mirrors the field's reference (`k3sm image pull`).
    func pull(scope: ImageStoreScope) {
        let text = pullText
        sheet = nil
        start { await $0.pull(text, scope: scope) }
    }

    /// Deletes `image`'s tag from the cluster registry, after its question.
    func untag(_ image: RegistryImage, role: NodeRole?) {
        start { await $0.untag(image, role: role) }
    }

    /// Runs the prune's dry run and shows what it would delete; nothing to
    /// reclaim in either half is a line, not a sheet, and an empty node cache
    /// with untagged registry manifests still opens the sheet.
    func previewPrune(scope: ImageStoreScope) {
        guard let node = scope.node else { return }
        start { driver in
            switch await driver.previewPrune(scope: scope) {
            case .preview(let preview) where preview.nothingToReclaim:
                return .ran(.succeeded, ImageStoreText.pruneLead(preview, node: node))
            case .preview(let preview):
                self.sheet = .prune(preview, node: node)
                return .declined
            case let other:
                return other
            }
        }
    }

    /// Runs the prune the preview sheet showed, only while this Mac's node
    /// is still the one the preview named.
    func confirmPrune(previewed node: String, scope: ImageStoreScope) {
        sheet = nil
        guard scope.node == node else {
            line = Line(text: ImageStoreText.pruneNodeChanged, failed: true)
            return
        }
        start { await $0.prune(scope: scope) }
    }

    private func start(_ work: @escaping @MainActor (ImageStoreDriver) async -> ImageStoreDriver.Result) {
        guard !running, let driver = driver() else { return }
        running = true
        line = nil
        Task {
            let result = await work(driver)
            running = false
            switch result {
            case .declined:
                break
            case .refused(let why):
                line = Line(text: why, failed: true)
            case .preview:
                break
            case .ran(let outcome, let text):
                line = text.isEmpty ? nil : Line(text: text, failed: outcome != .succeeded && outcome != .cancelled)
                if outcome == .succeeded { await refresh?() }
            }
            log.notice("images: write finished")
        }
    }

    /// Asks Untag's or Mirror's question; Cancel is the default answer.
    private static func confirm(_ question: ImageStoreDriver.Question) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.alertStyle = .warning
        let proceed = alert.addButton(withTitle: question.verbTitle)
        let cancel = alert.addButton(withTitle: "Cancel")
        proceed.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// ImagesHeaderRow is the Images tab's header row: where its writes act
/// (this Mac's node), the last write's line, and Mirror and Prune, each
/// disabled with its reason while the root step cannot run.
struct ImagesHeaderRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var store: ImageStoreModel

    var body: some View {
        let scope = ImageStoreScope.decide(report: app.report)
        let reason = ImageStoreDriver.disabledReason(scope: scope, availability: app.availability, busy: app.running || store.running)
        HStack(spacing: CGFloat(TabHeader.spacing)) {
            Text(verbatim: scope.label).font(.system(size: 11.5)).foregroundStyle(Palette.dimText).lineLimit(1)
            Spacer()
            if let line = store.line {
                Text(verbatim: StatusDisplay.clip(line.text))
                    .font(.system(size: 11.5))
                    .foregroundStyle(line.failed ? Palette.bad : Palette.ink2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .help(Help.Actions.fullLine(line.text))
            }
            Button("Mirror…") { store.openPull() }
                .controlSize(.small)
                .disabled(reason != nil)
                .help(Help.Images.write(Help.Images.pull, disabled: reason))
            Button("Prune…") { store.previewPrune(scope: scope) }
                .controlSize(.small)
                .disabled(reason != nil)
                .help(Help.Images.write(Help.Images.prune, disabled: reason))
        }
        .tabHeaderRow()
    }
}

/// ImageUntagBlock is the image inspector's Untag button for the selected
/// registry image, which deletes its tag from the cluster registry pinned to
/// its digest, disabled with its reason (`ImageStoreDriver.untagDisabledReason`).
struct ImageUntagBlock: View {
    @ObservedObject var app: AppModel
    @ObservedObject var store: ImageStoreModel
    let image: RegistryImage

    var body: some View {
        let role = app.report.flatMap(NodeRole.detect)
        let reason = ImageStoreDriver.untagDisabledReason(image, role: role, availability: app.availability,
                                                          busy: app.running || store.running)
        VStack(alignment: .leading, spacing: 6) {
            Button("Untag…") { store.untag(image, role: role) }
                .disabled(reason != nil)
                .help(Help.Images.write(Help.Images.untag, disabled: reason))
            Text(verbatim: reason ?? ImageStoreText.untagNote).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// ImagePullSheet is the Mirror field: the node it pulls to, the reference,
/// checked as it is typed (`ImageRef`), and Mirror, enabled only for a
/// reference that passes.
struct ImagePullSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var store: ImageStoreModel

    var body: some View {
        let scope = ImageStoreScope.decide(report: app.report)
        let text = store.pullText.trimmingCharacters(in: .whitespaces)
        let problem = ImageRef.problem(text)
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ImageStoreText.pullTitle).font(.system(size: 14, weight: .semibold))
            Text(verbatim: scope.label).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            TextField("Reference", text: $store.pullText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 420)
            Text(verbatim: text.isEmpty ? ImageRef.Problem.empty.text : (problem?.text ?? ImageStoreText.pullNote))
                .font(.system(size: 11.5))
                .foregroundStyle(problem == nil || text.isEmpty ? Palette.ink2 : Palette.bad)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { store.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .help(Help.Images.cancel)
                Button("Mirror") { store.pull(scope: scope) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || scope.node == nil)
                    .help(Help.Images.pullConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// ImagePruneSheet is the prune's preview: the node, what its dry run said
/// it would delete (the digests, the size and what it kept), the cluster
/// registry's untagged manifests or why it is skipped, the caveat that
/// the prune is worked out again when it runs, and Prune, which runs it.
struct ImagePruneSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var store: ImageStoreModel
    let preview: ImagePrunePreview
    let node: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ImageStoreText.pruneTitle).font(.system(size: 14, weight: .semibold))
            Text(verbatim: ImageStoreText.pruneLead(preview, node: node)).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !preview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(ImageStoreText.pruneDigests(preview).enumerated()), id: \.offset) { _, digest in
                            Text(verbatim: digest).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 180)
                .background(Palette.wash)
            }
            if let kept = ImageStoreText.pruneKept(preview) {
                Text(verbatim: StatusDisplay.clip(kept)).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
            }
            if let registry = ImageStoreText.pruneRegistry(preview) {
                Text(verbatim: registry).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: ImageStoreText.pruneCaveat).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { store.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .help(Help.Images.cancel)
                Button("Prune", role: .destructive) { store.confirmPrune(previewed: node, scope: ImageStoreScope.decide(report: app.report)) }
                    .help(Help.Images.pruneConfirm)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
