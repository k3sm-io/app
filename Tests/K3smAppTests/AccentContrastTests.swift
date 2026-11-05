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
/// AccentCatalogTests.paletteControlAccentMatchesTheScript ties to
/// Resources/Assets.car and Palette.controlAccent) fills the default button
/// and the selected row. Under each appearance the filled shape must stand
/// 3:1 against the surfaces around it (WCAG 2.2 SC 1.4.11) and its label
/// 4.5:1 against the fill (SC 1.4.3). The label and surface colours come from
/// the committed golden, Tests/Fixtures/accent/surfaces.json, keyed by macOS
/// major; the canary below compares it to live AppKit.
///
/// A non-emphasized selected row (an unfocused table) is not in the role
/// list on purpose: it is drawn on unemphasizedSelectedContentBackgroundColor,
/// a grey, not on the accent, so no accent fill is measured against it.
@Test func accentContrastMeasuresEveryRole() throws {
    let pair = try AccentCatalog.scriptPair()
    let data = try AccentContrast.fixtureData()
    var failures: [String] = []
    for (name, accent) in [("aqua", pair.light), ("darkAqua", pair.dark)] {
        let fill = AccentContrast.rgb(accent)
        let resolved = try AccentContrast.load(data, appearance: name, osMajor: AccentContrast.recordedMajor)
        for (role, label) in resolved.labels {
            #expect(label.a == 1, "\(name): \(role) is not opaque")
            #expect(AccentContrast.ratio(label.rgb, AccentContrast.rgb(0xffffff)) == 1, "\(name): \(role) is not white")
            let ratio = AccentContrast.ratio(fill, label.rgb)
            if ratio < 4.5 { failures.append("\(name): \(role) on \(AccentContrast.css(accent)) is \(AccentContrast.fmt(ratio)):1, under 4.5:1") }
        }
        for (role, surface) in resolved.surfaces {
            let ratio = AccentContrast.ratio(fill, surface)
            if ratio < 3 { failures.append("\(name): \(AccentContrast.css(accent)) against \(role) is \(AccentContrast.fmt(ratio)):1, under 3:1") }
        }
    }
    #expect(failures == [])
}

/// The loader is the guard: bad fixtures go through the real loader and each
/// fails with its own message.
@Test(arguments: [
    ("missing surface", "surfaces", "window background", nil as String?, "missing surface window background"),
    ("duplicate surface", "surfaces", "table background", "dup", "duplicate surface table background"),
    ("missing label", "labels", "selected row text", nil as String?, "missing label selected row text"),
    ("zeroed surface", "surfaces", "window background", "[0,0,0,0]", "degenerate surface window background"),
    ("out of range", "surfaces", "window background", "[2,1,1,1]", "degenerate surface window background"),
    ("short components", "surfaces", "window background", "[1,1,1]", "degenerate surface window background"),
    ("label equals a surface", "labels", "selected row text", "[0.117647,0.117647,0.117647,1]", "label selected row text equals a surface"),
    ("alternate row equals table", "surfaces", "alternate table row", "[0.117647,0.117647,0.117647,1]", "alternate table row equals table background"),
    ("translucent label", "labels", "default button title", "[1,1,1,0.5]", "degenerate label default button title"),
])
func accentFixtureLoaderRejectsBadEntries(_ c: (name: String, list: String, role: String, replace: String?, want: String)) throws {
    var top = try #require(JSONSerialization.jsonObject(with: AccentContrast.fixtureData()) as? [String: Any])
    var os = try #require(top["os"] as? [String: Any])
    var dark = try #require((os["27"] as? [String: Any])?["darkAqua"] as? [String: Any])
    var entries = try #require(dark[c.list] as? [[String: Any]])
    let at = try #require(entries.firstIndex { $0["role"] as? String == c.role })
    switch c.replace {
    case nil: entries.remove(at: at)
    case "dup": entries.append(entries[at])
    case let json?: entries[at]["rgba"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }
    dark[c.list] = entries
    os["27"] = ["darkAqua": dark, "aqua": try #require((os["27"] as? [String: Any])?["aqua"])]
    top["os"] = os
    let bad = try JSONSerialization.data(withJSONObject: top)
    do {
        _ = try AccentContrast.load(bad, appearance: "darkAqua", osMajor: 27)
        Issue.record("\(c.name): the loader accepted it")
    } catch let e as AccentContrast.FixtureError {
        #expect(e.description == c.want, "\(c.name)")
    }
}

@Test func accentFixtureLoaderRejectsUnknownSectionAndRole() throws {
    let data = try AccentContrast.fixtureData()
    #expect(throws: AccentContrast.FixtureError.self) { try AccentContrast.load(data, appearance: "darkAqua", osMajor: 99) }
    #expect(throws: AccentContrast.FixtureError.self) { try AccentContrast.load(data, appearance: "sepia", osMajor: 27) }
    #expect(AccentContrast.hasSection(data, osMajor: 27))
    #expect(!AccentContrast.hasSection(data, osMajor: 26))
}

/// The golden is a recording of AppKit's colours for one macOS major. When
/// the host runs a major with no recording, this records a visible skip
/// naming it. When there is one and the live colours differ (an OS release
/// or an accessibility setting) it names the drift. The ratio test never
/// reads the live colours. A default button's title has no live colour, so
/// only the selected row text and the surfaces are compared.
@Test func accentSurfacesCanaryNamesOSDrift() throws {
    let data = try AccentContrast.fixtureData()
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard AccentContrast.hasSection(data, osMajor: major) else {
        print("SKIP accentSurfacesCanaryNamesOSDrift: no golden recorded for macOS \(major) in Tests/Fixtures/accent/surfaces.json")
        withKnownIssue("no golden recorded for macOS \(major)") { Issue.record("no golden recorded for macOS \(major)") }
        return
    }
    var drift: [String] = []
    for name in ["aqua", "darkAqua"] {
        let live = try #require(AccentContrast.resolve(name == "aqua" ? .aqua : .darkAqua))
        let golden = try AccentContrast.load(data, appearance: name, osMajor: major)
        let pairs = zip(golden.labels.filter { live.labels.map(\.role).contains($0.role) } + golden.surfaces.map { ($0.role, AccentContrast.RGBA(rgb: $0.color, a: 1)) },
                        live.labels + live.surfaces.map { ($0.role, AccentContrast.RGBA(rgb: $0.color, a: 1)) })
        for (g, l) in pairs where abs(AccentContrast.luminance(g.1.rgb) - AccentContrast.luminance(l.1.rgb)) > 0.002 {
            drift.append("\(name): \(g.0) golden \(AccentContrast.fmt(AccentContrast.luminance(g.1.rgb))) live \(AccentContrast.fmt(AccentContrast.luminance(l.1.rgb)))")
        }
    }
    #expect(drift == [], "AppKit colours moved on macOS \(major); re-record Tests/Fixtures/accent/surfaces.json")
}

/// The bundle names the catalog's accent: Info.plist NSAccentColorName is AccentColor.
@Test func infoPlistNamesTheAccentColour() throws {
    let plist = AccentCatalog.root.appendingPathComponent("Resources/Info.plist")
    let dict = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
    #expect(dict["NSAccentColorName"] as? String == "AccentColor")
}

/// Filled controls take the catalog accent. Per file, the number of
/// .borderedProminent buttons must not exceed the number of
/// .tint(Palette.controlAccent) calls (SettingsWindowController tints its
/// whole container once, and draws none itself). Any other .tint( is a
/// problem, except Palette.navy on the line right after the popover's
/// "all checks" DisclosureGroup label, which draws a disclosure arrow, not a
/// filled shape.
@Test func tintSitesUseTheCatalogAccent() throws {
    let dir = AccentCatalog.root.appendingPathComponent("Sources/K3smApp")
    var problems: [String] = []
    for file in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".swift") {
        let lines = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n")
        let code = lines.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let accent = code.filter { $0.element.contains(".tint(Palette.controlAccent)") }.count
        let prominent = code.filter { $0.element.contains(".borderedProminent") }.count
        if prominent > accent { problems.append("\(file): \(prominent) borderedProminent, \(accent) controlAccent tints") }
        for (i, line) in code where line.contains(".tint(") && !line.contains(".tint(Palette.controlAccent)") {
            let closesDisclosure = lines[max(0, i - 3)..<i].contains { $0.contains("} label: {") } || lines[max(0, i - 3)...i].contains { $0.trimmingCharacters(in: .whitespaces) == "}" }
            let isDisclosure = file == "Views.swift" && line.contains(".tint(Palette.navy)") && closesDisclosure
                && lines[..<i].suffix(40).contains { $0.contains("DisclosureGroup") }
            if !isDisclosure { problems.append("\(file):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))") }
        }
    }
    #expect(problems == [])
}

/// The measure is not vacuous: the old dark accent #7d97ff fails its label
/// and the navy #011389 fails the dark surfaces.
@Test func accentContrastCatchesWeakPairs() throws {
    let dark = try AccentContrast.load(AccentContrast.fixtureData(), appearance: "darkAqua", osMajor: AccentContrast.recordedMajor)
    let white = try #require(dark.labels.first { $0.role.hasPrefix("default button") }).color.rgb
    #expect(AccentContrast.ratio(AccentContrast.rgb(0x7d97ff), white) < 4.5)
    let window = try #require(dark.surfaces.first { $0.role == "window background" }).color
    #expect(AccentContrast.ratio(AccentContrast.rgb(0x011389), window) < 3)
}

/// AccentContrast loads and resolves the colours the accent is measured
/// against, and measures WCAG 2 contrast between opaque sRGB colours.
enum AccentContrast {
    struct RGB: Equatable { var r: Double; var g: Double; var b: Double }
    struct RGBA { var rgb: RGB; var a: Double }
    struct Resolved {
        /// The text drawn on the accent, one entry per role.
        var labels: [(role: String, color: RGBA)]
        /// What the filled shape sits on, flattened to opaque.
        var surfaces: [(role: String, color: RGB)]
    }
    struct FixtureError: Error, CustomStringConvertible { var description: String }

    /// The roles the fixture must carry. They are the contract, written
    /// here, never produced from the fixture or the loader.
    static let labelRoles: Set<String> = ["default button title", "selected row text"]
    static let surfaceRoles: Set<String> = ["window background", "table background", "alternate table row"]
    static let recordedMajor = 27

    static func fixtureData() throws -> Data {
        try Data(contentsOf: AccentCatalog.fixture("surfaces.json"))
    }

    static func hasSection(_ data: Data, osMajor: Int) -> Bool {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let os = top["os"] as? [String: Any] else { return false }
        return os[String(osMajor)] != nil
    }

    /// load validates and reads one appearance of one OS major's section:
    /// every role present once, no unknown role, every colour four
    /// components in 0...1, surfaces not transparent or all-zero, labels
    /// opaque, no non-white label equal to a surface (white on the light window is the real answer), the alternate row distinct from
    /// the table.
    static func load(_ data: Data, appearance: String, osMajor: Int) throws -> Resolved {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any], let os = top["os"] as? [String: Any],
              let section = os[String(osMajor)] as? [String: Any] else { throw FixtureError(description: "no section for macOS \(osMajor)") }
        guard let one = section[appearance] as? [String: Any] else { throw FixtureError(description: "no \(appearance) in macOS \(osMajor)") }
        func entries(_ list: String, _ roles: Set<String>, _ kind: String) throws -> [String: RGBA] {
            guard let raw = one[list] as? [[String: Any]] else { throw FixtureError(description: "no \(list)") }
            var out: [String: RGBA] = [:]
            for entry in raw {
                guard let role = entry["role"] as? String, roles.contains(role) else { throw FixtureError(description: "unknown \(kind) \(entry["role"] ?? "?")") }
                if out[role] != nil { throw FixtureError(description: "duplicate \(kind) \(role)") }
                guard let v = entry["rgba"] as? [Double], v.count == 4, v.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                    throw FixtureError(description: "degenerate \(kind) \(role)")
                }
                let c = RGBA(rgb: RGB(r: v[0], g: v[1], b: v[2]), a: v[3])
                let zeroed = c.a == 0 || (c.rgb == RGB(r: 0, g: 0, b: 0) && kind == "surface")
                if zeroed || (kind == "label" && c.a != 1) { throw FixtureError(description: "degenerate \(kind) \(role)") }
                out[role] = c
            }
            for role in roles.sorted() where out[role] == nil { throw FixtureError(description: "missing \(kind) \(role)") }
            return out
        }
        let labels = try entries("labels", labelRoles, "label")
        let raw = try entries("surfaces", surfaceRoles, "surface")
        let flat = flattenSurfaces(raw)
        for (role, c) in labels where c.rgb != RGB(r: 1, g: 1, b: 1) && flat.contains(where: { $0.color == c.rgb }) { throw FixtureError(description: "label \(role) equals a surface") }
        if flat[2].color == flat[1].color { throw FixtureError(description: "alternate table row equals table background") }
        return Resolved(labels: labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, surfaces: flat)
    }

    private static func flattenSurfaces(_ raw: [String: RGBA]) -> [(role: String, color: RGB)] {
        let black = RGB(r: 0, g: 0, b: 0)
        let table = flatten(raw["table background"]!, over: black)
        return [("window background", flatten(raw["window background"]!, over: black)),
                ("table background", table),
                ("alternate table row", flatten(raw["alternate table row"]!, over: table))]
    }

    static func rgb(_ hex: UInt32) -> RGB {
        RGB(r: Double((hex >> 16) & 0xff) / 255, g: Double((hex >> 8) & 0xff) / 255, b: Double(hex & 0xff) / 255)
    }

    /// resolve reads AppKit's live colours under a named appearance. Only the
    /// plain aqua and darkAqua are resolved: under the accessibility
    /// (increased-contrast) names this process answers with the plain
    /// appearance (its `name` reads Aqua and every dynamic colour probed was
    /// identical), so such a resolution would measure nothing. The default
    /// button's title has no AppKit colour, so it is not returned here.
    static func resolve(_ name: NSAppearance.Name) -> Resolved? {
        guard name == .aqua || name == .darkAqua, let appearance = NSAppearance(named: name) else { return nil }
        var out: Resolved?
        appearance.performAsCurrentDrawingAppearance {
            guard let table = srgba(.controlBackgroundColor), let window = srgba(.windowBackgroundColor),
                  let alternate = srgba(NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor),
                  let label = srgba(.alternateSelectedControlTextColor) else { return }
            out = Resolved(labels: [("selected row text", label)],
                           surfaces: flattenSurfaces(["window background": window, "table background": table, "alternate table row": alternate]))
        }
        return out
    }

    private static func srgba(_ color: NSColor) -> RGBA? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return RGBA(rgb: RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), a: c.alphaComponent)
    }

    private static func flatten(_ c: RGBA, over back: RGB) -> RGB {
        RGB(r: c.rgb.r * c.a + back.r * (1 - c.a), g: c.rgb.g * c.a + back.g * (1 - c.a), b: c.rgb.b * c.a + back.b * (1 - c.a))
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
