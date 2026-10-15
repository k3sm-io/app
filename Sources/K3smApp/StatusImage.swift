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

/// ButterflyImage renders the k3sm mark as the menu bar's status image: a
/// flat, filled template the menu bar tints for light and dark bars.
enum ButterflyImage {
    /// The canvas in points, the menu bar's usual image size.
    static let canvas: CGFloat = 18
    /// The square the mark is drawn into, centred on the canvas.
    static let markSize: CGFloat = 16
    /// The side of the degraded badge's triangle.
    static let badgeSize: CGFloat = 7
    /// The diameter of the dot shown when other devices may connect.
    static let dotSize: CGFloat = 6

    /// statusIcon is the mark with a triangle at the top right when
    /// `degraded` and a dot at the bottom right when `lan`. The drawing runs
    /// at the target's backing scale, so it stays crisp on every display.
    static func statusIcon(degraded: Bool, lan: Bool, label: String) -> NSImage {
        let size = NSSize(width: canvas, height: canvas)
        // A flipped canvas matches the path's coordinates (y grows down).
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = (canvas - markSize) / 2
            let rect = CGRect(x: inset, y: inset, width: markSize, height: markSize)
            ctx.addPath(Butterfly().path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            if degraded {
                badge(ctx, triangle(in: CGRect(x: canvas - badgeSize, y: 0, width: badgeSize, height: badgeSize)))
            }
            if lan {
                badge(ctx, CGPath(ellipseIn: CGRect(x: canvas - dotSize, y: canvas - dotSize, width: dotSize, height: dotSize), transform: nil))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// badge clears a one-point margin around `shape`, so it reads apart
    /// from the wing under it, then fills the shape.
    private static func badge(_ ctx: CGContext, _ shape: CGPath) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(shape)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
    }

    /// triangle is an upward triangle filling `rect` (y grows down).
    private static func triangle(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
