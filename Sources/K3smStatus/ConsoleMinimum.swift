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

    /// The console window's minimum height. The panel, the tab and the
    /// inspector each scroll in a shorter room, so the height floor is only
    /// what keeps the strip and a few rows of a tab on screen.
    public static let consoleMinimumHeight: Double = 420

    /// The console window's natural height: what a first launch opens at,
    /// the screen allowing (`natural`).
    public static let consoleNaturalHeight: Double = 700

    /// The strip's natural width (`TabStripLayout.minimumWidth`): every tab
    /// label whole, the Developer mode badge while it is shown and the
    /// search field at its minimum. Update is on the Alerts tab's card, not
    /// in the strip, so it costs the strip nothing. A narrower strip scrolls.
    public static func consoleStripWidth(_ inputs: ConsoleInputs) -> Double {
        TabStripLayout.minimumWidth(labels: inputs.labels, buttonWidth: nil,
                                    badgeWidth: inputs.developerBadge ? TabStripLayout.badgeWidth() : nil)
    }

    /// The strip's natural width after its leading inset
    /// (`TabStripLayout.leadingInset`, drawn outside the strip's scroll so
    /// the window buttons never cover a scrolled tab): its content and its
    /// trailing half padding.
    public static func stripScrollWidth(_ inputs: ConsoleInputs) -> Double {
        consoleStripWidth(inputs) - TabStripLayout.padding / 2
    }

    /// The tab column's natural width (`TabStripLayout.columnNaturalWidth`):
    /// the larger of what the window floor leaves and what the strip needs,
    /// which while the panel is collapsed includes clearing the window buttons.
    public static func contentNaturalWidth(_ inputs: ConsoleInputs) -> Double {
        TabStripLayout.columnNaturalWidth(strip: TabStripLayout.stripMinimumWidth(
            strip: consoleStripWidth(inputs), panelCollapsed: inputs.panelCollapsed,
            windowButtonsEdge: inputs.windowButtonsEdge))
    }

    /// The console window's minimum size: the width
    /// `TabStripLayout.windowMinimumWidth` gives (the panel's minimum unless
    /// it is collapsed, the tab column's minimum, and the inspector's
    /// minimum), the inspector counted while it is drawn (`inspectorDrawn`)
    /// unless `inspectorOverride` says otherwise (the placement,
    /// `inspectorCountsAtPlacement`), and the height floor
    /// (`consoleMinimumHeight`). The strip's labels, the Developer mode
    /// badge and the window buttons do not raise it: the strip scrolls.
    public static func minimum(_ inputs: ConsoleInputs, inspectorOverride: Bool? = nil) -> Size {
        let inspector = inspectorOverride ?? inspectorDrawn(inspectorShown: inputs.inspectorShown,
                                                            stripShown: inputs.stripShown)
        let width = TabStripLayout.windowMinimumWidth(inspectorShown: inspector, panelCollapsed: inputs.panelCollapsed)
        return Size(width: width, height: consoleMinimumHeight)
    }

    /// The console window's natural size, at which nothing scrolls sideways:
    /// `TabStripLayout.windowNaturalWidth` of the same inputs, the inspector
    /// counted as in `minimum`, and `consoleNaturalHeight`. A first launch
    /// opens at it (`firstFrame`).
    public static func natural(_ inputs: ConsoleInputs, inspectorOverride: Bool? = nil) -> Size {
        let inspector = inspectorOverride ?? inspectorDrawn(inspectorShown: inputs.inspectorShown,
                                                            stripShown: inputs.stripShown)
        let width = TabStripLayout.windowNaturalWidth(strip: consoleStripWidth(inputs), inspectorShown: inspector,
                                                      panelCollapsed: inputs.panelCollapsed,
                                                      windowButtonsEdge: inputs.windowButtonsEdge)
        return Size(width: width, height: consoleNaturalHeight)
    }
}
