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

/// WaitingButterfly is the waiting mark: the butterfly at `size` points,
/// beating with `flap` (the continuous beat `WaitingModel` runs).
struct WaitingButterfly: View {
    @ObservedObject var flap: FlapModel
    let size: CGFloat

    /// The 14 pt mark centred in a tab's content during its first read.
    static let contentSize: CGFloat = 14
    /// The 10 pt mark landed on a tab's label during a later read.
    static let labelSize: CGFloat = 10

    var body: some View {
        FlappingButterfly(angle: flap.angle, color: Palette.navy)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Waiting.accessibilityLabel)
    }
}

/// TabWaitingMark draws `section`'s waiting butterfly where `WaitingModel`
/// puts it, when it is `placement`, and nothing otherwise. It takes no space
/// of its own: it rides an overlay, so it replaces nothing it covers.
struct TabWaitingMark: View {
    @ObservedObject var waiting: WaitingModel
    let section: ConsoleSection
    let placement: WaitingMark

    var body: some View {
        if waiting.marks[section] == placement {
            WaitingButterfly(
                flap: waiting.flap,
                size: placement == .content ? WaitingButterfly.contentSize : WaitingButterfly.labelSize)
            .allowsHitTesting(false)
        }
    }
}
