// Renders the app icon as a 1024px PNG using only CoreGraphics.
// Run through `swift tools/make-icon.swift <output.png>` (see tools/make-icon.sh).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let dimension = 1024
let side = CGFloat(dimension)
let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

guard let context = CGContext(
    data: nil,
    width: dimension,
    height: dimension,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("make-icon: cannot create bitmap context\n".utf8))
    exit(1)
}

context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

// macOS icon grid: rounded square inset from the canvas edge.
let inset = side * 0.055
let plateRect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let plateCorner = plateRect.width * 0.2237
let plate = CGPath(
    roundedRect: plateRect,
    cornerWidth: plateCorner,
    cornerHeight: plateCorner,
    transform: nil
)

context.saveGState()
context.addPath(plate)
context.clip()
if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.36, 0.42, 1.0), color(0.20, 0.16, 0.62)] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plateRect.minX, y: plateRect.maxY),
        end: CGPoint(x: plateRect.maxX, y: plateRect.minY),
        options: []
    )
}
context.restoreGState()

// The "input bar": a translucent pill with a bright caret.
let pillWidth = plateRect.width * 0.66
let pillHeight = plateRect.height * 0.20
let pill = CGRect(
    x: plateRect.midX - pillWidth / 2,
    y: plateRect.midY - pillHeight / 2 - plateRect.height * 0.05,
    width: pillWidth,
    height: pillHeight
)
let pillCorner = pillHeight / 2
let pillPath = CGPath(roundedRect: pill, cornerWidth: pillCorner, cornerHeight: pillCorner, transform: nil)

context.saveGState()
context.addPath(pillPath)
context.setFillColor(color(1, 1, 1, 0.16))
context.fillPath()

context.addPath(pillPath)
context.setStrokeColor(color(1, 1, 1, 0.92))
context.setLineWidth(side * 0.022)
context.strokePath()

let caret = CGRect(
    x: pill.minX + pillHeight * 0.42,
    y: pill.minY + pillHeight * 0.24,
    width: pillHeight * 0.11,
    height: pillHeight * 0.52
)
context.addPath(CGPath(roundedRect: caret, cornerWidth: caret.width / 2, cornerHeight: caret.width / 2, transform: nil))
context.setFillColor(color(1, 1, 1, 0.98))
context.fillPath()

// Two text-like lines inside the pill.
context.setFillColor(color(1, 1, 1, 0.62))
for (index, widthFactor) in [0.42, 0.26].enumerated() {
    let lineHeight = pillHeight * 0.10
    let rect = CGRect(
        x: caret.maxX + pillHeight * 0.26,
        y: pill.maxY - pillHeight * (0.34 + CGFloat(index) * 0.24) - lineHeight / 2,
        width: pillWidth * CGFloat(widthFactor),
        height: lineHeight
    )
    context.addPath(CGPath(roundedRect: rect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
    context.fillPath()
}
context.restoreGState()

// A four-point sparkle, top-right: the "intelligence" hint.
let sparkleCenter = CGPoint(x: plateRect.maxX - plateRect.width * 0.17, y: plateRect.maxY - plateRect.height * 0.17)
let sparkleRadius = plateRect.width * 0.13
let waist = sparkleRadius * 0.24
let sparkle = CGMutablePath()
sparkle.move(to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y + sparkleRadius))
sparkle.addQuadCurve(
    to: CGPoint(x: sparkleCenter.x + sparkleRadius, y: sparkleCenter.y),
    control: CGPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y + waist)
)
sparkle.addQuadCurve(
    to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y - sparkleRadius),
    control: CGPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y - waist)
)
sparkle.addQuadCurve(
    to: CGPoint(x: sparkleCenter.x - sparkleRadius, y: sparkleCenter.y),
    control: CGPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y - waist)
)
sparkle.addQuadCurve(
    to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y + sparkleRadius),
    control: CGPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y + waist)
)
context.addPath(sparkle)
context.setFillColor(color(1, 1, 1, 1))
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("make-icon: cannot render image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("make-icon: cannot create \(outputPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("make-icon: cannot write \(outputPath)\n".utf8))
    exit(1)
}
print("make-icon: wrote \(outputPath)")
