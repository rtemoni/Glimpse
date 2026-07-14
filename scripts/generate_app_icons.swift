#!/usr/bin/env swift

import AppKit
import Foundation

private let fileManager = FileManager.default
private let repositoryRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
private let resources = repositoryRoot.appendingPathComponent("Sources/Glimpse/Resources", isDirectory: true)
private let markURL = resources.appendingPathComponent("AppIcon.icon/Assets/GlimpseMark.png")
private let appIconSetURL = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
private let icnsURL = resources.appendingPathComponent("AppIcon.icns")
private let startIconURL = resources.appendingPathComponent("GlimpseStartIcon.png")

private enum GeneratorError: LocalizedError {
    case imageLoadFailed(URL)
    case bitmapCreationFailed(Int)
    case pngEncodingFailed(Int)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Unable to load image at \(url.path)"
        case .bitmapCreationFailed(let size):
            return "Unable to create a \(size)x\(size) bitmap"
        case .pngEncodingFailed(let size):
            return "Unable to encode a \(size)x\(size) PNG"
        }
    }
}

private func bitmap(size: Int, drawing: () -> Void) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GeneratorError.bitmapCreationFailed(size)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    drawing()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func pngData(from bitmap: NSBitmapImageRep, size: Int) throws -> Data {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneratorError.pngEncodingFailed(size)
    }
    return data
}

private func writePNG(_ bitmap: NSBitmapImageRep, size: Int, to url: URL) throws {
    try pngData(from: bitmap, size: size).write(to: url, options: .atomic)
}

private func renderLegacyIcon(mark: NSImage, size: Int) throws -> NSBitmapImageRep {
    let scale = CGFloat(size) / 1024
    return try bitmap(size: size) {
        let baseRect = NSRect(x: 72 * scale, y: 72 * scale, width: 880 * scale, height: 880 * scale)
        let radius = 198 * scale
        let basePath = NSBezierPath(roundedRect: baseRect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 38 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
        shadow.set()
        NSColor.black.setFill()
        basePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colorsAndLocations:
            (NSColor(displayP3Red: 0.11, green: 0.09, blue: 0.35, alpha: 1), 0),
            (NSColor(displayP3Red: 0.29, green: 0.18, blue: 0.83, alpha: 1), 1)
        )
        gradient?.draw(in: basePath, angle: 90)

        NSColor.white.withAlphaComponent(0.20).setStroke()
        basePath.lineWidth = max(1, 3 * scale)
        basePath.stroke()

        mark.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)),
            from: NSRect(origin: .zero, size: mark.size),
            operation: .sourceOver,
            fraction: 1
        )
    }
}

private func resize(_ image: NSImage, to size: Int) throws -> NSBitmapImageRep {
    try bitmap(size: size) {
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
    }
}

private func bigEndianBytes(_ value: Int) -> Data {
    var value = UInt32(value).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func writeICNS(chunks: [(type: String, data: Data)], to url: URL) throws {
    var payload = Data()
    for chunk in chunks {
        precondition(chunk.type.utf8.count == 4)
        payload.append(contentsOf: chunk.type.utf8)
        payload.append(bigEndianBytes(chunk.data.count + 8))
        payload.append(chunk.data)
    }

    var file = Data("icns".utf8)
    file.append(bigEndianBytes(payload.count + 8))
    file.append(payload)
    try file.write(to: url, options: .atomic)
}

do {
    guard let mark = NSImage(contentsOf: markURL) else {
        throw GeneratorError.imageLoadFailed(markURL)
    }

    try fileManager.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

    let masterBitmap = try renderLegacyIcon(mark: mark, size: 1024)
    guard let masterImage = NSImage(data: try pngData(from: masterBitmap, size: 1024)) else {
        throw GeneratorError.bitmapCreationFailed(1024)
    }

    let iconFiles: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    var generatedPNGs: [String: Data] = [:]
    for iconFile in iconFiles {
        let resized = try resize(masterImage, to: iconFile.pixels)
        let data = try pngData(from: resized, size: iconFile.pixels)
        generatedPNGs[iconFile.name] = data
        try data.write(to: appIconSetURL.appendingPathComponent(iconFile.name), options: .atomic)
    }

    let startIcon = try resize(mark, to: 256)
    try writePNG(startIcon, size: 256, to: startIconURL)

    let icnsChunks: [(type: String, file: String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png")
    ]
    try writeICNS(
        chunks: try icnsChunks.map { chunk in
            guard let data = generatedPNGs[chunk.file] else {
                throw GeneratorError.pngEncodingFailed(0)
            }
            return (chunk.type, data)
        },
        to: icnsURL
    )

    print("Generated AppIcon.icns, the macOS app icon set, and GlimpseStartIcon.png")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
