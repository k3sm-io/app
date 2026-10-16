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

/// ConsoleView is the window once k3sm is installed: this Mac on the left,
/// the chosen tab (`ConsoleSection`) in the middle, the inspector on the right unless the
/// details button has collapsed it. Every string from the CLI renders verbatim
/// and clipped. The lifecycle controls are the status panel, a popover from
/// the info button. The console follows the system appearance; only the navy
/// Mac panel keeps its own colours.
struct ConsoleView: View {
    @ObservedObject var app: AppModel

    static let minSize = CGSize(width: 1180, height: 700)
    /// The inspector's fixed width; collapsing it lowers the minimum width by this much.
    static let inspectorWidth: CGFloat = 320

    /// The window's minimum size for the inspector's state.
    static func minSize(inspectorShown: Bool) -> CGSize {
        inspectorShown ? minSize : CGSize(width: minSize.width - inspectorWidth, height: minSize.height)
    }

    var body: some View {
        HStack(spacing: 0) {
            MacPanel(app: app, workloads: app.workloads)
                .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                ConsoleStrip(app: app)
                section
            }
            .frame(minWidth: 520)
            if app.inspectorShown {
                Divider()
                Inspector(model: app.workloads)
                    .frame(width: Self.inspectorWidth)
            }
        }
        .frame(
            minWidth: Self.minSize(inspectorShown: app.inspectorShown).width,
            minHeight: Self.minSize(inspectorShown: app.inspectorShown).height
        )
        .background(Palette.surface)
        .ignoresSafeArea()
        .onAppear {
            app.startTabs()
            app.startReportPolling()
            app.flap.start()
        }
        .onDisappear {
            app.stopTabs()
            app.flap.stop()
            app.stopReportPolling()
        }
    }

    @ViewBuilder
    private var section: some View {
        switch app.section {
        case .workloads: WorkloadsSection(model: app.workloads)
        case .images: ImagesSection(app: app, workloads: app.workloads)
        case .builds:
            if let builds = app.builds {
                BuildsSection(loader: builds)
            } else {
                Color.clear
            }
        }
    }
}

/// ConsoleStrip is the row above the tab: the tab strip, the tab's search
/// field (on a tab with rows to search), the details button that shows or
/// collapses the inspector, and the info button that opens the status panel.
struct ConsoleStrip: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    var body: some View {
        HStack(spacing: 12) {
            TabStrip(selected: app.section) { app.section = $0 }
            Spacer()
            switch app.section {
            case .workloads:
                TextField("Search", text: $workloads.query).textFieldStyle(.roundedBorder).frame(width: 180)
            case .images:
                TextField("Search", text: $app.imagesQuery).textFieldStyle(.roundedBorder).frame(width: 180)
            case .builds:
                EmptyView()
            }
            Button { app.inspectorShown.toggle() } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 16)).foregroundStyle(Palette.navy)
                    .opacity(app.inspectorShown ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .accessibilityLabel(app.inspectorShown ? "Hide details" : "Show details")
            .help(app.inspectorShown ? "Hide details (Command-Option-I)" : "Show details (Command-Option-I)")
            Button { app.statusPanelShown.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Palette.navy)
            }
            .buttonStyle(.plain)
            .help("k3sm on this Mac: start, stop, connections, uninstall")
            .popover(isPresented: $app.statusPanelShown, arrowEdge: .bottom) {
                StatusPanel(model: app).frame(width: 560)
            }
        }
        .padding(.horizontal, 16).frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
