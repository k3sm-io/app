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
/// details button has collapsed it. The left panel is the first pane of a
/// split view (`ConsoleSplit`): its divider drags between the panel's
/// minimum and the width its content could use (`PanelLayout.widthRange`),
/// and the panel collapses on a double-click of the divider or View > Hide
/// Panel; both survive a relaunch on `AppModel`. Every string from the CLI
/// renders verbatim and clipped. The lifecycle controls are the status
/// panel, a popover from the info button. The console follows the system
/// appearance; only the navy Mac panel keeps its own colours.
struct ConsoleView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    static let minSize = CGSize(width: 1180, height: 700)
    /// The inspector's fixed width; collapsing it lowers the minimum width by this much.
    static let inspectorWidth: CGFloat = 320
    /// The split view's divider.
    static let dividerWidth: CGFloat = 1

    /// The content pane's minimum width (the tabs, and the inspector when shown).
    static func contentMinWidth(inspectorShown: Bool) -> CGFloat {
        minSize.width - CGFloat(PanelLayout.minimum) - dividerWidth - (inspectorShown ? 0 : inspectorWidth)
    }

    /// The window's minimum size: the panel's minimum, or nothing while it
    /// is collapsed, plus the content pane's minimum.
    static func minSize(inspectorShown: Bool, panelCollapsed: Bool) -> CGSize {
        let panel = panelCollapsed ? 0 : CGFloat(PanelLayout.minimum) + dividerWidth
        return CGSize(width: panel + contentMinWidth(inspectorShown: inspectorShown), height: minSize.height)
    }

    var body: some View {
        let panel = MacPanel(app: app, workloads: workloads)
        let size = Self.minSize(inspectorShown: app.inspectorShown, panelCollapsed: app.consolePanelCollapsed)
        ConsoleSplit(
            app: app,
            range: PanelLayout.widthRange(content: panel.layoutContent),
            width: app.consolePanelWidth,
            collapsed: app.consolePanelCollapsed,
            contentMinimum: Double(Self.contentMinWidth(inspectorShown: app.inspectorShown)),
            // Each pane is hosted on its own; both run under the transparent
            // title bar, as the whole console did before the split.
            panel: panel.ignoresSafeArea(),
            content: ConsoleContent(app: app).ignoresSafeArea())
        .frame(minWidth: size.width, minHeight: size.height)
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
}

/// ConsoleContent is the split view's second pane: the strip and the chosen
/// tab, then the inspector unless it is collapsed.
struct ConsoleContent: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ConsoleStrip(app: app)
                if let panel = app.updateProgress.panel {
                    UpdateProgressPanel(app: app, panel: panel)
                }
                section
                    .overlay { TabWaitingMark(waiting: app.waiting, section: app.section, placement: .content) }
            }
            .frame(maxWidth: .infinity)
            if app.inspectorShown {
                Divider()
                Inspector(model: app.workloads)
                    .frame(width: ConsoleView.inspectorWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var section: some View {
        switch app.section {
        case .workloads: WorkloadsTab(app: app)
        case .images: ImagesSection(app: app, workloads: app.workloads)
        case .builds:
            if let builds = app.builds {
                BuildsSection(loader: builds)
            } else {
                Color.clear
            }
        case .services:
            if let services = app.services {
                ServicesSection(app: app, loader: services)
            } else {
                Color.clear
            }
        case .storage:
            if let storage = app.storage, let volume = app.dataVolume {
                StorageSection(app: app, claims: storage, volume: volume)
            } else {
                Color.clear
            }
        case .models:
            if let models = app.models {
                ModelsSection(app: app, loader: models)
            } else {
                Color.clear
            }
        }
    }
}

/// ConsoleStrip is the row above the tab: the tab strip, the managed update's
/// button while `UpdateOffer` shows one, the tab's search
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
            TabStrip(selected: app.section, waiting: app.waiting) { app.section = $0 }
            Spacer()
            if let title = app.updateOffer.buttonTitle {
                let offer = app.updateOffer
                Button(title) { app.performUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Palette.blue)
                    .disabled(!offer.isEnabled)
                    .help(offer.disabledReason ?? offer.tag.map { "Update k3sm on every node to \($0)" } ?? title)
            }
            switch app.section {
            case .workloads:
                if app.workloadsView == .pods {
                    search($workloads.query)
                }
            case .images: search($app.imagesQuery)
            case .services: search($app.servicesQuery)
            case .storage: search($app.storageQuery)
            case .models: search($app.modelsQuery)
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

    /// The tab's search field: 180 pt when the strip has room, narrowing to
    /// 100 pt before the tab labels are squeezed.
    private func search(_ text: Binding<String>) -> some View {
        TextField("Search", text: text).textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 180, maxWidth: 180)
    }
}
