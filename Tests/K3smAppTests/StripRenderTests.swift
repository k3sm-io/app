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
import K3smStatus
import SwiftUI
import Testing

@testable import K3smApp

/// The console's strip rendered off screen into a bitmap, in light,
/// dark and increased contrast, at its natural width and wider: each render
/// must come back at the size asked for. With `K3SM_RENDER_DIR` set the
/// renders are also written there as PNGs, for a person to look at; the
/// test never opens a window and never touches the running app. Liquid
/// Glass is drawn by the window server, so the button groups' glass does not
/// appear in these off-screen renders.
@MainActor
@Suite struct StripRenderTests {
    /// The appearances rendered, by the file name each one writes.
    static let appearances: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
        ("light-contrast", .accessibilityHighContrastAqua), ("dark-contrast", .accessibilityHighContrastDarkAqua),
    ]

    @Test func stripRendersAtEveryAppearanceAndWidth() throws {
        let defaults = UserDefaults.standard
        let keys = [ConsoleTabs.sectionKey, AppModel.inspectorShownKey, PanelLayout.collapsedKey]
        let kept = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in kept {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        _ = NSApplication.shared
        let app = AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
        app.section = .nodes
        let natural = WindowFrame.stripScrollWidth(app.consoleMinimumInputs)
        let out = ProcessInfo.processInfo.environment["K3SM_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (name, appearance) in Self.appearances {
            for (label, width) in [("natural", natural), ("wide", natural + 360)] {
                let image = try #require(Self.render(app: app, width: width, appearance: appearance))
                #expect(image.width == Int((width * 2).rounded()))
                #expect(image.height == Int((TabStripLayout.height * 2).rounded()))
                if let out { try Self.write(image, to: out.appendingPathComponent("strip-\(name)-\(label).png")) }
            }
        }
        // A flat tab and a glyph button under the pointer show their hover
        // fill: each render differs from the same strip with no hover, and the
        // light strip from the dark one, so a blank render cannot pass.
        let plainLight = try #require(Self.render(app: app, width: natural, appearance: .aqua))
        let plainDark = try #require(Self.render(app: app, width: natural, appearance: .darkAqua))
        #expect(Self.pixels(plainLight) != Self.pixels(plainDark))
        app.stripHover.hovered = .tab(.images)
        let hovered = try #require(Self.render(app: app, width: natural, appearance: .aqua))
        #expect(Self.pixels(hovered) != Self.pixels(plainLight))
        if let out { try Self.write(hovered, to: out.appendingPathComponent("strip-light-hover-tab.png")) }
        app.stripHover.hovered = .info
        let glyph = try #require(Self.render(app: app, width: natural, appearance: .darkAqua))
        #expect(Self.pixels(glyph) != Self.pixels(plainDark))
        if let out { try Self.write(glyph, to: out.appendingPathComponent("strip-dark-hover-glyph.png")) }
        app.stripHover.hovered = nil
        // Narrower than its natural width the strip scrolls; the render still comes back whole.
        let narrow = try #require(Self.render(app: app, width: 520, appearance: .aqua))
        #expect(narrow.width == 1040)
        if let out { try Self.write(narrow, to: out.appendingPathComponent("strip-light-overflow.png")) }
    }

    /// The strip at `width`, in `appearance`, on the console's surface: an
    /// off-screen hosting view (never put in a window, never shown) drawn
    /// into a 2x bitmap, so the strip's AppKit-backed parts (the search
    /// field, the horizontal scroll) draw as they do on screen, which
    /// `ImageRenderer` leaves as placeholders.
    static func render(app: AppModel, width: Double, appearance: NSAppearance.Name) -> CGImage? {
        // An off-screen view does not read Increase Contrast from its
        // appearance, so the contrast renders set it as the system would.
        let contrast = appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua
        let view = ConsoleStrip(app: app)
            .frame(width: CGFloat(width), height: CGFloat(TabStripLayout.height))
            .background(Palette.surface)
            .environment(\._colorSchemeContrast, contrast ? .increased : .standard)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(TabStripLayout.height))
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: CGFloat(width) * 2, height: CGFloat(TabStripLayout.height) * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded()),
                                         pixelsHigh: Int(size.height.rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = host.bounds.size
        host.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep.cgImage
    }

    /// The image's pixels, for telling two renders apart.
    static func pixels(_ image: CGImage) -> Data {
        (image.dataProvider?.data as Data?) ?? Data()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}
