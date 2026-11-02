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
import Testing

@testable import K3smApp

/// The accent the catalog gives the app (hack/make-accent.sh's pair, which
/// AccentCatalogTests ties to Resources/Assets.car and Palette.controlAccent)
/// fills the default button and the selected row. Under each appearance the
/// filled shape must stand 3:1 against the surfaces around it (WCAG 2.2 SC
/// 1.4.11) and its label 4.5:1 against the fill (SC 1.4.3). The label and
/// surface colours are the ones AppKit resolves for that appearance, so a
/// system change to them is measured too.
@Test func darkAccentMeetsComponentContrast() throws {
    let pair = try AccentCatalog.scriptPair()
    var failures: [String] = []
    for (name, appearance, accent) in [("aqua", NSAppearance.Name.aqua, pair.light), ("darkAqua", .darkAqua, pair.dark)] {
        let fill = AccentContrast.rgb(accent)
        let resolved = try #require(AccentContrast.resolve(appearance))
        for (role, label) in resolved.labels {
            let ratio = AccentContrast.ratio(fill, label)
            if ratio < 4.5 { failures.append("\(name): \(role) on \(AccentContrast.css(accent)) is \(AccentContrast.fmt(ratio)):1, under 4.5:1") }
        }
        for (role, surface) in resolved.surfaces {
            let ratio = AccentContrast.ratio(fill, surface)
            if ratio < 3 { failures.append("\(name): \(AccentContrast.css(accent)) against \(role) is \(AccentContrast.fmt(ratio)):1, under 3:1") }
        }
    }
    #expect(failures == [])
}

/// The measure is not vacuous: the old dark accent #7d97ff fails its label
/// and the navy #011389 fails the dark surfaces.
@Test func accentContrastCatchesWeakPairs() throws {
    let dark = try #require(AccentContrast.resolve(.darkAqua))
    let white = try #require(dark.labels.first { $0.role.hasPrefix("default button") }).color
    #expect(AccentContrast.ratio(AccentContrast.rgb(0x7d97ff), white) < 4.5)
    let window = try #require(dark.surfaces.first { $0.role == "window background" }).color
    #expect(AccentContrast.ratio(AccentContrast.rgb(0x011389), window) < 3)
}

/// AccentContrast resolves AppKit's colours under an appearance and measures
/// WCAG 2 contrast between opaque sRGB colours.
enum AccentContrast {
    struct RGB { var r: Double; var g: Double; var b: Double }
    struct Resolved {
        /// The text drawn on the accent: a default button's title and a
        /// selected (emphasized) table row's text.
        var labels: [(role: String, color: RGB)]
        /// What the filled shape sits on: the window, a table's background
        /// and its alternate row.
        var surfaces: [(role: String, color: RGB)]
    }

    static func rgb(_ hex: UInt32) -> RGB {
        RGB(r: Double((hex >> 16) & 0xff) / 255, g: Double((hex >> 8) & 0xff) / 255, b: Double(hex & 0xff) / 255)
    }

    static func resolve(_ name: NSAppearance.Name) -> Resolved? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: Resolved?
        appearance.performAsCurrentDrawingAppearance {
            guard let table = srgba(.controlBackgroundColor),
                  let window = srgba(.windowBackgroundColor),
                  let alternate = srgba(NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor),
                  let label = srgba(.alternateSelectedControlTextColor) else { return }
            // A translucent colour is drawn over what is behind it: the
            // label over the accent is measured as given (AppKit's is
            // opaque white), the alternate row over the table background.
            let fillLabel = flatten(label, over: RGB(r: 0, g: 0, b: 0))
            out = Resolved(
                labels: [("default button title", fillLabel), ("selected row text", fillLabel)],
                surfaces: [
                    ("window background", flatten(window, over: RGB(r: 0, g: 0, b: 0))),
                    ("table background", flatten(table, over: RGB(r: 0, g: 0, b: 0))),
                    ("alternate table row", flatten(alternate, over: flatten(table, over: RGB(r: 0, g: 0, b: 0)))),
                ])
        }
        return out
    }

    private static func srgba(_ color: NSColor) -> (RGB, Double)? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), c.alphaComponent)
    }

    private static func flatten(_ c: (RGB, Double), over back: RGB) -> RGB {
        let (f, a) = c
        return RGB(r: f.r * a + back.r * (1 - a), g: f.g * a + back.g * (1 - a), b: f.b * a + back.b * (1 - a))
    }

    /// luminance is WCAG 2's relative luminance of an sRGB colour.
    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    static func css(_ hex: UInt32) -> String { String(format: "#%06x", hex) }
}
