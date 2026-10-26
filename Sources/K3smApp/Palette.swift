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

/// Palette is the console's colours: the tokens of the design it follows,
/// named for their role so a view never spells a colour itself. The navy
/// Mac panel keeps its own fixed colours. Everything else the console draws
/// follows the system appearance: the surface is the system window
/// background, and each text colour has a light and a dark value that
/// measures at least 4.5:1 (WCAG 2) on that surface and on the selected row.
enum Palette {
    static let deep = Color(red: 0.027, green: 0.051, blue: 0.239)      // #070d3d, the Mac panel
    static let deep2 = Color(red: 0.067, green: 0.102, blue: 0.361)     // #111a5c, meters' tracks
    static let deepRaised = Color(red: 0.051, green: 0.082, blue: 0.302) // #0d154d, the panel's tiles
    static let blue = Color(red: 0.008, green: 0.184, blue: 0.984)      // #022ffb, the accent

    /// The console's surface: the window, the strip, the list and the inspector.
    static let surface = Color(nsColor: .windowBackgroundColor)
    /// Rules between the console's columns and rows.
    static let line = Color(nsColor: .separatorColor)
    static let navy = adaptive(light: 0x011389, dark: 0x7d97ff)          // icons and native marks; 12.4:1 / 4.67:1 on tint
    /// The k3sm blue as an accent on the system surfaces: `blue` itself in
    /// light (7.49:1 on white, 6.34:1 on #ececec) and the navy's dark value
    /// in dark (6.15:1 on #1e1e1e, 4.73:1 on #323232), where #022ffb would
    /// measure 2.22:1. The popover's top bar and a version card's edge use it.
    static let accent = adaptive(light: 0x022ffb, dark: 0x7d97ff)
    static let tint = adaptive(light: 0xeaedff, dark: 0x24305e)          // the selected row
    static let wash = adaptive(light: 0xf6f7fb, dark: 0x2a2b31)          // text wells
    static let raised = adaptive(light: 0xffffff, dark: 0x3a3b42)        // the selected chip
    static let ink2 = adaptive(light: 0x565c73, dark: 0xb4b8c8)          // secondary text; 5.60:1 / 6.41:1 at worst
    /// Labels and dim text: 5.86:1 on white and 4.96:1 on #ececec in light,
    /// 6.34:1 on #1e1e1e and 4.87:1 on #323232 in dark, at least 4.81:1 on
    /// the selected row. It replaces the design's #8a8fa3, which is 3.21:1 on white.
    static let dimText = adaptive(light: 0x5f6478, dark: 0x9a9fb3)

    // The Stats tab's cards: light by day, the site's dark palette by night.
    // Text ratios are against the card (white / #101216) and the page
    // (#f7f7f8 / #0a0b0d), light / dark; marks (bars, lines, the empty
    // state's symbol) are graphics, held to 3:1 where they carry meaning.
    static let statsPage = adaptive(light: 0xf7f7f8, dark: 0x0a0b0d)       // the tab behind the cards
    static let statsCard = adaptive(light: 0xffffff, dark: 0x101216)       // a card
    static let statsLine = adaptive(light: 0xe4e6ea, dark: 0x23262c)       // a card's border and the axes' grid; 1.25:1 / 1.24:1, a hairline
    static let statsAccent = adaptive(light: 0x1633e0, dark: 0x7d97ff)     // the symbol beside the title; 8.13:1 on the card, 7.59:1 on the page / 6.91:1, 7.26:1
    static let statsNumber = adaptive(light: 0x011389, dark: 0xb9c5ff)     // the headline figure; 14.43:1, 13.47:1 / 11.15:1, 11.71:1
    static let statsMuted = adaptive(light: 0x6b7177, dark: 0x9aa1a9)      // units, captions, axis labels, a bar for a phase the lists do not name; 4.94:1, 4.61:1 / 7.18:1, 7.54:1
    static let statsBar = adaptive(light: 0x022ffb, dark: 0x6f88fe)        // a bar, the first series; 7.49:1, 7.0:1 / 5.92:1, 6.21:1
    static let statsBarSoft = adaptive(light: 0x5f7bff, dark: 0x3d5bff)    // the second bar (free space, Succeeded); 3.64:1, 3.4:1 / 3.69:1, 3.88:1
    static let statsOk = adaptive(light: 0x216e45, dark: 0x4cc287)         // Running, the second series; 6.21:1, 5.8:1 / 8.37:1, 8.79:1
    static let statsWarn = adaptive(light: 0x875810, dark: 0xe0a33e)       // Pending, restarts, the third series; 6.12:1, 5.71:1 / 8.46:1, 8.89:1
    static let statsEmpty = adaptive(light: 0xb9bec6, dark: 0x454a53)      // the empty state's large symbol, decorative beside its line; 1.87:1 / 2.1:1
    /// The usage lines and the update bands, one per node or state in
    /// turn: the cards' bar, green, amber, the VM orange (3.46:1 / 5.42:1),
    /// the headline navy and the `bad` red #c9302c (5.33:1 / 3.52:1).
    static let statsSeries: [Color] = [statsBar, statsOk, statsWarn, vm, statsNumber, bad]

    static let vm = Color(red: 0.780, green: 0.467, blue: 0.0)          // #c77700, the Linux VM mark
    static let fill = Color(red: 0.373, green: 0.482, blue: 1.0)        // #5f7bff, meters on the panel
    static let fillSoft = Color(red: 0.725, green: 0.773, blue: 1.0)    // #b9c5ff, efficiency cores
    static let fillDim = Color(red: 0.227, green: 0.263, blue: 0.502)   // #3a4380, the rest of memory
    static let okOnDark = Color(red: 0.384, green: 0.902, blue: 0.627)  // #62e6a0, a healthy daemon
    static let dockMark = Color(red: 0.561, green: 0.643, blue: 1.0)    // #8fa4ff, the mark on the Dock tile
    static let dockMarkGlow = Color(red: 0.435, green: 0.533, blue: 0.996) // #6f88fe, its glow (the mark's dark-mode upper wing)
    static let dockTileGlow = Color(red: 0.239, green: 0.357, blue: 1.0) // #3d5bff, the light behind it
    static let night = Color(red: 0.024, green: 0.039, blue: 0.18)      // #060a2e, the tour's dimming and card
    static let glow = Color(red: 0.49, green: 0.576, blue: 1.0)         // #7d93ff, the tour's light
    static let glowSoft = Color(red: 0.624, green: 0.69, blue: 1.0)     // #9fb0ff, the tour's eyebrow
    /// What pods request, as the light band behind a load bar's solid use:
    /// the tour's lighter shade, thinned so the meters' fill reads over it.
    /// The navy panel keeps its colours in both appearances, so one value
    /// serves light and dark.
    static let requestedBand = glowSoft.opacity(0.35)

    /// Unused: the Stats tab's series come from `statsSeries`.
    static let chartSeries: [Color] = [fill, okOnDark, vm, fillSoft, glowSoft, warnOnDark, dockMark]

    static let ok = Color(red: 0.090, green: 0.569, blue: 0.310)
    static let warn = Color(red: 0.722, green: 0.416, blue: 0.0)
    static let bad = Color(red: 0.788, green: 0.188, blue: 0.173)
    static let unknown = Color(red: 0.616, green: 0.631, blue: 0.702)
    /// The system orange: a node that is not ready, or a cluster that is not
    /// running, as a dot on the navy panel.
    static let warnOnDark = Color.orange
    /// The system red: a down daemon's dot in the status item's menu.
    static let down = Color(nsColor: .systemRed)
    /// The system red: an entry the first-run form refuses.
    static let errorText = Color.red

    /// A status row's glyph and text on the window's light side: green when
    /// healthy, grey when not checked, amber when it needs attention.
    static func row(_ tone: RowTone) -> Color {
        switch tone {
        case .healthy: return ok
        case .notChecked: return unknown
        case .attention: return warn
        }
    }

    /// A status row's glyph and text on the dark left panel.
    static func rowOnDark(_ tone: RowTone) -> Color {
        switch tone {
        case .healthy: return okOnDark
        case .notChecked: return .white.opacity(0.55)
        case .attention: return warnOnDark
        }
    }

    /// The dot for a pod's health severity word; an unknown word is grey.
    static func health(_ severity: String) -> Color {
        switch severity {
        case "ok": return ok
        case "warn": return warn
        case "bad": return bad
        default: return unknown
        }
    }

    /// A This Mac chart part's fill: use, or macOS and apps.
    static func swatch(_ kind: UsageSwatch) -> Color {
        switch kind {
        case .used: return fill
        case .system: return fillDim
        }
    }

    /// A load bar part's fill: the light band for a request, solid for use.
    static func loadPart(_ part: LoadPart) -> Color {
        switch part {
        case .requested: return requestedBand
        case .used: return fill
        }
    }

    /// A colour with one value in a light appearance and another in a dark
    /// one, the increased-contrast variants included.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb(dark) : srgb(light)
        })
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
