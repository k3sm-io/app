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

import AppKit
import K3smStatus
import SwiftUI

/// FieldScene is where the Alerts tab rests when nothing is wrong: a low
/// hill line with a few flowers on it in Palette colours, and the k3sm
/// butterfly (`FieldButterfly`, the mark's own art) flying the fluttering
/// flight `FieldFlight.pose` samples on a display-rate timeline, now and
/// then landing on a flower and resting there side-on with its wings
/// closed (`FoldedButterfly`). Under Reduce Motion the timeline is paused
/// and the butterfly perches side-on on the tallest flower. The scene is
/// decoration: the line above it says the same thing, so it is hidden from
/// accessibility.
struct FieldScene: View {
    /// The butterfly's size, in points.
    static let markSize: CGFloat = 26
    /// The scene's height, in points.
    static let height: CGFloat = 170

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Hill().fill(Palette.ok.opacity(0.12))
                Hill().stroke(Palette.ok.opacity(0.55), lineWidth: 1.5)
                ForEach(Array(FieldFlight.flowers.indices), id: \.self) { index in
                    Flower(index: index).position(x: w * CGFloat(FieldFlight.flowers[index].x), y: h / 2)
                }
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let pose = FieldFlight.pose(at: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                    Group {
                        if pose.folded {
                            // Side-on with the wings closed, facing the way it turned.
                            FoldedButterfly(scale: 1, color: Palette.navy)
                                .scaleEffect(x: pose.turn < 0 ? -1 : 1, y: 1)
                        } else {
                            FieldButterfly(beat: pose.beat, hindBeat: pose.hindBeat, pitch: pose.pitch, turn: pose.turn, color: Palette.navy)
                        }
                    }
                    .frame(width: Self.markSize, height: Self.markSize)
                    .rotationEffect(.degrees(pose.tilt))
                    // The pose is the body's place: a folded mark's body is at its
                    // feet line, a flying one's at its centre.
                    .position(x: w * CGFloat(pose.x),
                              y: h * CGFloat(pose.y) - (pose.folded ? Self.markSize * CGFloat(TabStripLayout.markFoot - 0.5) : 0))
                }
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Hill is the field's ground: the line `FieldFlight.hill` describes across
/// the scene, closed along the bottom so it can be filled.
private struct Hill: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 48
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(x),
                                y: rect.minY + rect.height * CGFloat(FieldFlight.ground - FieldFlight.hill(at: x)))
            if step == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Flower is one of the field's flowers, `FieldFlight.flowers[index]`: a
/// stem from the hill line to its top, a leaf, and a round head, drawn in a
/// full-height column centred on the flower's x.
private struct Flower: View {
    let index: Int

    /// The heads' colours, taken in turn.
    static let heads: [Color] = [Palette.fillSoft, Palette.vm, Palette.glowSoft, Palette.blue, Palette.dockMark, Palette.fill]

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, mid = geo.size.width / 2
            let top = FieldFlight.flowerTop(index)
            let base = h * CGFloat(FieldFlight.ground - FieldFlight.hill(at: top.x))
            let head = h * CGFloat(top.y)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: mid, y: base))
                    p.addLine(to: CGPoint(x: mid, y: head))
                }
                .stroke(Palette.ok.opacity(0.7), lineWidth: 1.5)
                Ellipse().fill(Palette.ok.opacity(0.55))
                    .frame(width: 7, height: 3.5)
                    .rotationEffect(.degrees(-30))
                    .position(x: mid + 4, y: (base + head) / 2)
                Circle().fill(Self.heads[index % Self.heads.count])
                    .frame(width: 7, height: 7)
                    .position(x: mid, y: head)
            }
        }
        .frame(width: 16)
    }
}
