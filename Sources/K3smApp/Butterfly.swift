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

/// Butterfly is the k3sm mark, the wordmark's glyph and the tour's guide,
/// drawn as a path so the app ships no image.
struct Butterfly: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.0462, y: 0.0748))
        p.addLine(to: CGPoint(x: 0.0462, y: 0.3517))
        p.addCurve(to: CGPoint(x: 0.2829, y: 0.5765), control1: CGPoint(x: 0.0583, y: 0.4750), control2: CGPoint(x: 0.1591, y: 0.5708))
        p.addLine(to: CGPoint(x: 0.4706, y: 0.5799))
        p.addCurve(to: CGPoint(x: 0.3164, y: 0.6124), control1: CGPoint(x: 0.4174, y: 0.5862), control2: CGPoint(x: 0.3663, y: 0.5929))
        p.addCurve(to: CGPoint(x: 0.2495, y: 0.6535), control1: CGPoint(x: 0.2924, y: 0.6221), control2: CGPoint(x: 0.2692, y: 0.6371))
        p.addCurve(to: CGPoint(x: 0.1904, y: 0.7289), control1: CGPoint(x: 0.2254, y: 0.6736), control2: CGPoint(x: 0.2011, y: 0.6988))
        p.addCurve(to: CGPoint(x: 0.3772, y: 0.9078), control1: CGPoint(x: 0.1466, y: 0.8509), control2: CGPoint(x: 0.2531, y: 0.9751))
        p.addCurve(to: CGPoint(x: 0.4989, y: 0.6209), control1: CGPoint(x: 0.4658, y: 0.8598), control2: CGPoint(x: 0.4916, y: 0.7113))
        p.addCurve(to: CGPoint(x: 0.5020, y: 0.6255), control1: CGPoint(x: 0.4995, y: 0.6231), control2: CGPoint(x: 0.5017, y: 0.6228))
        p.addCurve(to: CGPoint(x: 0.5105, y: 0.7016), control1: CGPoint(x: 0.5053, y: 0.6507), control2: CGPoint(x: 0.5053, y: 0.6766))
        p.addCurve(to: CGPoint(x: 0.6419, y: 0.9252), control1: CGPoint(x: 0.5284, y: 0.7892), control2: CGPoint(x: 0.5671, y: 0.8719))
        p.addLine(to: CGPoint(x: 0.8704, y: 0.9267))
        p.addCurve(to: CGPoint(x: 0.5251, y: 0.5799), control1: CGPoint(x: 0.8619, y: 0.7394), control2: CGPoint(x: 0.7124, y: 0.5892))
        p.addLine(to: CGPoint(x: 0.6882, y: 0.5768))
        p.addCurve(to: CGPoint(x: 0.9513, y: 0.3243), control1: CGPoint(x: 0.8249, y: 0.5662), control2: CGPoint(x: 0.9350, y: 0.4605))
        p.addLine(to: CGPoint(x: 0.9513, y: 0.0748))
        p.addCurve(to: CGPoint(x: 0.9492, y: 0.0733), control1: CGPoint(x: 0.9525, y: 0.0748), control2: CGPoint(x: 0.9510, y: 0.0730))
        p.addCurve(to: CGPoint(x: 0.8549, y: 0.0907), control1: CGPoint(x: 0.9169, y: 0.0751), control2: CGPoint(x: 0.8856, y: 0.0818))
        p.addCurve(to: CGPoint(x: 0.5406, y: 0.3791), control1: CGPoint(x: 0.7162, y: 0.1311), control2: CGPoint(x: 0.5926, y: 0.2437))
        p.addCurve(to: CGPoint(x: 0.5071, y: 0.5008), control1: CGPoint(x: 0.5257, y: 0.4183), control2: CGPoint(x: 0.5138, y: 0.4591))
        p.addCurve(to: CGPoint(x: 0.5020, y: 0.5467), control1: CGPoint(x: 0.5056, y: 0.5090), control2: CGPoint(x: 0.5044, y: 0.5424))
        p.addCurve(to: CGPoint(x: 0.4989, y: 0.5522), control1: CGPoint(x: 0.5011, y: 0.5485), control2: CGPoint(x: 0.4995, y: 0.5503))
        p.addCurve(to: CGPoint(x: 0.4633, y: 0.3943), control1: CGPoint(x: 0.4938, y: 0.4980), control2: CGPoint(x: 0.4819, y: 0.4454))
        p.addCurve(to: CGPoint(x: 0.4223, y: 0.3121), control1: CGPoint(x: 0.4527, y: 0.3651), control2: CGPoint(x: 0.4360, y: 0.3395))
        p.addCurve(to: CGPoint(x: 0.3772, y: 0.2479), control1: CGPoint(x: 0.4107, y: 0.2890), control2: CGPoint(x: 0.3931, y: 0.2686))
        p.addCurve(to: CGPoint(x: 0.0487, y: 0.0733), control1: CGPoint(x: 0.2991, y: 0.1476), control2: CGPoint(x: 0.1746, y: 0.0834))
        p.closeSubpath()
        let t = CGAffineTransform(scaleX: rect.width, y: rect.height).translatedBy(x: rect.minX / rect.width, y: rect.minY / rect.height)
        return p.applying(t)
    }
}

import SwiftUI
/// SideWing is the two closed wings of a butterfly seen from the side, as one
/// silhouette facing right: a straight-ish leading edge rising up and forward
/// from the hinge (`SideWing.hinge`, over the thorax) to the forewing's apex
/// near the top front, the outer margin sweeping down and back to a rounded
/// hindwing lobe at the lower rear, clear of the perch, and the lower edge
/// running forward to the hinge above the abdomen, with a gap between them.
/// The apex is the highest point and the silhouette is taller than wide.
/// Drawn as a path so the app ships no image.
struct SideWing: Shape {
    /// The hinge, at the thorax, as a fraction of the mark's square.
    static let hinge = UnitPoint(x: 0.52, y: 0.70)

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        p.move(to: pt(0.52, 0.70))
        // Leading edge, up and forward to the forewing's apex, the highest point.
        p.addCurve(to: pt(0.72, 0.05), control1: pt(0.60, 0.48), control2: pt(0.70, 0.22))
        // The outer margin, one long gentle curve down and back.
        p.addCurve(to: pt(0.26, 0.44), control1: pt(0.60, 0.04), control2: pt(0.32, 0.20))
        // The hindwing's small rounded lobe at the lower rear, clear of the abdomen.
        p.addCurve(to: pt(0.24, 0.66), control1: pt(0.14, 0.50), control2: pt(0.14, 0.64))
        // The lower edge, forward to the hinge above the abdomen.
        p.addCurve(to: pt(0.52, 0.70), control1: pt(0.34, 0.68), control2: pt(0.44, 0.67))
        p.closeSubpath()
        return p
    }
}

/// SideBody is the butterfly's body seen from the side, facing right: a
/// round head at the front, the thorax under the wings' hinge, and a slim
/// abdomen tapering back to a point below the wings, with a gap between them.
struct SideBody: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        p.move(to: pt(0.16, 0.80))
        p.addCurve(to: pt(0.46, 0.74), control1: pt(0.24, 0.77), control2: pt(0.36, 0.76))
        p.addCurve(to: pt(0.60, 0.73), control1: pt(0.50, 0.69), control2: pt(0.58, 0.69))
        p.addCurve(to: pt(0.56, 0.84), control1: pt(0.63, 0.76), control2: pt(0.62, 0.83))
        p.addCurve(to: pt(0.16, 0.80), control1: pt(0.40, 0.85), control2: pt(0.22, 0.84))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: rect.minX + 0.60 * rect.width, y: rect.minY + 0.68 * rect.height,
                                width: 0.11 * rect.width, height: 0.11 * rect.height))
        return p
    }
}

/// SideAntennae is the pair of antennae seen from the side: two thin lines
/// from the head, angled forward and up, each ending in a club
/// (`SideClubs`).
struct SideAntennae: Shape {
    /// Where each antenna leaves the head and where its club is.
    static let lines: [(from: UnitPoint, to: UnitPoint)] = [
        (UnitPoint(x: 0.70, y: 0.71), UnitPoint(x: 0.92, y: 0.62)),
        (UnitPoint(x: 0.68, y: 0.69), UnitPoint(x: 0.88, y: 0.47)),
    ]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for line in Self.lines {
            p.move(to: CGPoint(x: rect.minX + line.from.x * rect.width, y: rect.minY + line.from.y * rect.height))
            p.addLine(to: CGPoint(x: rect.minX + line.to.x * rect.width, y: rect.minY + line.to.y * rect.height))
        }
        return p
    }
}

/// SideClubs is the antennae's round clubbed tips.
struct SideClubs: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = 0.07 * rect.width
        for line in SideAntennae.lines {
            let c = CGPoint(x: rect.minX + line.to.x * rect.width, y: rect.minY + line.to.y * rect.height)
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return p
    }
}

/// SideLegs is three hairline legs from the thorax down to the perch line.
struct SideLegs: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        for (a, b) in [((0.48, 0.81), (0.42, 0.92)), ((0.53, 0.82), (0.53, 0.92)), ((0.57, 0.81), (0.63, 0.92))] {
            p.move(to: pt(a.0, a.1))
            p.addLine(to: pt(b.0, b.1))
        }
        return p
    }
}

/// SideButterfly is the label mark seen from the side, facing right: the far
/// wing, the near wing over it, the body, the clubbed antennae (0.6 pt shafts and
/// 1.4 pt clubs at the 10 pt size) and three legs, in one colour, the far wing a
/// lighter tint of it. As `parting` (degrees) grows the near wing swings open
/// toward the viewer about the body's axis at the hinge, leaning back a
/// quarter as far, and the far wing opens a little the other way, so the far
/// wing's edge shows behind it: the perched beat at the perch's small parting,
/// the descent's wing strokes at the landing's larger one.
struct SideButterfly: View {
    let parting: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                SideWing().fill(color.opacity(0.55))
                    .rotation3DEffect(.degrees(-parting * 0.3), axis: (x: 1, y: 0, z: 0), anchor: SideWing.hinge)
                SideWing().fill(color)
                    .rotation3DEffect(.degrees(parting), axis: (x: 1, y: 0, z: 0), anchor: SideWing.hinge)
                    .rotationEffect(.degrees(-parting / 4), anchor: SideWing.hinge)
                SideBody().fill(color)
                SideLegs().stroke(color, style: StrokeStyle(lineWidth: w * 0.04, lineCap: .round))
                SideAntennae().stroke(color, style: StrokeStyle(lineWidth: w * 0.06, lineCap: .round))
                SideClubs().fill(color)
            }
        }
    }
}
