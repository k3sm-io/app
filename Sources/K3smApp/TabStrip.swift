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

/// TabStrip is the console's tabs, one per `ConsoleSection`, in the look of
/// the navy panel's own strip (`PanelTabStyle`) carried onto the light
/// surface: text, and a 2 pt underline on the strip's hairline under the
/// selected tab. It fills the strip's height so the underline sits on the
/// hairline the strip draws. A tab whose later read runs past
/// `Waiting.debounce` shows the 10 pt waiting butterfly landed at its word's
/// upper-left corner: its feet on the first letter's cap top, its left edge on
/// the label's leading edge (`TabStripLayout.waitingMarkFrame`), in the room
/// the strip's fixed height (`TabStripLayout.height`) leaves above the labels,
/// so no label moves and the strip never grows. Each label is one line at
/// its own width, never wrapped; only one past `TabStripLayout.labelCap`
/// characters is shortened, at its tail. The window's minimum width keeps
/// room for every label (`TabStripLayout.minimumWidth`).
struct TabStrip: View {
    let selected: ConsoleSection
    let waiting: WaitingModel
    let choose: (ConsoleSection) -> Void

    var body: some View {
        HStack(spacing: CGFloat(TabStripLayout.tabSpacing)) {
            ForEach(ConsoleSection.allCases) { s in
                Button { choose(s) } label: {
                    Text(TabStripLayout.display(s.title))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: true, vertical: false)
                }
                    .buttonStyle(ConsoleTabStyle(selected: selected == s))
                    .accessibilityLabel(s.title)
                    .help(Help.Strip.tab(s))
                    .accessibilityAddTraits(selected == s ? .isSelected : [])
                    .overlay(alignment: .topLeading) {
                        TabWaitingMark(waiting: waiting, section: s, placement: .label)
                            .offset(x: CGFloat(Self.markFrame.minX), y: CGFloat(Self.markFrame.minY))
                    }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Where a tab's waiting butterfly lands, from the labels' font metrics.
    private static let markFrame: MarkFrame = {
        let font = NSFont.systemFont(ofSize: CGFloat(TabStripLayout.fontSize), weight: .medium)
        return TabStripLayout.waitingMarkFrame(ascent: Double(font.ascender), descent: Double(-font.descender),
                                               capHeight: Double(font.capHeight),
                                               markSize: Double(WaitingButterfly.labelSize))
    }()
}

/// ConsoleTabStyle is one tab of the console's strip: primary text and a
/// 2 pt navy underline when selected, secondary text and no underline
/// otherwise; no fill, no outline. The colours follow the system appearance.
struct ConsoleTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: CGFloat(TabStripLayout.fontSize), weight: .medium))
            .foregroundStyle(selected ? Color.primary : Palette.ink2)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Palette.navy : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
