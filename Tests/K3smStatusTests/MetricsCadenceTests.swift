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

/// The metrics poll's cadence sized for the view: the step at each demand,
/// under both profiles, across a rise and a fall, and the Stats history's
/// timestamps across a change of cadence.
@Suite("the metrics cadence sized for the view")
struct MetricsCadenceTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)
    static let normal = PollProfile.normal.intervals
    static let low = PollProfile.lowPower.intervals

    private static func step(_ demand: MetricsDemand, after elapsed: TimeInterval?, absent: Bool = false,
                             in intervals: PollIntervals = normal) -> MetricsStep {
        MetricsSchedule.step(demand: demand, lastRead: elapsed.map { t0.addingTimeInterval(-$0) }, now: t0,
                             absent: absent, unit: 0, intervals: intervals)
    }

    @Test("fast demand reads every 15 s")
    func fast() {
        #expect(MetricsSchedule.interval(for: .fast, in: Self.normal) == .seconds(15))
        #expect(Self.step(.fast, after: nil) == .read)
        #expect(Self.step(.fast, after: 0) == .wait(.seconds(15)))
        #expect(Self.step(.fast, after: 14) == .wait(.seconds(1)))
        #expect(Self.step(.fast, after: 15) == .read)
    }

    @Test("slow demand reads every 60 s")
    func slow() {
        #expect(MetricsSchedule.interval(for: .slow, in: Self.normal) == .seconds(60))
        #expect(Self.step(.slow, after: nil) == .read)
        #expect(Self.step(.slow, after: 0) == .wait(.seconds(60)))
        #expect(Self.step(.slow, after: 15) == .wait(.seconds(45)))
        #expect(Self.step(.slow, after: 59) == .wait(.seconds(1)))
        #expect(Self.step(.slow, after: 60) == .read)
        // The absent retry is no faster than the slow cadence.
        #expect(Self.step(.slow, after: 30, absent: true) == .wait(.seconds(30)))
        #expect(Self.step(.fast, after: 30, absent: true) == .wait(.seconds(30)))
    }

    @Test("no demand never reads; it only looks again shortly")
    func hidden() {
        #expect(MetricsSchedule.interval(for: .off, in: Self.normal) == nil)
        for elapsed: TimeInterval? in [nil, 0, 15, 60, 3600] {
            #expect(Self.step(.off, after: elapsed) == .wait(MetricsSchedule.hiddenRecheck))
            #expect(Self.step(.off, after: elapsed, absent: true) == .wait(MetricsSchedule.hiddenRecheck))
        }
    }

    @Test("Low power doubles both: 30 s fast, 120 s slow")
    func lowPower() {
        #expect(MetricsSchedule.interval(for: .fast, in: Self.low) == .seconds(30))
        #expect(MetricsSchedule.interval(for: .slow, in: Self.low) == .seconds(120))
        #expect(Self.step(.fast, after: 15, in: Self.low) == .wait(.seconds(15)))
        #expect(Self.step(.fast, after: 30, in: Self.low) == .read)
        #expect(Self.step(.slow, after: 60, in: Self.low) == .wait(.seconds(60)))
        #expect(Self.step(.slow, after: 120, in: Self.low) == .read)
        #expect(Self.step(.off, after: 600, in: Self.low) == .wait(MetricsSchedule.hiddenRecheck))
    }

    @Test("a rise from slow to fast reads at once when the last read is older than 15 s")
    func rise() {
        // 20 s into a slow wait: slow still waits 40 s, fast reads now.
        #expect(Self.step(.slow, after: 20) == .wait(.seconds(40)))
        #expect(Self.step(.fast, after: 20) == .read)
        // A fresh read is not repeated: 5 s in, fast waits the 10 s left.
        #expect(Self.step(.fast, after: 5) == .wait(.seconds(10)))
        // From off, a stale or missing read is taken at once.
        #expect(Self.step(.off, after: 20) == .wait(MetricsSchedule.hiddenRecheck))
        #expect(Self.step(.slow, after: 75) == .read)
        #expect(Self.step(.fast, after: nil) == .read)
    }

    @Test("a fall from fast to slow waits out the slow interval")
    func fall() {
        // 15 s after the last read fast would read; slow waits 45 s more.
        #expect(Self.step(.fast, after: 15) == .read)
        #expect(Self.step(.slow, after: 15) == .wait(.seconds(45)))
        #expect(Self.step(.slow, after: 0) == .wait(.seconds(60)))
    }

    @Test("Stats points carry the real read times across a change of cadence")
    func statsTimestamps() throws {
        let sample = MetricsReading.sampled(MetricsSample(
            nodes: ["mac-a": NodeUsage(name: "mac-a", cores: 1, memoryBytes: 1 << 30)], pods: [:]))
        // Three fast reads 15 s apart, then two slow ones 60 s apart.
        let offsets: [TimeInterval] = [0, 15, 30, 90, 150]
        var history = StatsHistory()
        for offset in offsets { history.record(sample, at: Self.t0.addingTimeInterval(offset)) }
        let points = try #require(history.nodes["mac-a"])
        #expect(points.map(\.at) == offsets.map { Self.t0.addingTimeInterval($0) })

        let node = ClusterNode(name: "mac-a", ready: true, allocatableMilliCPU: 4000, allocatableMemoryBytes: 4 << 30)
        let series = StatsSeries.cpu(history, nodes: [node])
        #expect(series.count == 1)
        #expect(series.first?.points.map(\.at) == offsets.map { Self.t0.addingTimeInterval($0) })
        #expect(series.first?.points.map(\.percent) == Array(repeating: 25, count: offsets.count))
    }
}
