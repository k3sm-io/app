#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-icon.sh <svg> <out.icns>
#
# Renders the k3sm butterfly mark (Resources/k3sm-mark.svg) into the app icon
# (Resources/AppIcon.icns). The icon is the mark alone on a transparent
# background, by the maintainers' choice, rather than the rounded-square shape
# Apple's Human Interface Guidelines suggest for macOS app icons.
#
# The mark is drawn with AppKit at 1024x1024, centred and scaled to fill about
# 80 percent of the canvas with its aspect ratio kept. sips derives every
# AppIcon.iconset member (16 to 512 at 1x and 2x) from that render, and
# iconutil packs the set. Only the toolchain and the system are used: swift,
# sips and iconutil.
#
# The generated AppIcon.icns is committed, so a build needs no regeneration;
# this script is its reproducible source. Rerun it after the mark changes.
set -euo pipefail

usage() {
	echo "usage: hack/make-icon.sh <svg> <out.icns>" >&2
	exit 2
}
[ "$#" -eq 2 ] || usage
SVG="$1"
OUT="$2"
[ -f "$SVG" ] || { echo "make-icon: no such file: $SVG" >&2; exit 1; }
case "$OUT" in
*.icns) ;;
*) usage ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/render.swift" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render <svg> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
guard let mark = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      mark.size.width > 0, mark.size.height > 0 else {
    FileHandle.standardError.write("render: cannot load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let side = 1024
let fill = 0.8 * Double(side)
let scale = min(fill / mark.size.width, fill / mark.size.height)
let w = mark.size.width * scale
let h = mark.size.height * scale
let rect = NSRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("render: cannot make a bitmap context\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
NSColor.clear.set()
NSRect(x: 0, y: 0, width: side, height: side).fill()
mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render: cannot encode PNG\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write("render: \(error)\n".data(using: .utf8)!)
    exit(1)
}
SWIFT

echo "==> render 1024x1024"
swift "$work/render.swift" "$SVG" "$work/icon-1024.png"

echo "==> iconset"
set_dir="$work/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
	double=$((size * 2))
	sips -z "$size" "$size" "$work/icon-1024.png" --out "$set_dir/icon_${size}x${size}.png" > /dev/null
	sips -z "$double" "$double" "$work/icon-1024.png" --out "$set_dir/icon_${size}x${size}@2x.png" > /dev/null
done

echo "==> iconutil -c icns"
iconutil -c icns "$set_dir" -o "$OUT"
echo "make-icon: $OUT"
