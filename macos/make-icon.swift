#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Renders data/inputer.svg as the PDF the input-source menu wants. The SVG is
// nothing but rectangles, so redrawing it here avoids depending on rsvg or any
// other converter that is not already on a Mac.
//
// The menu bar treats this as a template image: only the alpha channel is read,
// and the system colours it to match the bar. So the artwork is drawn as a
// silhouette — the SVG's cream background would otherwise fill the whole square
// with opaque pixels and render as a solid black tile.
//
// Usage: swift macos/make-icon.swift macos/ari.pdf

import AppKit

let side: CGFloat = 64
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ari.pdf"

var mediaBox = CGRect(x: 0, y: 0, width: side, height: side)
guard let context = CGContext(URL(fileURLWithPath: output) as CFURL,
                              mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("cannot write \(output)\n".data(using: .utf8)!)
    exit(1)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
}
// Any opaque colour reads the same once the system applies its template
// treatment; black keeps the PDF legible on its own if opened directly.
let ink = color(0x000000)

context.beginPDFPage(nil)
// SVG measures y downwards from the top; PDF measures it upwards from the
// bottom. Flipping once lets the coordinates below match the SVG verbatim.
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)

func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
          radius: CGFloat = 0, _ fillColor: CGColor) {
    context.setFillColor(fillColor)
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                           cornerWidth: radius, cornerHeight: radius,
                           transform: nil))
    context.fillPath()
}

// A ring rather than a filled square: the enclosed area has to stay
// transparent for the glyph inside it to be visible at all.
context.setStrokeColor(ink)
context.setLineWidth(3)
context.addPath(CGPath(roundedRect: CGRect(x: 9, y: 9, width: 46, height: 46),
                       cornerWidth: 10, cornerHeight: 10, transform: nil))
context.strokePath()

// The 注 glyph, as the same seven bars the SVG uses, scaled to the ring.
for bar in [(19.0, 19.0, 4.0, 7.0), (18.0, 30.0, 4.0, 4.0), (19.0, 39.0, 4.0, 7.0),
            (30.0, 18.0, 4.0, 28.0), (28.0, 22.0, 15.0, 4.0),
            (28.0, 31.0, 15.0, 4.0), (28.0, 40.0, 15.0, 4.0)] {
    fill(CGFloat(bar.0), CGFloat(bar.1), CGFloat(bar.2), CGFloat(bar.3),
         radius: 1, ink)
}

context.endPDFPage()
context.closePDF()
print("wrote \(output)")
