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
/// of its own: it rides an overlay, so it replaces nothing it covers. The
/// content mark beats with the model's flap; the label mark flies its
/// `LabelFlight` (`PerchingButterfly`).
struct TabWaitingMark: View {
    @ObservedObject var waiting: WaitingModel
    let section: ConsoleSection
    let placement: WaitingMark

    var body: some View {
        if waiting.marks[section] == placement {
            if placement == .label {
                PerchingButterfly(flight: waiting.flights[section], size: WaitingButterfly.labelSize)
                    .allowsHitTesting(false)
            } else {
                WaitingButterfly(flap: waiting.flap, size: WaitingButterfly.contentSize)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// PerchingButterfly is the label mark in flight: on a display-rate timeline,
/// only while it is shown, it samples `flight`'s pose (`LabelFlight.pose`) on
/// the monotonic clock and draws the mark at that offset from its perch,
/// tilted, its wing pair scaled narrow as they fold and hinged by the beat,
/// at that opacity; as the landing begins it turns (a cross-fade with a turn
/// about its vertical axis, by `sideOn`) to the side view, `FoldedButterfly`
/// (the mark turned, its wings mirrored together and narrowed to
/// `sideScale`), parting and closing them in profile down to the perch, and turns
/// back at take-off. With no flight, or under Reduce Motion, the timeline is
/// paused and the pose is the still perched mark.
struct PerchingButterfly: View {
    let flight: LabelFlight?
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(paused: flight?.reduceMotion ?? true)) { _ in
            let pose = flight?.pose(at: ProcessInfo.processInfo.systemUptime) ?? Perch.still
            ZStack {
                FlappingButterfly(angle: pose.beat, color: Palette.navy)
                    .scaleEffect(x: CGFloat(pose.wingScale), y: 1, anchor: .center)
                    .rotation3DEffect(.degrees(90 * pose.sideOn), axis: (x: 0, y: 1, z: 0))
                    .opacity(1 - pose.sideOn)
                FoldedButterfly(scale: pose.sideScale, color: Palette.navy)
                    .rotation3DEffect(.degrees(-90 * (1 - pose.sideOn)), axis: (x: 0, y: 1, z: 0))
                    .opacity(pose.sideOn)
            }
            .frame(width: size, height: size)
                .rotationEffect(.degrees(pose.rotation), anchor: .center)
                .offset(x: CGFloat(pose.dx), y: CGFloat(pose.dy))
                .opacity(pose.opacity)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Waiting.accessibilityLabel)
    }
}
