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

/// ConsolePane is what the console window's content pane shows. The window is
/// the console from the moment it opens: its chrome and the left panel never
/// change. Only the content pane does: before the first health check it is
/// empty, while nothing is installed it holds the guided first run (the set-up
/// flow), and once k3sm is installed it holds the tab strip and the tabs.
///
/// | health check | install watch | the pane |
/// |---|---|---|
/// | not read yet | not running | checking (empty, no strip) |
/// | any | running | set up, so a half-started install does not flash the tabs |
/// | not installed | not running | set up |
/// | any other state | not running | the tabs |
public enum ConsolePane: Equatable, Sendable, CaseIterable {
    /// Before the first health check: nothing in the pane yet.
    case checking
    /// Nothing installed: the guided first run in the pane, no tab strip.
    case setUp
    /// k3sm is installed, healthy or not: the strip and the chosen tab.
    case tabs

    /// The pane for the health check's state and whether the install watch
    /// is holding the first run on screen.
    public static func of(health: HealthState?, watching: Bool) -> ConsolePane {
        if watching { return .setUp }
        guard let health else { return .checking }
        return health.showsFirstRun ? .setUp : .tabs
    }

    /// Whether the tab strip (and with it the tabs, the inspector and the
    /// info button) shows: only once k3sm is installed.
    public var stripShown: Bool { self == .tabs }

    /// Whether the console's reads run (the tabs' lists, the report loop):
    /// only while the tabs show, so nothing reads a cluster that is not there.
    public var readsCluster: Bool { self == .tabs }

    /// The window's title bar, the same for every pane: the console's
    /// transparent one, so moving between panes never swaps or restyles the
    /// window.
    public var titleBar: ConsoleTitleBar { .transparent }

    /// The left panel's state line: "Not installed" while the set-up flow
    /// shows, else the report's headline (`StatusHeadline.of`).
    public func panelHeadline(report: StatusReport?, podCount: Int?) -> StatusHeadline {
        self == .setUp ? StatusHeadline.notInstalled : StatusHeadline.of(report, podCount: podCount)
    }

    /// The left panel's note while the set-up flow shows.
    public static let setUpPanelNote = "k3sm is not installed on this Mac. Its figures show here once it runs."
}

/// ConsoleTitleBar is the console window's title bar style.
public enum ConsoleTitleBar: Equatable, Sendable {
    /// Transparent, the content running under it and the title hidden.
    case transparent
}

extension StatusHeadline {
    /// The headline while nothing is installed on this Mac.
    public static let notInstalled = StatusHeadline(
        state: StatusHeadline.word(.notInstalled), tone: StatusHeadline.tone(.notInstalled),
        needsAdmin: 0, accessibilityLabel: StatusHeadline.word(.notInstalled))
}
