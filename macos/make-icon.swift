#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Renders data/inputer.svg as the PDF the input-source menu wants. The SVG is
// nothing but rectangles, so redrawing it here avoids depending on rsvg or any
// other converter that is not already on a Mac.
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
let cream = color(0xf7f4ed)
let teal = color(0x2f5d62)

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

fill(0, 0, side, side, radius: 14, cream)
fill(14, 14, 36, 36, teal)

context.setStrokeColor(cream)
context.setLineWidth(2)
context.stroke(CGRect(x: 18, y: 18, width: 28, height: 28))

// The 注 glyph, as the same seven bars the SVG uses.
for bar in [(23.0, 21.0, 4.0, 6.0), (22.0, 31.0, 4.0, 4.0), (23.0, 39.0, 4.0, 6.0),
            (31.0, 20.0, 4.0, 24.0), (29.0, 24.0, 13.0, 4.0),
            (29.0, 32.0, 13.0, 4.0), (29.0, 40.0, 13.0, 4.0)] {
    fill(CGFloat(bar.0), CGFloat(bar.1), CGFloat(bar.2), CGFloat(bar.3),
         radius: 1, cream)
}

context.endPDFPage()
context.closePDF()
print("wrote \(output)")
