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

/// OverflowScroll is a pane whose content was laid out for a natural size
/// (`minWidth`, `minHeight`; 0 for an axis that never scrolls). On each
/// axis the content is drawn at the larger of that size and the room the
/// window gives the pane (`Overflow.extent`), so it fills a large pane and
/// is never squeezed in a small one, where the pane scrolls on that axis
/// instead. The scroll view is always there, so the content's own state
/// (a list's scroll position, a field's focus) survives a resize across
/// the natural size; while the content fits it does not scroll or bounce.
struct OverflowScroll<Content: View>: View {
    var minWidth: Double = 0
    var minHeight: Double = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(axes) {
                content()
                    .frame(width: CGFloat(Overflow.extent(room: Double(geo.size.width), natural: minWidth)),
                           height: CGFloat(Overflow.extent(room: Double(geo.size.height), natural: minHeight)))
            }
            .scrollBounceBehavior(.basedOnSize, axes: axes)
        }
    }

    /// The axes this pane may scroll on: those with a natural size.
    private var axes: Axis.Set {
        var axes: Axis.Set = []
        if minWidth > 0 { axes.insert(.horizontal) }
        if minHeight > 0 { axes.insert(.vertical) }
        return axes
    }
}
