import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import KoreUI

/// What keeps drawn text and pictures cheap: text colours macOS can store at 2 bytes a pixel,
/// windows that draw in sRGB, and chips that decode pictures at their own size.
@MainActor
@Suite("layer memory")
struct LayerMemoryTests {
    private func components(_ color: Color) throws -> (r: Double, g: Double, b: Double, a: Double) {
        let ns = try #require(NSColor(color).usingColorSpace(.sRGB))
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    private func luminance(_ color: Color) throws -> Double {
        let c = try components(color)
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: Color, on b: Color) throws -> Double {
        let (x, y) = (try luminance(a), try luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: Text colours

    /// A paragraph's layer holding only greys stays at 2 bytes a pixel; a tint anywhere in it
    /// (the text, or the inline-code fill made from it) takes it to 8 on a wide-gamut screen.
    /// (`secondary` and `tertiary` keep the hue: greying them measured no further saving.)
    @Test func proseColoursAreNeutralGreys() throws {
        for (name, color) in [("text", Theme.text), ("inlineCode", Theme.inlineCode)] {
            let c = try components(color)
            #expect(abs(c.r - c.g) < 0.5 / 255 && abs(c.g - c.b) < 0.5 / 255, "\(name) is tinted: \(c)")
        }
    }

    /// The grey kept the tinted text's luminance: contrast on the window ground is unchanged.
    @Test func greysKeepTheirContrast() throws {
        #expect(try contrast(Theme.text, on: Theme.background) >= 16.0)
        #expect(try contrast(Theme.secondary, on: Theme.background) >= 6.0)
        #expect(try contrast(Theme.tertiary, on: Theme.background) >= 4.7)
        #expect(try contrast(Theme.tertiary, on: Theme.surface) >= 4.3)
    }

    // MARK: Windows

    @Test func windowsDrawInSRGB() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        WindowColor.prepare(window)
        #expect(window.colorSpace == .sRGB)
        WindowColor.prepare(window)
        #expect(window.colorSpace == .sRGB)
    }

    // MARK: Picture chips

    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func pixels(_ image: NSImage?) throws -> (Int, Int) {
        let cg = try #require(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return (cg.width, cg.height)
    }

    @Test func aPastedScreenshotsChipIsChipSizedAndOpensWhole() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chip-\(UUID().uuidString).png")
        try png(width: 2000, height: 1500).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = Attachment(url: url)
        let (w, h) = try pixels(attachment.thumbnail)
        #expect(max(w, h) <= Thumbnail.maxPixels)
        #expect(w > h)
        #expect(try pixels(attachment.image) == (2000, 1500))
        // The same thumbnail each time: made once.
        #expect(attachment.thumbnail === attachment.thumbnail)
    }

    @Test func aPictureFromHistoryIsChipSizedAndOpensWhole() throws {
        let attachment = Attachment(name: "Image", kind: .image, imageData: try png(width: 1200, height: 1600))
        let (w, h) = try pixels(attachment.thumbnail)
        #expect(max(w, h) <= Thumbnail.maxPixels && h > w)
        #expect(try pixels(attachment.image) == (1200, 1600))
        // Copy and Save As get the whole picture, not the chip's.
        #expect(try pixels(MediaMenu.Target(attachment).image) == (1200, 1600))
    }

    @Test func aDocumentHasNoPicture() {
        let attachment = Attachment(name: "notes.md", kind: .text)
        #expect(attachment.thumbnail == nil && attachment.image == nil)
    }
}
