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

    /// The window's minimum height.
    static let minHeight: CGFloat = 700
    /// The inspector's fixed width; collapsing it lowers the minimum width by this much.
    static let inspectorWidth = CGFloat(TabStripLayout.inspectorWidth)

    /// The strip's minimum width (`TabStripLayout.minimumWidth`): every tab
    /// label whole, the update button while one is offered, the search field
    /// at its minimum.
    static func stripMinWidth(updateTitle: String?) -> Double {
        TabStripLayout.minimumWidth(labels: ConsoleSection.allCases.map(\.title),
                                    buttonWidth: updateTitle.map(TabStripLayout.buttonWidth(title:)))
    }

    /// The content pane's minimum width (the tabs, and the inspector when
    /// shown): the larger of what the window floor leaves and what the strip needs.
    static func contentMinWidth(inspectorShown: Bool, updateTitle: String?) -> CGFloat {
        CGFloat(TabStripLayout.contentMinimumWidth(strip: stripMinWidth(updateTitle: updateTitle), inspectorShown: inspectorShown))
    }

    /// The window's minimum size: the panel's minimum, or nothing while it
    /// is collapsed, plus the content pane's minimum.
    static func minSize(inspectorShown: Bool, panelCollapsed: Bool, updateTitle: String?) -> CGSize {
        let width = TabStripLayout.windowMinimumWidth(strip: stripMinWidth(updateTitle: updateTitle),
                                                      inspectorShown: inspectorShown, panelCollapsed: panelCollapsed)
        return CGSize(width: CGFloat(width), height: minHeight)
    }

    var body: some View {
        let panel = MacPanel(app: app, workloads: workloads)
        let updateTitle = app.updateOffer.buttonTitle
        let size = Self.minSize(inspectorShown: app.inspectorShown, panelCollapsed: app.consolePanelCollapsed,
                                updateTitle: updateTitle)
        ConsoleSplit(
            app: app,
            range: PanelLayout.widthRange(content: panel.layoutContent),
            width: app.consolePanelWidth,
            collapsed: app.consolePanelCollapsed,
            contentMinimum: Double(Self.contentMinWidth(inspectorShown: app.inspectorShown, updateTitle: updateTitle)),
            // Each pane is hosted on its own; both run under the transparent
            // title bar, as the whole console did before the split.
            panel: panel.ignoresSafeArea(),
            content: ConsoleContent(app: app).ignoresSafeArea())
        .frame(minWidth: size.width, minHeight: size.height)
        .background(Palette.surface)
        .overlay { TourOverlay(tour: app.tour) }
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

/// ConsoleContent is the split view's second pane: the strip, the health
/// banner while the health check finds a problem (`HealthBanner`, which opens
/// the guided panel), and the chosen tab, then the inspector (`ConsoleInspector`, following the tab) unless it
/// is collapsed.
struct ConsoleContent: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ConsoleStrip(app: app)
                if let plan = app.guidedPlan {
                    HealthBanner(app: app, plan: plan)
                }
                if let panel = app.updateProgress.panel {
                    UpdateProgressPanel(app: app, panel: panel)
                }
                section
                    .overlay { TabWaitingMark(waiting: app.waiting, section: app.section, placement: .content) }
            }
            .frame(maxWidth: .infinity)
            if app.inspectorShown {
                Divider()
                ConsoleInspector(app: app)
                    .frame(width: ConsoleView.inspectorWidth)
                    .tourTarget(.inspector, app.tour)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        // The one confirmation every tab's actions share, here rather than
        // in the inspector, so a row's menu or the Delete key asks it with
        // the inspector collapsed too.
        .modifier(ActionConfirmationDialog(runner: app.actions))
        // A recorded build's log, opened by its Show Log; closing it stops
        // the read.
        .sheet(isPresented: Binding(get: { app.buildLog != nil }, set: { if !$0 { app.closeBuildLog() } })) {
            if let log = app.buildLog {
                BuildLogSheet(log: log) { app.closeBuildLog() }
            }
        }
        // The guided panel the health banner opens, for the plan it was
        // opened with, so its finished line stays after the state changes.
        .sheet(isPresented: Binding(get: { app.guidedPanel != nil }, set: { if !$0 { app.closeGuided() } })) {
            if let plan = app.guidedPanel {
                GuidedPanelView(app: app, plan: plan)
            }
        }
    }

    @ViewBuilder
    private var section: some View {
        switch app.section {
        case .workloads: WorkloadsTab(app: app).tourTarget(.pods, app.tour)
        case .nodes: NodesSection(app: app, workloads: app.workloads, columns: app.columns)
        case .images: ImagesSection(app: app, workloads: app.workloads, columns: app.columns)
        case .builds:
            if let builds = app.builds, let history = app.buildHistory {
                BuildsSection(app: app, loader: builds, history: history, runner: app.actions, columns: app.columns)
            } else {
                Color.clear
            }
        case .services:
            if let services = app.services {
                ServicesSection(app: app, loader: services, columns: app.columns)
            } else {
                Color.clear
            }
        case .storage:
            if let storage = app.storage, let volume = app.dataVolume {
                StorageSection(app: app, claims: storage, volume: volume, workloads: app.workloads, columns: app.columns)
            } else {
                Color.clear
            }
        case .models:
            if let models = app.models {
                ModelsSection(app: app, loader: models, columns: app.columns)
            } else {
                Color.clear
            }
        case .stats: StatsSection(app: app, workloads: app.workloads)
        }
    }
}

/// ConsoleStrip is the row above the tab: the tab strip, the managed update's
/// button while `UpdateOffer` shows one, the tab's search
/// field (on a tab with rows to search), the details button that shows or
/// collapses the inspector, the tour button, the info button that opens the
/// status panel, and the gear that opens Settings. A tab's bulk actions are
/// on the tab's own header row (`TabHeader`), not here.
struct ConsoleStrip: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    var body: some View {
        HStack(spacing: CGFloat(TabStripLayout.itemSpacing)) {
            TabStrip(selected: app.section, waiting: app.waiting) { app.section = $0 }
                .tourTarget(.tabs, app.tour)
            Spacer()
            if let title = app.updateOffer.buttonTitle {
                let offer = app.updateOffer
                Button(title) { app.performUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Palette.blue)
                    .disabled(!offer.isEnabled)
                    .help(Help.Strip.update(offer))
            }
            switch app.section {
            case .workloads:
                if app.workloadsView == .pods {
                    search($workloads.query)
                }
            case .nodes: search($app.nodesQuery)
            case .images: search($app.imagesQuery)
            case .services: search($app.servicesQuery)
            case .storage: search($app.storageQuery)
            case .models: search($app.modelsQuery)
            case .builds, .stats:
                EmptyView()
            }
            Button { app.inspectorShown.toggle() } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 16)).foregroundStyle(Palette.navy)
                    .opacity(app.inspectorShown ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .accessibilityLabel(app.inspectorShown ? "Hide details" : "Show details")
            .help(Help.Strip.details(shown: app.inspectorShown))
            Button { app.tour.start() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 16)).foregroundStyle(Palette.navy)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take the tour")
            .help(Help.Strip.tour)
            Button { app.statusPanelShown.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Palette.navy)
            }
            .buttonStyle(.plain)
            .tourTarget(.info, app.tour)
            .accessibilityLabel("k3sm status")
            .help(Help.Strip.status)
            .popover(isPresented: $app.statusPanelShown, arrowEdge: .bottom) {
                StatusPopoverPanel(model: app)
            }
            Button { SettingsWindowController.shared?.show() } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(Palette.navy)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .help(Help.Strip.settings)
        }
        .padding(.horizontal, CGFloat(TabStripLayout.padding / 2)).frame(height: CGFloat(TabStripLayout.height))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    /// The tab's search field: 180 pt when the strip has room, narrowing to
    /// `TabStripLayout.searchMinimum` before the tab labels are squeezed.
    private func search(_ text: Binding<String>) -> some View {
        TextField("Search", text: text).textFieldStyle(.roundedBorder).frame(minWidth: CGFloat(TabStripLayout.searchMinimum), idealWidth: 180, maxWidth: 180)
    }
}
