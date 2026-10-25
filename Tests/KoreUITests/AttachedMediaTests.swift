import AVFoundation
import AppKit
import Foundation
import KoreCore
import Testing

@testable import KoreUI

@Suite("Video, audio and other files attached")
struct AttachedMediaTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-media-\(UUID().uuidString)")

    /// A plain 8-second H.264 movie, 64×48, one colour a second.
    func movie() async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for second in 0...7 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(second * 30), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func aVideoGoesAsFramesAndALineNeverAsItsPath() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = Attachments.File(url: url, name: "clip.mov", kind: Attachments.kind(of: url))
        #expect(file.kind == .other && AttachedMedia.kind(of: url).video)
        let media = await AttachedMedia.read([file])
        let read = try #require(media[url])
        #expect(read.frames.count == 3)
        #expect(read.note == "[video: \(url.path), 0:08, 3 frames from it attached]", "\(read.note)")
        let claude = try #require(Attachments.claudeContent(text: "What's wrong here?", files: [file], folder: folder, media: media).array)
        #expect(claude.filter { $0["type"]?.string == "image" }.count == 3)
        let text = claude.last?["text"]?.string ?? ""
        #expect(text.contains("[video: ") && !text.contains("@"))
        let codex = try #require(Attachments.codexInput(text: "What's wrong here?", files: [file], media: media).array)
        #expect(codex.filter { $0["type"]?.string == "localImage" }.count == 3)
        #expect(Attachments.isFileNote(codex.last?["text"]?.string ?? ""))
    }

    @Test func aBinaryIsNamedAndAFolderIsPointedAt() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src/"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("data.sqlite")
        try Data([0, 1, 2]).write(to: binary)
        let files = [
            Attachments.File(url: binary, name: "data.sqlite", kind: .other),
            Attachments.File(url: folder.appendingPathComponent("src/"), name: "src", kind: .other),
        ]
        let text = Attachments.claudeContent(text: "Look", files: files, folder: folder).array?.last?["text"]?.string ?? ""
        #expect(text.contains("[file: \(binary.path)]") && text.contains("@src") && !text.contains("@data.sqlite"), "\(text)")
    }

    @Test func lengthsReadAsAClock() {
        #expect(AttachedMedia.clock(42) == "0:42")
        #expect(AttachedMedia.clock(3909) == "1:05:09")
    }
}
