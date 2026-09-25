#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Writes the input-source menu icon: ㄅ knocked out of a filled rounded square.
//
// Two things here are not free choices.
//
// The page is 16x16 POINTS. macOS reads an input-method icon's PDF page size as
// its point size, so it is not scaled to fit the menu — a 64pt page draws a 64pt
// icon. That is what pushed the name onto its own line in the input menu and
// made the entry overlap its label in System Settings. Being vector, one 16pt
// page still renders sharply at the larger size the settings list uses.
//
// The glyph is knocked OUT of the square rather than drawn on top of it. The
// menu treats this as a template image: only the alpha channel is read and the
// system paints the result to match the bar, so anything drawn in a second
// colour would come back as one flat silhouette with no ㄅ visible at all.
//
// The hole is made with an even-odd fill of one combined path, NOT with a
// .clear blend mode. A bitmap context honours .clear, so a PNG preview of it
// looks right, but PDF has no such blend mode and the operation is dropped on
// the way out: the page then holds a plain filled square. Even-odd is plain
// vector geometry, so what the PDF stores is what was drawn. ㄅ has no closed
// counter, so nothing inside the glyph is toggled back on.
//
// The outline is taken from the installed font at generation time and baked
// into the PDF as a path, so nothing has to resolve a font at runtime.
//
// Usage: swift macos/make-icon.swift macos/ari.pdf

import AppKit
import CoreText

let side: CGFloat = 16
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ari.pdf"

// ㄅ rather than 注: the icon sits directly below Apple's own Zhuyin entry,
// whose icon is 注 in a square. At 16pt a second 注 is neither distinguishable
// from it nor legible — the strokes merge. ㄅ opens ㄅㄆㄇㄈ, so it reads as
// Bopomofo at a glance and stays clean at this size.
let symbol = "ㄅ"

func glyphPath(_ text: String, size: CGFloat) -> CGPath {
    let font = NSFont(name: "PingFangTC-Semibold", size: size)
        ?? NSFont(name: "HeitiTC-Medium", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font]))
    let combined = CGMutablePath()
    for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
        let runFont = unsafeBitCast(
            CFDictionaryGetValue(
                CTRunGetAttributes(run),
                unsafeBitCast(kCTFontAttributeName, to: UnsafeRawPointer.self)),
            to: CTFont.self)
        for i in 0..<CTRunGetGlyphCount(run) {
            var glyph = CGGlyph()
            var pos = CGPoint()
            CTRunGetGlyphs(run, CFRangeMake(i, 1), &glyph)
            CTRunGetPositions(run, CFRangeMake(i, 1), &pos)
            if let p = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                combined.addPath(p, transform: CGAffineTransform(translationX: pos.x,
                                                                 y: pos.y))
            }
        }
    }
    return combined
}

// Centre on the glyph's own ink bounds. A Bopomofo glyph does not fill its em
// box, so using the typographic advance instead would sit it off-centre.
func fitted(_ path: CGPath, into box: CGRect) -> CGPath {
    let bounds = path.boundingBoxOfPath
    guard bounds.width > 0, bounds.height > 0 else { return path }
    let scale = min(box.width / bounds.width, box.height / bounds.height)
    var transform = CGAffineTransform.identity
        .translatedBy(x: box.midX, y: box.midY)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    return path.copy(using: &transform) ?? path
}

var mediaBox = CGRect(x: 0, y: 0, width: side, height: side)
guard let context = CGContext(URL(fileURLWithPath: output) as CFURL,
                              mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("cannot write \(output)\n".data(using: .utf8)!)
    exit(1)
}

context.beginPDFPage(nil)

// A 1pt margin keeps the square off the edge of the menu's icon slot; the
// corner radius matches the proportion Apple's own input-source icons use.
let plate = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
let knockout = CGMutablePath()
knockout.addPath(CGPath(roundedRect: plate, cornerWidth: side * 0.25,
                        cornerHeight: side * 0.25, transform: nil))
knockout.addPath(fitted(glyphPath(symbol, size: side),
                        into: plate.insetBy(dx: plate.width * 0.19,
                                            dy: plate.height * 0.19)))
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.addPath(knockout)
context.fillPath(using: .evenOdd)

context.endPDFPage()
context.closePDF()
print("wrote \(output)")
