import AppKit
import Foundation

/// Draws the app icon and the drag-install disk image background.
///
///   swift scripts/render_branding.swift [repo root]
///
/// Writes Resources/AppIcon.icns and Resources/dmg-background.png.

let args = Array(CommandLine.arguments.dropFirst())
let previewOnly = args.contains("--preview")
let rootArg = args.first { !$0.hasPrefix("--") }
let root = URL(fileURLWithPath: rootArg ?? FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")

func savePNG(_ image: NSImage, to url: URL, pixels: NSSize, points: NSSize) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels.width),
        pixelsHigh: Int(pixels.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "branding", code: 1) }
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: points))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "branding", code: 2)
    }
    try data.write(to: url)
}

func fillOval(_ rect: NSRect, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

func waveform(in rect: NSRect) {
    let bars: [CGFloat] = [0.34, 0.58, 1.0, 0.46, 0.72]
    let gap = rect.width * 0.09
    let barW = (rect.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
    let amber = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.32, alpha: 1)
    fillOval(rect.insetBy(dx: -rect.width * 0.06, dy: -rect.height * 0.08),
             amber.withAlphaComponent(0.16))
    for (i, h) in bars.enumerated() {
        let bh = rect.height * h
        let bar = NSRect(x: rect.minX + CGFloat(i) * (barW + gap),
                         y: rect.midY - bh / 2,
                         width: barW, height: bh)
        amber.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
    }
}

func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.095, blue: 0.11, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.052, blue: 0.06, alpha: 1)
    ])!
    bg.draw(in: bounds, angle: -100)

    let capW = side * 0.58
    let capH = side * 0.54
    let cap = NSRect(x: (side - capW) / 2, y: side * 0.22, width: capW, height: capH)
    let radius = side * 0.07
    let lip = capH * 0.14

    fillOval(NSRect(x: cap.minX + capW * 0.10, y: cap.minY - side * 0.028,
                    width: capW * 0.80, height: side * 0.055),
             NSColor.black.withAlphaComponent(0.55))

    let bodyPath = NSBezierPath(roundedRect: cap, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.025, alpha: 1)
    ])!.draw(in: bodyPath, angle: -90)

    let top = NSRect(x: cap.minX, y: cap.minY + lip, width: cap.width, height: cap.height - lip)
    let topPath = NSBezierPath(roundedRect: top, xRadius: radius * 0.9, yRadius: radius * 0.9)
    NSGradient(colors: [
        NSColor(srgbRed: 0.55, green: 0.56, blue: 0.60, alpha: 1),
        NSColor(srgbRed: 0.32, green: 0.33, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.205, blue: 0.23, alpha: 1)
    ])!.draw(in: topPath, angle: -90)

    NSColor.white.withAlphaComponent(0.45).setStroke()
    let edge = NSBezierPath(roundedRect: top.insetBy(dx: side * 0.010, dy: side * 0.010),
                             xRadius: radius * 0.75, yRadius: radius * 0.75)
    edge.lineWidth = side * 0.005
    edge.stroke()

    let shine = NSRect(x: top.minX + top.width * 0.16, y: top.maxY - top.height * 0.20,
                       width: top.width * 0.38, height: top.height * 0.07)
    fillOval(shine, NSColor.white.withAlphaComponent(0.20))

    waveform(in: top.insetBy(dx: top.width * 0.22, dy: top.height * 0.30))
    image.unlockFocus()
    return image
}

func drawBackground(size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [
        NSColor(srgbRed: 0.11, green: 0.115, blue: 0.135, alpha: 1),
        NSColor(srgbRed: 0.055, green: 0.058, blue: 0.068, alpha: 1)
    ])!.draw(in: bounds, angle: -90)

    // Icon centers in the Finder window: (160, 210) and (500, 210) from the top.
    let iconY = size.height - 210
    for x in [CGFloat(160), CGFloat(500)] {
        let well = NSRect(x: x - 78, y: iconY - 78, width: 156, height: 156)
        fillOval(well, NSColor.white.withAlphaComponent(0.06))
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let ring = NSBezierPath(ovalIn: well.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1
        ring.stroke()
    }

    let title = "Thocky" as NSString
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        .kern: 0.6
    ]
    let titleSize = title.size(withAttributes: titleAttr)
    title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: size.height - 72),
               withAttributes: titleAttr)

    let sub = "Drag to Applications" as NSString
    let subAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.46)
    ]
    let subSize = sub.size(withAttributes: subAttr)
    sub.draw(at: NSPoint(x: (size.width - subSize.width) / 2, y: size.height - 96),
             withAttributes: subAttr)

    let y = iconY
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: y - 3))
    arrow.line(to: NSPoint(x: 368, y: y - 3))
    arrow.line(to: NSPoint(x: 368, y: y - 12))
    arrow.line(to: NSPoint(x: 412, y: y))
    arrow.line(to: NSPoint(x: 368, y: y + 12))
    arrow.line(to: NSPoint(x: 368, y: y + 3))
    arrow.line(to: NSPoint(x: 258, y: y + 3))
    arrow.close()
    NSColor.white.withAlphaComponent(0.78).setFill()
    arrow.fill()

    image.unlockFocus()
    return image
}

func rounded(_ image: NSImage, side: CGFloat) -> NSImage {
    let out = NSImage(size: NSSize(width: side, height: side))
    out.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    NSBezierPath(roundedRect: rect, xRadius: side * 0.223, yRadius: side * 0.223).addClip()
    image.draw(in: rect)
    out.unlockFocus()
    return out
}

func drawLabel(_ text: String, centerX: CGFloat, top: CGFloat) {
    let attr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92)
    ]
    let s = (text as NSString).size(withAttributes: attr)
    (text as NSString).draw(at: NSPoint(x: centerX - s.width / 2, y: top - s.height),
                            withAttributes: attr)
}

func showcase(icon: NSImage, background: NSImage) throws {
    let dir = root.appendingPathComponent("showcase")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let iconSide: CGFloat = 512
    try savePNG(rounded(icon, side: iconSide), to: dir.appendingPathComponent("icon.png"),
                pixels: NSSize(width: iconSide, height: iconSide),
                points: NSSize(width: iconSide, height: iconSide))

    let sheet = NSImage(size: NSSize(width: 760, height: 280))
    sheet.lockFocus()
    NSColor(srgbRed: 0.11, green: 0.115, blue: 0.13, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 760, height: 280).fill()
    let sizes: [CGFloat] = [180, 96, 48, 32, 16]
    var x: CGFloat = 36
    for side in sizes {
        let y = (280 - side) / 2
        rounded(icon, side: side).draw(in: NSRect(x: x, y: y, width: side, height: side))
        x += side + 28
    }
    sheet.unlockFocus()
    try savePNG(sheet, to: dir.appendingPathComponent("icon-sizes.png"),
                pixels: NSSize(width: 760, height: 280),
                points: NSSize(width: 760, height: 280))

    let windowW: CGFloat = 680
    let titleH: CGFloat = 28
    let contentH: CGFloat = 400
    let window = NSImage(size: NSSize(width: windowW, height: titleH + contentH))
    window.lockFocus()
    background.draw(in: NSRect(x: 0, y: 0, width: windowW, height: contentH))
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
    NSRect(x: 0, y: contentH, width: windowW, height: titleH).fill()
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9)
    ]
    let title = "Thocky" as NSString
    let titleSize = title.size(withAttributes: titleAttr)
    title.draw(at: NSPoint(x: (windowW - titleSize.width) / 2, y: contentH + 6),
               withAttributes: titleAttr)
    for (cx, color) in [(CGFloat(14), NSColor.systemRed),
                        (CGFloat(32), NSColor.systemYellow),
                        (CGFloat(50), NSColor.systemGreen)] {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx, y: contentH + 8, width: 12, height: 12)).fill()
    }

    let iconPt: CGFloat = 120
    let centers = [(CGFloat(160), "Thocky"), (CGFloat(500), "Applications")]
    let applicationsIcon = URL(fileURLWithPath:
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns")
    let appIcon = NSImage(contentsOf: applicationsIcon) ?? NSWorkspace.shared.icon(forFile: "/Applications")
    appIcon.size = NSSize(width: iconPt, height: iconPt)
    for (cx, name) in centers {
        let originY = contentH - 210 - iconPt / 2
        let rect = NSRect(x: cx - iconPt / 2, y: originY, width: iconPt, height: iconPt)
        if name == "Thocky" {
            rounded(icon, side: iconPt).draw(in: rect)
        } else {
            appIcon.draw(in: rect)
        }
        drawLabel(name, centerX: cx, top: originY - 6)
    }
    window.unlockFocus()
    try savePNG(window, to: dir.appendingPathComponent("dmg-window.png"),
                pixels: NSSize(width: windowW, height: titleH + contentH),
                points: NSSize(width: windowW, height: titleH + contentH))
    print("showcase \(dir.path)")
}

do {
    if previewOnly {
        let icon = drawIcon(side: 1024)
        let background = drawBackground(size: NSSize(width: 680, height: 400))
        try showcase(icon: icon, background: background)
        exit(0)
    }
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let iconPNG = resources.appendingPathComponent("AppIcon-1024.png")
    try savePNG(drawIcon(side: 1024), to: iconPNG,
                pixels: NSSize(width: 1024, height: 1024),
                points: NSSize(width: 1024, height: 1024))

    let iconset = resources.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, px) in sizes {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-z", "\(px)", "\(px)", iconPNG.path, "--out",
                          iconset.appendingPathComponent(name).path]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            fputs("sips failed for \(name)\n", stderr)
            exit(1)
        }
    }
    let icns = resources.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    if iconutil.terminationStatus != 0 {
        fputs("iconutil failed (\(iconutil.terminationStatus))\n", stderr)
        exit(1)
    }
    try? FileManager.default.removeItem(at: iconset)
    try? FileManager.default.removeItem(at: iconPNG)

    let bg = resources.appendingPathComponent("dmg-background.png")
    let points = NSSize(width: 680, height: 400)
    try savePNG(drawBackground(size: points), to: bg, pixels: points, points: points)
    print("wrote \(icns.path)")
    print("wrote \(bg.path)")
} catch {
    fputs("branding failed: \(error)\n", stderr)
    exit(1)
}
