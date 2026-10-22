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

/// FieldButterfly is the Alerts field's butterfly in flight, made only from
/// the mark itself: the mark cut into four wings, the forewings above the
/// waist (`seam`) and the hindwings below it on each side of the centre
/// line, each drawn through `WingProjection` at its hinge angle, so the
/// wings rise over the back and fall below the body as seen from above and
/// a little behind. The hindwings take `hindBeat`, which trails `beat`. A
/// raised wing is drawn a shade lighter, as a wing turned toward the light
/// is, so the stroke reads in depth. The whole mark then pitches about its
/// horizontal centre line by `pitch`. At a 0 beat and pitch it draws
/// exactly the flat mark.
struct FieldButterfly: View {
    let beat: Double
    let hindBeat: Double
    let pitch: Double
    let color: Color

    /// Where the mark's forewings meet its hindwings, as a fraction of its
    /// height from the top: the waist, where both wing outlines come in to
    /// the body.
    static let seam: CGFloat = 0.58

    var body: some View {
        GeometryReader { geo in
            let size = Double(geo.size.width)
            ZStack {
                Self.wing(left: true, fore: false, angle: hindBeat, size: size, color: color)
                Self.wing(left: false, fore: false, angle: hindBeat, size: size, color: color)
                Self.wing(left: true, fore: true, angle: beat, size: size, color: color)
                Self.wing(left: false, fore: true, angle: beat, size: size, color: color)
            }
        }
        .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.4)
        .accessibilityHidden(true)
    }

    /// wing is one wing of the mark, left or right of the centre line and
    /// above (`fore`) or below the seam, drawn at `angle`.
    static func wing(left: Bool, fore: Bool, angle: Double, size: Double, color: Color) -> some View {
        Butterfly().fill(color)
            .mask { WingArea(left: left, fore: fore) }
            .brightness(0.12 * max(0, sin(angle * .pi / 180)))
            .projectionEffect(projection(WingProjection.of(angle: angle, left: left, size: size)))
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
