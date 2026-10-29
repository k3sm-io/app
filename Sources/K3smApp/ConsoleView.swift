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

/// ConsoleView is the window, from its first opening: this Mac on the left,
/// and in the content pane the guided first run while nothing is installed
/// (`ConsolePane`), else the chosen tab (`ConsoleSection`) in the middle,
/// the inspector on the right unless the
/// details button has collapsed it. The three are the panes of a split view
/// (`ConsoleSplit`); the inspector opens at its default width and keeps the
/// width the user drags its divider to (`InspectorWidth`). The left panel
/// opens at its natural width, the widest
/// either region needs with nothing compressed (`PanelLayout.naturalWidth`),
/// fixed when the window lays out (`PanelWidth`), so live content never
/// moves the divider; the user drags it between the panel's minimum and that
/// width, and the drag is kept; only View > Hide Panel collapses the panel,
/// and while it is hidden the strip starts past the window buttons; both
/// survive a relaunch on `AppModel`. Every string from the CLI
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
    /// The strip's minimum width (`TabStripLayout.minimumWidth`): every tab
    /// label whole and the search field at its minimum. Update is on the
    /// Alerts tab's card, not in the strip, so it costs the strip nothing.
    static func stripMinWidth() -> Double {
        TabStripLayout.minimumWidth(labels: ConsoleSection.allCases.map(\.title), buttonWidth: nil)
    }

    /// The tab column's minimum width: the larger of what the window floor
    /// leaves and what the strip needs, which while the panel is collapsed
    /// includes clearing the window buttons (`windowButtonsEdge`).
    static func contentMinWidth(panelCollapsed: Bool = false, windowButtonsEdge: Double? = nil) -> CGFloat {
        CGFloat(TabStripLayout.columnMinimumWidth(strip: TabStripLayout.stripMinimumWidth(
            strip: stripMinWidth(), panelCollapsed: panelCollapsed, windowButtonsEdge: windowButtonsEdge)))
    }

    /// The window's minimum size: the panel's minimum, or nothing while it
    /// is collapsed, the tab column's minimum, and the inspector's minimum
    /// while it is shown.
    static func minSize(inspectorShown: Bool, panelCollapsed: Bool, windowButtonsEdge: Double? = nil) -> CGSize {
        let width = TabStripLayout.windowMinimumWidth(strip: stripMinWidth(), inspectorShown: inspectorShown,
                                                      panelCollapsed: panelCollapsed, windowButtonsEdge: windowButtonsEdge)
        return CGSize(width: CGFloat(width), height: minHeight)
    }

    var body: some View {
        let panel = MacPanel(app: app, workloads: workloads)
        // The inspector and the log pane follow the tabs: while the set-up
        // flow fills the content pane neither shows.
        let tabs = app.pane.stripShown
        let size = Self.minSize(inspectorShown: app.inspectorShown && tabs, panelCollapsed: app.consolePanelCollapsed,
                                windowButtonsEdge: app.windowButtonsEdge)
        // Only before the first layout does the content's width reach the split.
        let estimate = PanelLayout.naturalWidth(regions: panel.layoutRegions, measured: app.consolePanelMeasured)
        ConsoleSplit(
            app: app,
            range: app.consolePanelWidth.range(estimate: estimate),
            width: app.consolePanelWidth.shown(estimate: estimate),
            collapsed: app.consolePanelCollapsed,
            contentMinimum: Double(Self.contentMinWidth(panelCollapsed: app.consolePanelCollapsed,
                                                        windowButtonsEdge: app.windowButtonsEdge)),
            inspectorWidth: app.inspectorWidth,
            inspectorShown: app.inspectorShown && tabs,
            // Each pane is hosted on its own; all run under the transparent
            // title bar, as the whole console did before the split.
            panel: panel.ignoresSafeArea(),
            content: ConsoleContent(app: app).ignoresSafeArea(),
            inspector: ConsoleInspector(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
                .tourTarget(.inspector, app.tour)
                .ignoresSafeArea(),
            logHeight: app.logPaneHeight,
            logOpen: app.logPane.isOpen && tabs,
            logPane: LogPaneView(app: app).ignoresSafeArea())
        .frame(minWidth: size.width, minHeight: size.height)
        .background(Palette.surface)
        .overlay { TourOverlay(tour: app.tour) }
        .ignoresSafeArea()
        .onAppear {
            app.panelOpened(natural: naturalWidth(panel), measured: app.consolePanelMeasured != nil)
            if app.pane.readsCluster { startReads() }
        }
        .onDisappear { stopReads() }
        // The install check succeeding flips the pane to the tabs in place:
        // the reads start here, not from a new window.
        .onChange(of: app.pane.readsCluster) { _, reads in reads ? startReads() : stopReads() }
        // The first measurement after the window opened lays the panel out;
        // later ones (live content) are ignored by `PanelWidth.measured`.
        .onChange(of: app.consolePanelMeasured) { app.panelLaidOut(natural: naturalWidth(panel)) }
    }

    /// Starts the console's reads: the tabs, the report loop and the flap.
    private func startReads() {
        app.startTabs()
        app.startReportPolling()
        app.flap.start()
    }

    private func stopReads() {
        app.stopTabs()
        app.flap.stop()
        app.stopReportPolling()
    }

    /// The panel's natural width for its content now.
    private func naturalWidth(_ panel: MacPanel) -> Double {
        PanelLayout.naturalWidth(regions: panel.layoutRegions, measured: app.consolePanelMeasured)
    }
}

/// ConsoleContent is the split view's middle pane. While nothing is
/// installed it is the set-up flow (`SetUpPane`) with no strip; once k3sm is
/// installed, the strip, the health banner while the health check finds a
/// problem (`HealthBanner`, which opens the guided panel), and the chosen
/// tab. The inspector (`ConsoleInspector`, following the tab) is the split's
/// third pane. Before the first health check it is empty.
struct ConsoleContent: View {
    @ObservedObject var app: AppModel

    var body: some View {
        switch app.pane {
        case .tabs: tabs
        case .setUp: SetUpPane(model: app).background(Palette.surface)
        case .checking: Palette.surface
        }
    }

    private var tabs: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        // The one confirmation every tab's actions share, here rather than
        // in the inspector, so a row's menu or the Delete key asks it with
        // the inspector collapsed too.
        .modifier(ActionConfirmationDialog(runner: app.actions))
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
        case .cluster: AlertsSection(app: app)
        case .workloads: WorkloadsTab(app: app).tourTarget(.pods, app.tour)
        case .nodes: NodesSection(app: app, workloads: app.workloads, columns: app.columns)
        case .images:
            if let images = app.registryImages {
                ImagesSection(app: app, images: images, columns: app.columns, store: app.imageStore)
            } else {
                Color.clear
            }
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

/// ConsoleStrip is the row above the tab: the tab strip, the tab's search
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
            case .cluster, .builds, .stats:
                EmptyView()
            }
            Button { app.inspectorShown.toggle() } label: {
                // One colour in both states: the symbol carries the state.
                Image(systemName: TabStripLayout.detailsSymbol(shown: app.inspectorShown))
                    .font(.system(size: 16)).foregroundStyle(Palette.navy)
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
        // While the panel is hidden the strip starts at the window's edge,
        // under the window buttons, and its first tab starts past them.
        .padding(.leading, CGFloat(TabStripLayout.leadingInset(panelCollapsed: app.consolePanelCollapsed,
                                                                windowButtonsEdge: app.windowButtonsEdge)))
        .padding(.trailing, CGFloat(TabStripLayout.padding / 2)).frame(height: CGFloat(TabStripLayout.height))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    /// The tab's search field: 180 pt when the strip has room, narrowing to
    /// `TabStripLayout.searchMinimum` before the tab labels are squeezed.
    private func search(_ text: Binding<String>) -> some View {
        TextField("Search", text: text).textFieldStyle(.roundedBorder).frame(minWidth: CGFloat(TabStripLayout.searchMinimum), idealWidth: 180, maxWidth: 180)
    }
}
