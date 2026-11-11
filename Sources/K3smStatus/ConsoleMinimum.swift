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

extension WindowFrame {
    /// What the console window's minimum depends on, read once from the
    /// app's state so the view and the window controller cannot drift.
    public struct ConsoleInputs: Equatable, Sendable {
        /// Whether the details button has the inspector shown.
        public var inspectorShown: Bool
        /// Whether the strip and the tabs show (`ConsolePane.stripShown`).
        public var stripShown: Bool
        /// Whether View > Hide Panel has the left panel collapsed.
        public var panelCollapsed: Bool
        /// Where the window buttons end, nil until measured.
        public var windowButtonsEdge: Double?
        /// Whether the strip shows the Developer mode badge.
        public var developerBadge: Bool
        /// The strip's tab labels, in order.
        public var labels: [String]

        public init(inspectorShown: Bool, stripShown: Bool, panelCollapsed: Bool, windowButtonsEdge: Double?,
                    developerBadge: Bool, labels: [String]) {
            self.inspectorShown = inspectorShown
            self.stripShown = stripShown
            self.panelCollapsed = panelCollapsed
            self.windowButtonsEdge = windowButtonsEdge
            self.developerBadge = developerBadge
            self.labels = labels
        }
    }

    /// The console window's minimum height.
    public static let consoleMinimumHeight: Double = 700

    /// The strip's minimum width (`TabStripLayout.minimumWidth`): every tab
    /// label whole, the Developer mode badge while it is shown and the
    /// search field at its minimum. Update is on the Alerts tab's card, not
    /// in the strip, so it costs the strip nothing.
    public static func consoleStripWidth(_ inputs: ConsoleInputs) -> Double {
        TabStripLayout.minimumWidth(labels: inputs.labels, buttonWidth: nil,
                                    badgeWidth: inputs.developerBadge ? TabStripLayout.badgeWidth() : nil)
    }

    /// The tab column's minimum width (`TabStripLayout.columnMinimumWidth`):
    /// the larger of what the window floor leaves and what the strip needs,
    /// which while the panel is collapsed includes clearing the window buttons.
    public static func contentMinimumWidth(_ inputs: ConsoleInputs) -> Double {
        TabStripLayout.columnMinimumWidth(strip: TabStripLayout.stripMinimumWidth(
            strip: consoleStripWidth(inputs), panelCollapsed: inputs.panelCollapsed,
            windowButtonsEdge: inputs.windowButtonsEdge))
    }

    /// The console window's minimum size: the width
    /// `TabStripLayout.windowMinimumWidth` gives, the inspector counted while
    /// it is drawn (`inspectorDrawn`) unless `inspectorOverride` says
    /// otherwise (the placement, `inspectorCountsAtPlacement`), and the
    /// height floor (`consoleMinimumHeight`).
    public static func minimum(_ inputs: ConsoleInputs, inspectorOverride: Bool? = nil) -> Size {
        let inspector = inspectorOverride ?? inspectorDrawn(inspectorShown: inputs.inspectorShown,
                                                            stripShown: inputs.stripShown)
        let width = TabStripLayout.windowMinimumWidth(strip: consoleStripWidth(inputs), inspectorShown: inspector,
                                                      panelCollapsed: inputs.panelCollapsed,
                                                      windowButtonsEdge: inputs.windowButtonsEdge)
        return Size(width: width, height: consoleMinimumHeight)
    }
}
