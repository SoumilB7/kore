// Renders the app icon into a macOS .iconset (every size iconutil expects). The small SVG, if
// given, is used at 32px and below, where outlines and gradients don't survive.
//   swift scripts/render-icon.swift <icon.svg> <out.iconset> [small.svg]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: render-icon <icon.svg> <out.iconset> [small.svg]\n".utf8))
    exit(1)
}
let small = args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (pixels <= 32 ? small ?? svg : svg).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
