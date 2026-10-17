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

/// InstallPathView is the developer build's install watch on screen
/// (`InstallWatch`): a dotted winding path across the window and the
/// butterfly flying it from left to right, wings beating, turned along the
/// path; at the right end it lands side-on (`FoldedButterfly`) while the
/// health check runs, and flies again from the left when the check returns.
/// The timeline runs only while it flies; under Reduce Motion the still mark
/// stands at the right end.
struct InstallPathView: View {
    let watch: InstallWatch

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        GeometryReader { geo in
            TimelineView(.animation(paused: reduceMotion || watch.checking)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                let pose = InstallPath.pose(watch, at: now, width: Double(geo.size.width), reduceMotion: reduceMotion)
                InstallPathScene(width: geo.size.width, pose: pose, beat: InstallPath.beat(at: now))
            }
        }
        .frame(height: CGFloat(InstallPath.height))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Waiting.accessibilityLabel)
        .help(Help.FirstRun.installPath)
    }
}

/// InstallPathScene draws one frame of the path and the mark at `pose`.
struct InstallPathScene: View {
    let width: CGFloat
    let pose: InstallPathPose
    let beat: Double

    var body: some View {
        let size = CGFloat(InstallPath.markSize)
        ZStack(alignment: .topLeading) {
            InstallPathLine()
                .stroke(Palette.navy.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.5, 4]))
            Group {
                if pose.landed {
                    FoldedButterfly(scale: 1, color: Palette.navy)
                } else {
                    // The mark is drawn head up; turn it to face along the path.
                    FlappingButterfly(angle: beat, color: Palette.navy)
                        .rotationEffect(.degrees(90 + pose.heading))
                }
            }
            .frame(width: size, height: size)
            .position(x: CGFloat(pose.x), y: CGFloat(pose.y))
        }
        .frame(width: width, height: CGFloat(InstallPath.height), alignment: .topLeading)
    }
}

/// InstallPathLine is the path itself, `InstallPath.point` sampled across the width.
struct InstallPathLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 96
        for i in 0...steps {
            let point = InstallPath.point(Double(i) / Double(steps), width: Double(rect.width))
            let cg = CGPoint(x: rect.minX + CGFloat(point.x), y: rect.minY + CGFloat(point.y))
            if i == 0 { p.move(to: cg) } else { p.addLine(to: cg) }
        }
        return p
    }
}
