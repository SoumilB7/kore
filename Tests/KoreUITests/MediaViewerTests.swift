import AppKit
import Foundation
import Testing

@testable import KoreUI

/// SVG and video in the chat's viewer: which view a chip opens, and the chip's picture, made once
/// off the main actor. On a temp folder.
@MainActor
@Suite("SVG and video in the viewer")
struct MediaViewerTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-viewer-\(UUID().uuidString)")

    static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect x="4" y="20" width="40" height="40" fill="red">\
        <animate attributeName="x" values="4;76;4" dur="1s" repeatCount="indefinite"/></rect></svg>
        """

    private func write(_ name: String, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func anSVGIsMeasuredFromItsRootTag() {
        #expect(SVGFile.rootSize(Data(Self.svg.utf8)) == CGSize(width: 120, height: 80))
        #expect(SVGFile.rootSize(Data(#"<svg viewBox="0 0 30 20"/>"#.utf8)) == CGSize(width: 30, height: 20))
        #expect(SVGFile.rootSize(Data(#"<svg width="50%" height="10"/>"#.utf8)) == nil)
    }

    @Test func eachChipOpensItsOwnView() async throws {
        let media = AttachedMediaTests()
        let movie = try await media.movie()
        defer { try? FileManager.default.removeItem(at: media.folder) }
        let svg = try write("pulse.svg", Self.svg)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .video(let file, _)? = ViewerContent.make(Attachment(url: movie), pending: true) else {
            Issue.record("a video opens in the player")
            return
        }
        #expect(file.url == movie && file.size > 0)
        guard case .image(let vector)? = ViewerContent.make(Attachment(url: svg), pending: true) else {
            Issue.record("an SVG opens as a picture")
            return
        }
        #expect(vector.vector?.url == svg && !vector.markable && vector.pendingID != nil)
        let png = folder.appendingPathComponent("dot.png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(rep?.representation(using: .png, properties: [:])).write(to: png)
        guard case .image(let raster)? = ViewerContent.make(Attachment(url: png), pending: false) else {
            Issue.record("a PNG opens as a picture")
            return
        }
        #expect(raster.vector == nil && raster.markable)
    }

    @Test func videoAndSVGChipsGetAPosterOnce() async throws {
        let media = AttachedMediaTests()
        let movie = try await media.movie()
        defer { try? FileManager.default.removeItem(at: media.folder) }
        let svg = try write("pulse.svg", Self.svg)
        defer { try? FileManager.default.removeItem(at: folder) }

        let clip = Attachment(url: movie)
        let poster = try #require(clip.poster)
        #expect(poster.video && clip.thumbnail == nil && !clip.showsPicture)
        poster.make()
        try await until { poster.image != nil }
        let frame = try #require(poster.image)
        #expect(max(frame.size.width, frame.size.height) <= CGFloat(Thumbnail.maxPixels))
        poster.make()
        #expect(poster.image === frame, "made once")
        #expect(clip.showsPicture)

        let drawing = Attachment(url: svg)
        let drawn = try #require(drawing.poster)
        #expect(!drawn.video && drawing.kind == .image)
        drawn.make()
        try await until { drawn.image != nil }
        #expect(drawn.image?.size == CGSize(width: Thumbnail.maxPixels, height: 117))
    }

    @Test func aVideoCanBeSavedAs() async throws {
        let media = AttachedMediaTests()
        let movie = try await media.movie()
        defer { try? FileManager.default.removeItem(at: media.folder) }
        let titles = MediaMenu.items(.init(url: movie), openInKore: {}).filter { !$0.separator }.map(\.title)
        #expect(titles == ["Copy File", "Copy Path", "Save As…", "Open", "Open with Default App", "Reveal in Finder"])
    }
}
