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
import Testing

@testable import K3smStatus

/// The home of the Stats cards' tests. Today it pins only the shape of the
/// contract sketch in `StatsCards.swift`; the implementation adds the
/// tests of each card's label and each chart's headline here.
@Suite("the Stats cards' contract")
struct StatsCardsTests {
    @Test func cardLabelHasItsShape() {
        let label = StatsCardLabel(chart: .cpu, symbolName: "cpu", title: "CPU by node", unit: "% of allocatable")
        let chart: StatsChart = label.chart
        let symbol: String = label.symbolName
        let title: String = label.title
        let unit: String = label.unit
        _ = (chart, symbol, title, unit)
    }

    @Test func headlineHasItsShape() {
        let headline = StatsHeadline(figure: "42", caption: "pods running")
        let figure: String = headline.figure
        let caption: String = headline.caption
        _ = (figure, caption)
    }
}
