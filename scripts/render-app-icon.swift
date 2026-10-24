#!/usr/bin/env swift
// Renders App/Assets.xcassets/AppIcon.appiconset from the mark on the About window (`AppMark`): a teal rounded
// square with a white ring. The square sits on Apple's macOS icon grid (824 of 1024 points, centered).
//
// Usage: scripts/render-app-icon.swift      (run from the repository root after changing the mark)
import AppKit

let teal = NSColor(srgbRed: 0.0, green: 0.51, blue: 0.56, alpha: 1)  // Theme.teal, light appearance
let output = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Same proportions as AppMark: corner 0.24, ring 0.46 wide with a 0.075 stroke inside its edge.
    let side = size * 824 / 1024
    let square = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    context.addPath(CGPath(roundedRect: square, cornerWidth: side * 0.24, cornerHeight: side * 0.24, transform: nil))
    context.setFillColor(teal.cgColor)
    context.fillPath()

    let lineWidth = side * 0.075
    let ring = side * 0.46 - lineWidth
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(lineWidth)
    context.strokeEllipse(in: CGRect(x: (size - ring) / 2, y: (size - ring) / 2, width: ring, height: ring))

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
