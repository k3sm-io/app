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

/// FieldButterfly is the Alerts field's butterfly in flight or opening its
/// wings on a flower, made only from the mark itself: the mark cut into
/// four wings, the forewings above the waist (`seam`) and the hindwings
/// below it on each side of the centre line, each drawn through
/// `WingProjection` at its hinge angle with the body at `pitch` and turned
/// `turn` toward its side, so the wings rise over the back and fall below
/// the body as seen from above and a little behind, or, side-on, sweep up
/// over the back and down in profile. The hindwings take `hindBeat`, which
/// trails `beat`. A raised wing is drawn a shade lighter, as a wing turned
/// toward the light is, so the stroke reads in depth. Its body is on the
/// frame's centre; at a 0 beat, pitch and turn it draws exactly the flat
/// mark, and with its wings closed side-on exactly `FoldedButterfly`
/// (whose body is at the frame's feet line, so the scene places the two
/// apart by that much).
struct FieldButterfly: View {
    let beat: Double
    let hindBeat: Double
    let pitch: Double
    let turn: Double
    let color: Color

    /// Where the mark's forewings meet its hindwings, as a fraction of its
    /// height from the top: the waist, where both wing outlines come in to
    /// the body.
    nonisolated static let seam: CGFloat = 0.58

    var body: some View {
        GeometryReader { geo in
            let size = Double(geo.size.width)
            ZStack {
                ForEach(Self.order(turn: turn), id: \.self) { wing in
                    Self.wing(wing, angle: wing.fore ? beat : hindBeat, pitch: pitch, turn: turn, size: size, color: color)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Wing names one of the four wings.
    struct Wing: Hashable {
        let left: Bool
        let fore: Bool
    }

    /// order is the four wings back to front: hindwings behind forewings,
    /// and turned side-on, the far side's pair behind the near side's
    /// (head right shows the right side, head left the left).
    static func order(turn: Double) -> [Wing] {
        let farLeft = turn >= 0
        return [Wing(left: farLeft, fore: false), Wing(left: farLeft, fore: true),
                Wing(left: !farLeft, fore: false), Wing(left: !farLeft, fore: true)]
    }

    /// wing is one wing of the mark, left or right of the centre line and
    /// above (`fore`) or below the seam, drawn at `angle`.
    static func wing(_ wing: Wing, angle: Double, pitch: Double, turn: Double, size: Double, color: Color) -> some View {
        Butterfly().fill(color)
            .mask { WingArea(left: wing.left, fore: wing.fore) }
            .brightness(0.12 * max(0, sin(angle * .pi / 180)) * (1 - abs(turn)))
            .projectionEffect(projection(WingProjection.of(angle: angle, left: wing.left, size: size,
                                                           turn: turn, pitch: pitch, hind: !wing.fore)))
    }

    /// projection is `w` as SwiftUI's transform.
    static func projection(_ w: WingProjection) -> ProjectionTransform {
        var t = ProjectionTransform()
        t.m11 = CGFloat(w.m11); t.m12 = CGFloat(w.m12); t.m13 = CGFloat(w.m13)
        t.m21 = CGFloat(w.m21); t.m22 = CGFloat(w.m22); t.m23 = CGFloat(w.m23)
        t.m31 = CGFloat(w.m31); t.m32 = CGFloat(w.m32); t.m33 = CGFloat(w.m33)
        return t
    }
}

/// WingArea is the part of the mark's square one wing occupies: its half
/// of the square and its side of the seam, overlapping the seam a little so
/// the forewing and hindwing meet without a hairline.
private struct WingArea: Shape {
    let left: Bool
    let fore: Bool

    func path(in rect: CGRect) -> Path {
        let overlap: CGFloat = 0.01
        let top = fore ? rect.minY : rect.minY + rect.height * (FieldButterfly.seam - overlap)
        let bottom = fore ? rect.minY + rect.height * (FieldButterfly.seam + overlap) : rect.maxY
        let x = left ? rect.minX : rect.midX
        return Path(CGRect(x: x, y: top, width: rect.width / 2, height: bottom - top))
    }
}
