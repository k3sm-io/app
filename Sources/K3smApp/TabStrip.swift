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

/// TabStrip is the console's tabs, one per `ConsoleSection`, in the look of
/// the navy panel's own strip (`PanelTabStyle`) carried onto the light
/// surface: text, and a 2 pt underline on the strip's hairline under the
/// selected tab. It fills the strip's height so the underline sits on the
/// hairline the strip draws. A tab whose later read runs past
/// `Waiting.debounce` shows the 10 pt waiting butterfly just after its label,
/// in the gap to the next tab, so no label moves.
struct TabStrip: View {
    let selected: ConsoleSection
    let waiting: WaitingModel
    let choose: (ConsoleSection) -> Void

    var body: some View {
        HStack(spacing: 20) {
            ForEach(ConsoleSection.allCases) { s in
                Button(s.title) { choose(s) }
                    .buttonStyle(ConsoleTabStyle(selected: selected == s))
                    .accessibilityAddTraits(selected == s ? .isSelected : [])
                    .overlay(alignment: .trailing) {
                        TabWaitingMark(waiting: waiting, section: s, placement: .label).offset(x: 14)
                    }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// ConsoleTabStyle is one tab of the console's strip: primary text and a
/// 2 pt navy underline when selected, secondary text and no underline
/// otherwise; no fill, no outline. The colours follow the system appearance.
struct ConsoleTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Color.primary : Palette.ink2)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Palette.navy : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
