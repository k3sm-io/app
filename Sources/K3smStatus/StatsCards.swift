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

import Foundation

/// StatsCardLabel is what a Stats card shows above its chart: an SF Symbol,
/// the chart's title and its units line.
///
/// The title and units come from `StatsChart.title` and `StatsChart.unit`;
/// the symbol is chosen here in `K3smStatus` and pinned by a test, never
/// written in a view. No view uses this type yet.
public struct StatsCardLabel: Equatable, Sendable {
    /// The chart the card draws.
    public let chart: StatsChart
    /// The SF Symbol's system name, drawn before the title.
    public let symbolName: String
    /// The card's title.
    public let title: String
    /// The card's units and span, under its title.
    public let unit: String

    public init(chart: StatsChart, symbolName: String, title: String, unit: String) {
        self.chart = chart
        self.symbolName = symbolName
        self.title = title
        self.unit = unit
    }
}

/// StatsHeadline is a Stats card's headline figure: the figure in large
/// type and the caption that says what it counts, for a chart whose data
/// has one ("42" over "pods running").
///
/// Which charts carry a headline, the figure each shows and its caption are
/// decided in `K3smStatus` (beside `StatsDisplay`) and unit-tested; a chart
/// without data for one has no headline, never a zero. Both strings are
/// meant to reach the screen as built here, every cluster-supplied part
/// already clipped by `StatusDisplay.clip`. No view uses this type yet.
public struct StatsHeadline: Equatable, Sendable {
    /// The figure, formatted for display ("42", "3", "118 GB").
    public let figure: String
    /// What the figure counts ("pods running", "restarts in the last hour").
    public let caption: String

    public init(figure: String, caption: String) {
        self.figure = figure
        self.caption = caption
    }
}
