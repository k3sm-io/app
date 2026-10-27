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

import K3smStatus
import SwiftUI

/// LogPaneView is the log pane along the bottom of the console window,
/// below the panel, the tab and the inspector: a title naming the log
/// (`LogPaneSource.title`), its controls, the close button, then the log in
/// a monospaced block that keeps its end in view, and the line saying how
/// the read stands. A pod's log is its last lines of every container
/// (`WorkloadsModel.loadLog`) until Follow streams one container
/// (`LogFollowRead`, Stop ends it); a build's is `BuildLogModel`'s read.
/// Every string from the CLI is cleaned and shown verbatim.
struct LogPaneView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch app.logPane.source {
            case .pod(let key)?:
                podLog(key)
            case .build?:
                if let log = app.buildLog {
                    BuildLogBody(log: log, header: header(title: app.logPane.title ?? "", controls: EmptyView()))
                }
            case nil:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    @ViewBuilder
    private func podLog(_ key: String) -> some View {
        let follow = workloads.shownFollow(podKey: key)
        header(title: app.logPane.title ?? "", controls: followControl(key, follow: follow))
        LogBlock(text: follow?.text ?? (workloads.logLoading ? "loading…" : workloads.logText),
                 count: follow?.data.count ?? -1)
        if let follow {
            LogStatusLine(text: follow.status)
        }
    }

    /// The title, the controls and the close button, on one row.
    private func header(title: String, controls: some View) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            controls
            Button { app.closeLogPane() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close log")
            .help(Help.LogPane.close)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Stop while the pod's log is followed; otherwise Follow, or a menu of
    /// its containers for a pod of several (`LogFollow.targets`); nothing
    /// once the pod is no longer listed.
    @ViewBuilder
    private func followControl(_ key: String, follow: LogFollowRead?) -> some View {
        let targets = workloads.pod(key: key).map(LogFollow.targets(for:)) ?? []
        if let follow, follow.reading {
            Button("Stop") { workloads.stopFollow() }
                .controlSize(.small)
                .help(Help.LogPane.followStop)
        } else if targets.count == 1, let target = targets.first {
            Button("Follow") { workloads.startFollow(target) }
                .controlSize(.small)
                .help(Help.LogPane.follow)
        } else if !targets.isEmpty {
            Menu("Follow") {
                ForEach(targets) { target in
                    Button(target.container?.value ?? target.title) { workloads.startFollow(target) }
                        .help(Help.LogPane.followContainer)
                }
            }
            .controlSize(.small).fixedSize()
            .help(Help.LogPane.followMenu)
        }
    }
}

/// BuildLogBody is a recorded build's log in the pane, observing its read.
private struct BuildLogBody<Header: View>: View {
    @ObservedObject var log: BuildLogModel
    let header: Header

    var body: some View {
        header
        LogBlock(text: log.text, count: log.dataCount)
        LogStatusLine(text: log.status)
    }
}

/// LogBlock is the log itself: monospaced, selectable, scrolled to its end
/// whenever `count` (the bytes read) changes; -1 for a read that does not grow.
private struct LogBlock: View {
    let text: String
    let count: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(verbatim: NodeNameMask.shownText(text))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: count) { if count >= 0 { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Palette.wash)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

/// LogStatusLine is the line under the log saying how its read stands.
private struct LogStatusLine: View {
    let text: String

    var body: some View {
        Text(verbatim: NodeNameMask.shownText(text)).font(.system(size: 11.5))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.bottom, 10)
    }
}
