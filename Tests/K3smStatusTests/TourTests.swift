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

import CoreGraphics
import Foundation
import Testing

@testable import K3smStatus

@Suite("tour")
struct TourTests {
    @Test("six stops, one per target, in order")
    func stops() {
        for shape in Self.shapes {
            let steps = Tour.steps(for: shape)
            #expect(steps.map(\.target) == [.summary, .cores, .tabs, .pods, .inspector, .info])
            #expect(steps.count == Tour.count)
            #expect(steps.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty })
        }
        #expect(Set(Tour.steps(for: .single).map(\.target)).count == TourTarget.allCases.count)
        #expect(TourTarget.allCases.filter(\.inPanel) == [.summary, .cores])
    }

    static let shapes: [ClusterShape] = [.single, .serverWithWorkers(macs: 3), .worker, .unknown]

    @Test("the first stop says what the panel's heading says, for each shape")
    func firstStop() {
        #expect(Tour.first(for: .single).title == ClusterDisplay.singleTitle)
        #expect(Tour.first(for: .unknown).title == ClusterDisplay.unknownTitle)
        #expect(Tour.first(for: .serverWithWorkers(macs: 3)).text.contains("a cluster of 3 Macs"))
        #expect(Tour.first(for: .worker).text.contains("the control plane runs on the server Mac"))
        // Only a single Mac runs the whole thing; no other shape may say so.
        for shape in Self.shapes where shape != .single {
            let stop = Tour.first(for: shape)
            #expect(!stop.text.contains("One Mac runs the whole thing"), "\(shape)")
            #expect(stop.title != ClusterDisplay.singleTitle, "\(shape)")
        }
    }

    @Test("the tabs stop names every tab in the strip")
    func tabsStop() {
        let stop = Tour.steps(for: .single).first { $0.target == .tabs }
        #expect(stop != nil)
        for section in ConsoleSection.allCases {
            #expect(stop?.text.contains(section.title) == true, "\(section.title) is missing")
        }
        #expect(stop?.text.contains("Cluster, Workloads, Nodes, Images, Builds, Services, Storage, Models and Stats") == true)
    }

    @Test("a list reads like a sentence")
    func list() {
        #expect(Tour.list([]) == "")
        #expect(Tour.list(["A"]) == "A")
        #expect(Tour.list(["A", "B"]) == "A and B")
        #expect(Tour.list(["A", "B", "C"]) == "A, B and C")
    }

    @Test("a stop is lit when the guide lands, at once under Reduce Motion")
    func reveal() {
        #expect(Tour.reveal(reduceMotion: false) == Tour.flight)
        #expect(Tour.flight > 0)
        #expect(Tour.reveal(reduceMotion: true) == 0)
    }

    /// How far `p` is from the straight line through `a` and `b`.
    static func offLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / (dx * dx + dy * dy).squareRoot()
    }

    @Test("a flight is a straight glide that starts and ends exactly and stays inside")
    func flight() {
        let size = CGSize(width: 1180, height: 732)
        let a = CGPoint(x: 40, y: 680), b = CGPoint(x: 1100, y: 40)
        #expect(Tour.flightPoint(from: a, to: b, at: 0, in: size) == a)
        #expect(Tour.flightPoint(from: a, to: b, at: 1, in: size) == b)
        #expect(Tour.flightPoint(from: a, to: b, at: -1, in: size) == a)
        #expect(Tour.flightPoint(from: a, to: b, at: 2, in: size) == b)
        for i in 0...100 {
            let p = Tour.flightPoint(from: a, to: b, at: Double(i) / 100, in: size)
            #expect(Self.offLine(p, a, b) < 0.01)
            #expect(p.x >= 16 && p.x <= size.width - 16 && p.y >= 16 && p.y <= size.height - 16)
        }
        // It eases: a tenth of the way through, it has covered well under a
        // tenth of the distance (a linear glide would cover exactly a tenth).
        let early = Tour.flightPoint(from: a, to: b, at: 0.1, in: size)
        #expect(early.x - a.x < (b.x - a.x) * 0.05)
        #expect(Tour.flightPoint(from: b, to: b, at: 0.5, in: size) == b)
    }

    @Test("the guide perches on a full-height stop's top-left corner, outside its content")
    func perch() {
        let size = CGSize(width: 1180, height: 732)
        let inspector = CGRect(x: 852, y: 3, width: 325, height: 726)
        let p = Tour.landing(by: inspector, in: size)
        #expect(p.x == inspector.minX)
        #expect(p.y < inspector.minY + 30)
    }

    @Test("with no side free, a big stop holds the card in its lower-right corner")
    func cardInside() {
        let size = CGSize(width: 1000, height: 718), card = CGSize(width: 330, height: 262)
        let pods = CGRect(x: 4, y: 24, width: 690, height: 690)   // the pod list, with the inspector beside it
        let p = Tour.card(card, by: pods, in: size)
        let box = CGRect(origin: p, size: card)
        #expect(box.maxY <= size.height - 12, "card bottom \(box.maxY)")
        #expect(pods.contains(box), "card \(box) not inside the stop")
        #expect(box.maxX == pods.maxX - 16)
    }

    @Test("with no side free, a stop too small to hold the card has it clamped inside", arguments: [
        // Too small both ways: below and right of the stop, clamped to the window.
        (CGRect(x: 300, y: 250, width: 350, height: 200), CGPoint(x: 658, y: 444)),
        // One point narrower than the card and its insets: still clamped.
        (CGRect(x: 300, y: 100, width: 361, height: 330), CGPoint(x: 658, y: 444)),
        // Exactly wide enough: the stop holds the card in its lower-right corner.
        (CGRect(x: 300, y: 100, width: 362, height: 330), CGPoint(x: 316, y: 152)),
    ])
    func cardFallback(stop: CGRect, want: CGPoint) {
        let size = CGSize(width: 1000, height: 718), card = CGSize(width: 330, height: 262)
        #expect(Tour.card(card, by: stop, in: size) == want)
    }

    @Test("the keyboard", arguments: [
        (UInt16(124), false, Tour.Key?.some(.next)), (125, false, .next), (36, false, .next), (49, false, .next),
        (123, false, .back), (126, false, .back), (53, false, .end),
        (0, false, nil), (124, true, nil), (53, true, nil),
    ])
    func keys(code: UInt16, modified: Bool, want: Tour.Key?) {
        #expect(Tour.key(code: code, commandOptionOrControl: modified) == want)
    }

    @Test("stepping: forward ends after the last stop, back stops at the first, Escape ends")
    func stepping() {
        let last = Tour.count - 1
        #expect(Tour.step(after: .next, from: 0) == 1)
        #expect(Tour.step(after: .next, from: last) == nil)
        #expect(Tour.step(after: .back, from: 0) == 0)
        #expect(Tour.step(after: .back, from: 3) == 2)
        #expect(Tour.step(after: .end, from: 2) == nil)
    }

    @Test("the tour's layout shows every stop")
    func layout() {
        let shown = Tour.shown
        #expect(shown.section == .workloads)
        #expect(shown.workloadsView == .pods)
        #expect(!shown.panelCollapsed)
        #expect(shown.panelMode == .thisMac)
        #expect(shown.inspectorShown)
    }

    @Test("a window rectangle converts to a view's top-left coordinates")
    func local() {
        // A view whose frame in the window is x 100...900, y 50...650 (origin bottom left).
        let view = CGRect(x: 100, y: 50, width: 800, height: 600)
        let r = CGRect(x: 150, y: 600, width: 40, height: 30)   // near the view's top-left
        #expect(Tour.local(r, in: view) == CGRect(x: 50, y: 20, width: 40, height: 30))
    }

    @Test("the card goes right of the target when it fits, never over it, and stays inside")
    func card() {
        let size = CGSize(width: 1200, height: 700), card = CGSize(width: 330, height: 180)
        let left = CGRect(x: 20, y: 100, width: 200, height: 120)
        #expect(Tour.card(card, by: left, in: size) == CGPoint(x: 242, y: 100))
        let right = CGRect(x: 1000, y: 100, width: 180, height: 120)
        let placed = CGRect(origin: Tour.card(card, by: right, in: size), size: card)
        #expect(!placed.intersects(right))
        #expect(placed.minX >= 12 && placed.maxX <= size.width - 12 && placed.minY >= 12 && placed.maxY <= size.height - 12)
    }

    @Test("the guide lands inside the window by every kind of stop", arguments: [
        CGRect(x: 20, y: 120, width: 210, height: 260),     // in the panel: above it
        CGRect(x: 267, y: 0, width: 190, height: 52),       // the tab strip at the top: below it
        CGRect(x: 852, y: -8, width: 336, height: 748),     // the inspector, full height: inside its corner
        CGRect(x: 243, y: 44, width: 624, height: 696),     // the pod list down to the bottom: above it
    ])
    func landing(_ stop: CGRect) {
        let size = CGSize(width: 1180, height: 732)
        let p = Tour.landing(by: stop, in: size)
        #expect(p.x >= 20 && p.x <= size.width - 20 && p.y >= 20 && p.y <= size.height - 20, "landed at \(p)")
    }

    @Test("the lit box stays inside the window for every kind of stop", arguments: [
        CGRect(x: 20, y: 82, width: 210, height: 260),      // in the panel: padded all round
        CGRect(x: 267, y: 0, width: 190, height: 52),       // the tab strip at the top
        CGRect(x: 251, y: 52, width: 608, height: 680),     // the pod list down to the bottom
        CGRect(x: 860, y: 0, width: 320, height: 732),      // the inspector, top to bottom at the right
    ])
    func highlight(_ stop: CGRect) {
        let size = CGSize(width: 1180, height: 732)
        let box = Tour.highlight(stop, in: size)
        #expect(box.minX >= 3 && box.minY >= 3 && box.maxX <= size.width - 3 && box.maxY <= size.height - 3, "box \(box)")
        // Where there is room, the box is padded past the stop.
        if stop.minX >= 11 { #expect(box.minX == stop.minX - 8) }
    }

    @Test("the guide's beat stays between flat and its peak and is flat at each period")
    func guide() {
        for i in 0...60 {
            let a = Tour.guideAngle(at: Double(i) * 0.05)
            #expect(a >= 0 && a <= 55 + 1e-9)
        }
        #expect(abs(Tour.guideAngle(at: 0)) < 1e-9)
        #expect(abs(Tour.guideAngle(at: 0.3) - 55) < 1e-9)
        #expect(Tour.guideAngle(at: 1, period: 0) == 0)
    }
}
