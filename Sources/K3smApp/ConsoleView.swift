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

import SwiftUI

/// ConsoleSection is one view of the cluster the console's strip can show.
/// Adding one is a case here and a view in `ConsoleView.section`.
enum ConsoleSection: String, CaseIterable, Identifiable {
    case workloads = "Workloads"
    var id: Self { self }
}

/// ConsoleView is the window once k3sm is installed: this Mac on the left,
/// the chosen section in the middle, the inspector on the right. Every string
/// from the CLI renders verbatim and clipped. The lifecycle controls are the
/// status panel, a popover from the info button. The console is a light
/// design and keeps the light scheme whatever the system appearance.
struct ConsoleView: View {
    @ObservedObject var app: AppModel

    static let minSize = CGSize(width: 1180, height: 700)

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
            Divider()
            Inspector(model: app.workloads)
                .frame(width: 320)
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .background(Color.white)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .onAppear {
            app.workloads.start()
            app.startReportPolling()
        }
        .onDisappear {
            app.workloads.stop()
            app.stopReportPolling()
        }
    }

    @ViewBuilder
    private var section: some View {
        switch app.section {
        case .workloads: WorkloadsSection(model: app.workloads)
        }
    }
}

/// ConsoleStrip is the row above the section: the section chips, the search
/// field, and the info button that opens the status panel.
struct ConsoleStrip: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(ConsoleSection.allCases) { s in
                    Button(s.rawValue) { app.section = s }
                        .buttonStyle(ChipStyle(selected: app.section == s))
                }
            }
            Spacer()
            TextField("Search", text: $workloads.query).textFieldStyle(.roundedBorder).frame(width: 180)
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

/// ChipStyle is a section chip: raised when selected, flat otherwise.
struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Color.primary : Palette.ink2)
            .padding(.horizontal, 13).padding(.vertical, 5)
            .background(selected ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1, y: 1)
    }
}
