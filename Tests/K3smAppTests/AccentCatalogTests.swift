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
import Foundation
import SwiftUI
import Testing

@testable import K3smApp

/// The committed accent catalog (Resources/Assets.car) is a binary the build
/// copies into the bundle before signing. hack/make-accent.sh is its source,
/// but its --check needs Xcode's actool. These tests tie the binary to the
/// script with assetutil, which ships with macOS: the catalog holds exactly
/// the script's two AccentColor colours and nothing else, and
/// Palette.controlAccent spells the same pair. The script's colour-set JSON is the one source of
/// the pair; nothing here repeats the values.
@Suite(.enabled(if: AccentCatalog.hasAssetutil, "needs /usr/bin/assetutil, which ships with macOS"))
struct AccentCatalogTests {
    @Test func accentCatalogHoldsOnlyTheAccentColour() throws {
        let pair = try AccentCatalog.scriptPair()
        let problems = try AccentCatalog.problems(catalog: AccentCatalog.committed, expected: pair)
        #expect(problems == [])
    }

    /// The check is not vacuous: a catalog with one component changed, a
    /// catalog full of other assets, and a file that is no catalog all fail.
    @Test func tamperedCatalogsFail() throws {
        let pair = try AccentCatalog.scriptPair()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The light blue component (0x89 / 255) is stored as a double; change it.
        var bytes = try Data(contentsOf: AccentCatalog.committed)
        var blue = Double(pair.light & 0xff) / 255
        let needle = withUnsafeBytes(of: &blue) { Data($0) }
        let at = try #require(bytes.range(of: needle), "the light blue component is not in the catalog as a double")
        var other = 0.6
        bytes.replaceSubrange(at, with: withUnsafeBytes(of: &other) { Data($0) })
        let wrong = dir.appendingPathComponent("wrong.car")
        try bytes.write(to: wrong)
        #expect(try AccentCatalog.problems(catalog: wrong, expected: pair).contains { $0.contains("components") })

        // A system app's catalog: images, other names, far over the size cap.
        let foreign = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/Resources/Assets.car")
        try #require(FileManager.default.fileExists(atPath: foreign.path))
        let foreignProblems = try AccentCatalog.problems(catalog: foreign, expected: pair)
        #expect(foreignProblems.contains { $0.contains("not a colour") })
        #expect(foreignProblems.contains { $0.contains("bytes") })

        let bogus = dir.appendingPathComponent("bogus.car")
        try Data("not a catalog\n".utf8).write(to: bogus)
        #expect(try AccentCatalog.problems(catalog: bogus, expected: pair).contains { $0.contains("assetutil") })
    }

    @Test func paletteControlAccentMatchesTheScript() throws {
        let pair = try AccentCatalog.scriptPair()
        #expect(AccentCatalog.hex(Palette.controlAccent, appearance: .aqua) == pair.light)
        #expect(AccentCatalog.hex(Palette.controlAccent, appearance: .darkAqua) == pair.dark)
    }
}

/// AccentCatalog reads the accent pair out of hack/make-accent.sh and checks
/// a compiled catalog against it.
enum AccentCatalog {
    static let assetutil = "/usr/bin/assetutil"
    static let maxBytes = 32 * 1024
    static var hasAssetutil: Bool { FileManager.default.isExecutableFile(atPath: assetutil) }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var committed: URL { root.appendingPathComponent("Resources/Assets.car") }
    static var script: URL { root.appendingPathComponent("hack/make-accent.sh") }

    struct Pair: Equatable { var light: UInt32; var dark: UInt32 }

    enum Failure: Error, CustomStringConvertible {
        case script(String)
        var description: String { switch self { case .script(let s): "make-accent.sh: \(s)" } }
    }

    /// scriptPair parses the colour-set Contents.json the script writes (its
    /// <<'JSON' heredoc): the entry with no appearance is light, the one with
    /// luminosity dark is dark.
    static func scriptPair() throws -> Pair {
        let text = try String(contentsOf: script, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasSuffix("<<'JSON'") }),
              let end = lines[(start + 1)...].firstIndex(of: "JSON") else { throw Failure.script("no <<'JSON' heredoc") }
        let json = lines[(start + 1)..<end].joined(separator: "\n")
        guard let top = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let colors = top["colors"] as? [[String: Any]], colors.count == 2 else { throw Failure.script("not two colours") }
        var light: UInt32?
        var dark: UInt32?
        for entry in colors {
            guard let color = entry["color"] as? [String: Any], color["color-space"] as? String == "srgb",
                  let c = color["components"] as? [String: String], c["alpha"] == "1.000",
                  let r = byte(c["red"]), let g = byte(c["green"]), let b = byte(c["blue"]) else {
                throw Failure.script("a colour is not opaque srgb hex components")
            }
            let hex = r << 16 | g << 8 | b
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            if appearances.isEmpty { light = hex }
            else if appearances == [["appearance": "luminosity", "value": "dark"]] { dark = hex }
            else { throw Failure.script("unexpected appearances \(appearances)") }
        }
        guard let light, let dark else { throw Failure.script("needs one light and one dark colour") }
        return Pair(light: light, dark: dark)
    }

    private static func byte(_ s: String?) -> UInt32? {
        guard let s, s.hasPrefix("0x"), s.count == 4, let v = UInt32(s.dropFirst(2), radix: 16) else { return nil }
        return v
    }

    /// problems lists every way the catalog differs from the accent pair,
    /// empty when it holds exactly the two AccentColor colours and is small.
    static func problems(catalog: URL, expected: Pair) throws -> [String] {
        var out: [String] = []
        let size = (try FileManager.default.attributesOfItem(atPath: catalog.path)[.size] as? Int) ?? 0
        if size >= maxBytes { out.append("catalog is \(size) bytes, not under \(maxBytes)") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: assetutil)
        p.arguments = ["--info", catalog.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return out + ["assetutil cannot read the catalog (exit \(p.terminationStatus))"]
        }

        var seen: [String: UInt32] = [:]
        for entry in entries where entry["AssetType"] != nil {
            let name = entry["Name"] as? String ?? "?"
            guard entry["AssetType"] as? String == "Color" else {
                out.append("rendition \(name) is not a colour: \(entry["AssetType"] ?? "?")")
                continue
            }
            guard name == "AccentColor" else { out.append("colour \(name) is not AccentColor"); continue }
            let key: String
            switch entry["Appearance"] as? String {
            case nil: key = "any"
            case "NSAppearanceNameDarkAqua": key = "dark"
            case let other?: out.append("AccentColor has an unexpected appearance \(other)"); continue
            }
            guard seen[key] == nil else { out.append("AccentColor \(key) appears twice"); continue }
            guard entry["Colorspace"] as? String == "srgb",
                  let c = entry["Color components"] as? [Double], c.count == 4, c[3] == 1 else {
                out.append("AccentColor \(key) is not opaque srgb components")
                continue
            }
            let bytes = c[0..<3].map { UInt32(($0 * 255).rounded()) }
            let exact = zip(c[0..<3], bytes).allSatisfy { abs($0 * 255 - Double($1)) < 1e-6 }
            guard exact else { out.append("AccentColor \(key) components \(c) are not whole bytes"); continue }
            seen[key] = bytes[0] << 16 | bytes[1] << 8 | bytes[2]
        }
        for (key, want) in [("any", expected.light), ("dark", expected.dark)] {
            if let got = seen[key], got != want {
                out.append("AccentColor \(key) components are \(css(got)), want \(css(want))")
            } else if seen[key] == nil {
                out.append("no AccentColor \(key) rendition")
            }
        }
        return out
    }

    private static func css(_ hex: UInt32) -> String {
        let digits = String(hex, radix: 16)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// hex is the colour's sRGB value as drawn under the appearance.
    static func hex(_ color: Color, appearance: NSAppearance.Name) -> UInt32? {
        var out: UInt32?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = UInt32((c.redComponent * 255).rounded())
            let g = UInt32((c.greenComponent * 255).rounded())
            let b = UInt32((c.blueComponent * 255).rounded())
            out = r << 16 | g << 8 | b
        }
        return out
    }
}
