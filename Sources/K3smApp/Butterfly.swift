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

import K3smStatus
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


/// FoldedButterfly is the label mark perched, seen from the side and facing
/// right, made only from the mark itself (`FlappingButterfly.half`): the mark
/// turned 90 degrees clockwise so its centre line, the body, lies level and
/// its head points right; its right half mirrored across that line onto the
/// left, so both wing pairs stand together above the body and the lower half
/// is empty; and the whole stretched (`Perch.sideFill`) so the closed wings
/// fill the box the flight mark fills, then drawn at `scale` of that
/// (`PerchPose.sideScale`: 1 at rest, a little smaller on a stroke). The body
/// sits on the perch line (`TabStripLayout.markFoot`), where the flight
/// view's feet are, and stays there as the scale changes.
struct FoldedButterfly: View {
    let scale: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FlappingButterfly.half(left: true, color: color)
                FlappingButterfly.half(left: false, color: color).scaleEffect(x: -1, y: 1, anchor: .center)
            }
            .rotationEffect(.degrees(90), anchor: .center)
            .scaleEffect(x: CGFloat(Perch.sideFill.x * scale), y: CGFloat(Perch.sideFill.y * scale), anchor: .center)
            .offset(y: geo.size.height * CGFloat(TabStripLayout.markFoot - 0.5))
        }
        // One layer, so a fade shows no seam where the mirrored halves overlap.
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
