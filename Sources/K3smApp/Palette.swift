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
    static let blue = Color(red: 0.008, green: 0.184, blue: 0.984)      // #022ffb, the accent

    /// The console's surface: the window, the strip, the list and the inspector.
    static let surface = Color(nsColor: .windowBackgroundColor)
    /// Rules between the console's columns and rows.
    static let line = Color(nsColor: .separatorColor)
    static let navy = adaptive(light: 0x011389, dark: 0x7d97ff)          // icons and native marks; 12.4:1 / 4.67:1 on tint
    static let tint = adaptive(light: 0xeaedff, dark: 0x24305e)          // the selected row
    static let wash = adaptive(light: 0xf6f7fb, dark: 0x2a2b31)          // text wells
    static let raised = adaptive(light: 0xffffff, dark: 0x3a3b42)        // the selected chip
    static let ink2 = adaptive(light: 0x565c73, dark: 0xb4b8c8)          // secondary text; 5.60:1 / 6.41:1 at worst
    /// Labels and dim text: 5.86:1 on white and 4.96:1 on #ececec in light,
    /// 6.34:1 on #1e1e1e and 4.87:1 on #323232 in dark, at least 4.81:1 on
    /// the selected row. It replaces the design's #8a8fa3, which is 3.21:1 on white.
    static let dimText = adaptive(light: 0x5f6478, dark: 0x9a9fb3)

    static let vm = Color(red: 0.780, green: 0.467, blue: 0.0)          // #c77700, the Linux VM mark
    static let fill = Color(red: 0.373, green: 0.482, blue: 1.0)        // #5f7bff, meters on the panel
    static let fillSoft = Color(red: 0.725, green: 0.773, blue: 1.0)    // #b9c5ff, efficiency cores
    static let fillDim = Color(red: 0.227, green: 0.263, blue: 0.502)   // #3a4380, the rest of memory
    static let okOnDark = Color(red: 0.384, green: 0.902, blue: 0.627)  // #62e6a0, a healthy daemon

    static let ok = Color(red: 0.090, green: 0.569, blue: 0.310)
    static let warn = Color(red: 0.722, green: 0.416, blue: 0.0)
    static let bad = Color(red: 0.788, green: 0.188, blue: 0.173)
    static let unknown = Color(red: 0.616, green: 0.631, blue: 0.702)

    /// The dot for a pod's health severity word; an unknown word is grey.
    static func health(_ severity: String) -> Color {
        switch severity {
        case "ok": return ok
        case "warn": return warn
        case "bad": return bad
        default: return unknown
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
