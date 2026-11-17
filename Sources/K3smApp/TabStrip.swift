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

/// StripControl names a control of the console's strip that shows a hover
/// highlight: a tab, or one of the glyph buttons.
enum StripControl: Hashable {
    case tab(ConsoleSection)
    case panel, details, tour, info, settings
}

/// StripHover is which strip control the pointer is over, if any. It lives
/// on `AppModel` (views keep no `@State`), apart from its published state,
/// so a hover redraws the strip's controls and nothing else.
@MainActor
final class StripHover: ObservableObject {
    @Published var hovered: StripControl?

    /// Records the pointer entering (`inside`) or leaving `control`; leaving
    /// one the pointer has already moved past changes nothing.
    func set(_ control: StripControl, inside: Bool) {
        if inside {
            if hovered != control { hovered = control }
        } else if hovered == control {
            hovered = nil
        }
    }
}

/// TabStrip is the console's tabs, one per `ConsoleSection`, drawn as
/// Safari's compact tabs: a capsule per tab in the strip's row
/// (`ConsoleTabStyle`), the selected one raised and filled with the k3sm
/// accent, the others flat with a faint fill under the pointer. The tabs share
/// the room the row gives them evenly, each from its least width
/// (`TabStripLayout.tabWidth`, its label whole) up to
/// `TabStripLayout.tabMaximumWidth`; a row narrower than every tab's least
/// scrolls (`ConsoleStrip`). The sections are fixed, so a tab has no close
/// button and the strip no new-tab button. Each tab fills the strip's
/// height, its label centred in that height, which is the box
/// `TabStripLayout.waitingMarkFrame` measures from. The tab on screen shows
/// the 10 pt waiting butterfly for each of its later reads, at once: it lands
/// (`Perch`), perches at least `Waiting.labelMinimumShown` and takes off
/// when the read is done. Its perch is at its word's upper-left corner: its
/// feet on the first letter's cap top, its left edge on the label's leading
/// edge (`TabStripLayout.waitingMarkFrame`), in the room the strip's fixed
/// height (`TabStripLayout.height`) leaves above the labels, so no label moves
/// and the strip never grows. Each label is one line at its own width, never
/// wrapped; only one past `TabStripLayout.labelCap` characters is shortened,
/// at its tail. Command-1 to Command-9 and Control-Tab pick a tab from the
/// View menu (`MainMenu`).
struct TabStrip: View {
    let selected: ConsoleSection
    let waiting: WaitingModel
    @ObservedObject var hover: StripHover
    let choose: (ConsoleSection) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: CGFloat(TabStripLayout.tabGap)) {
            ForEach(ConsoleSection.allCases) { s in
                Button { choose(s) } label: {
                    Text(TabStripLayout.display(s.title))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            TabWaitingMark(waiting: waiting, section: s, placement: .label)
                                .offset(x: CGFloat(Self.markFrame.minX), y: CGFloat(Self.markFrame.minY))
                        }
                }
                    .buttonStyle(ConsoleTabStyle(selected: selected == s, hovered: hover.hovered == .tab(s),
                                                 increasedContrast: contrast == .increased,
                                                 minWidth: TabStripLayout.tabWidth(s.title)))
                    .onHover { hover.set(.tab(s), inside: $0) }
                    .accessibilityLabel(s.title)
                    .help(Help.Strip.tab(s))
                    .accessibilityAddTraits(selected == s ? .isSelected : [])
                    .id(s)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hover.hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// Where a tab's waiting butterfly lands, from the labels' font metrics.
    private static let markFrame: MarkFrame = {
        let font = NSFont.systemFont(ofSize: CGFloat(TabStripLayout.fontSize), weight: .medium)
        return TabStripLayout.waitingMarkFrame(ascent: Double(font.ascender), descent: Double(-font.descender),
                                               capHeight: Double(font.capHeight),
                                               markSize: Double(WaitingButterfly.labelSize))
    }()
}

/// ConsoleTabStyle is one tab of the console's strip, after Safari's compact
/// tabs: a `TabStripLayout.tabHeight` capsule centred in the strip's height,
/// at least `minWidth` wide and growing to `TabStripLayout.tabMaximumWidth`,
/// its label centred. Selected, the capsule is raised (a soft shadow) and
/// filled with the accent's tint (`Palette.tint`), outlined in the accent and
/// labelled in `Palette.navy`, so the selection keeps k3sm's hue rather than
/// the system blue; otherwise it is flat, labelled in `Palette.ink2`, with a
/// faint fill only under the pointer or while pressed. With Increase
/// Contrast on, the outline is the full accent, a flat tab's label is the
/// primary colour and the hover fill is stronger. The colours follow the
/// system appearance.
struct ConsoleTabStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    var increasedContrast = false
    var minWidth: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        let capsule = Capsule(style: .continuous)
        let flatFill = Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered ? (increasedContrast ? 0.14 : 0.07) : 0))
        return configuration.label
            .font(.system(size: CGFloat(TabStripLayout.fontSize), weight: .medium))
            .foregroundStyle(selected ? Palette.navy : (increasedContrast ? Color.primary : Palette.ink2))
            .padding(.horizontal, CGFloat(TabStripLayout.tabPadding))
            .frame(minWidth: CGFloat(minWidth), maxWidth: CGFloat(TabStripLayout.tabMaximumWidth), maxHeight: .infinity)
            .background {
                ZStack {
                    if selected {
                        capsule.fill(Palette.tint)
                            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                        capsule.strokeBorder(Palette.accent.opacity(increasedContrast ? 1 : 0.35),
                                             lineWidth: increasedContrast ? 1.5 : 1)
                    } else {
                        capsule.fill(flatFill)
                        if increasedContrast {
                            capsule.strokeBorder(Palette.line, lineWidth: 1)
                        }
                    }
                }
                .frame(height: CGFloat(TabStripLayout.tabHeight))
            }
            .contentShape(Rectangle())
    }
}

/// StripGlyphButton is one of the strip's glyph buttons, Safari's toolbar
/// style: a borderless `TabStripLayout.iconSymbolSize` symbol in the navy
/// accent, in a `TabStripLayout.iconButtonWidth` square, with a circle of
/// faint fill under the pointer and a stronger one while pressed. It sits in
/// a `StripButtonGroup` capsule with its neighbours.
struct StripGlyphButton: View {
    let control: StripControl
    let symbol: String
    let label: String
    let help: HelpTag
    @ObservedObject var hover: StripHover
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CGFloat(TabStripLayout.iconSymbolSize)))
                .foregroundStyle(Palette.navy)
        }
        .buttonStyle(StripGlyphStyle(hovered: hover.hovered == control))
        .onHover { hover.set(control, inside: $0) }
        .accessibilityLabel(label)
        .help(help)
    }
}

/// StripGlyphStyle draws a `StripGlyphButton`: the symbol centred in its
/// square, a circle of `Color.primary` at low opacity under the pointer and
/// stronger while pressed; nothing otherwise.
struct StripGlyphStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let side = CGFloat(TabStripLayout.iconButtonWidth)
        return configuration.label
            .frame(width: side, height: side)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovered ? 0.07 : 0))))
            .contentShape(Circle())
    }
}

/// StripButtonGroup is a row of glyph buttons in one capsule, as Safari
/// groups its toolbar buttons: on macOS 26 the capsule is Liquid Glass
/// (`glassEffect`), which the system draws as an opaque fill when Reduce
/// Transparency is on; with Increase Contrast it also takes a hairline.
struct StripButtonGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(CGFloat(TabStripLayout.groupInset))
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .overlay {
                if contrast == .increased {
                    Capsule(style: .continuous).strokeBorder(Palette.line, lineWidth: 1)
                }
            }
    }
}
