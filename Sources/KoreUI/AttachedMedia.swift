import AVFoundation
import AppKit
import KoreCore
import UniformTypeIdentifiers

/// A video or audio file attached to a message, as the model is given it: no CLI reads one
/// itself (Claude's, asked to read a screen recording by its path, hung mid-turn). A video goes
/// as a few frames, about one every 3 s and at most `maxFrames`, scaled as any image is, with a
/// line saying what they are; audio as the line alone.
struct AttachedMedia: Sendable {
    /// "[video: /path/clip.mov, 0:42, 8 frames]"; "[audio: /path/memo.m4a, 1:05]".
    let note: String
    /// The frames, as JPEG files in a folder of Kore's own (Codex takes images by path).
    let frames: [URL]

    static let maxFrames = 8
    static let secondsPerFrame = 3.0

    /// Whether `url` is a video or audio file (by its type), and which.
    static func kind(of url: URL) -> (video: Bool, audio: Bool) {
        guard !url.hasDirectoryPath, let type = UTType(filenameExtension: url.pathExtension) else { return (false, false) }
        return (type.conforms(to: .movie), !type.conforms(to: .movie) && type.conforms(to: .audio))
    }

    /// The media among `files`, read: nothing for the rest.
    static func read(_ files: [Attachments.File]) async -> [URL: AttachedMedia] {
        var media: [URL: AttachedMedia] = [:]
        for file in files where file.kind == .other {
            let kind = kind(of: file.url)
            guard kind.video || kind.audio else { continue }
            media[file.url] = await read(file.url, video: kind.video)
        }
        return media
    }

    static func read(_ url: URL, video: Bool) async -> AttachedMedia {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let length = seconds.map(Self.clock)
        guard video else { return AttachedMedia(note: "[audio: \(url.path)" + (length.map { ", \($0)" } ?? "") + "]", frames: []) }
        var frames: [URL] = []
        if let seconds {
            let count = min(maxFrames, max(1, Int((seconds / secondsPerFrame).rounded(.up))))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: ImageFit.maxSide, height: ImageFit.maxSide)
            let tolerance = CMTime(seconds: min(1, seconds / Double(count) / 2), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-frames/\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<count {
                let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
                guard let (image, _) = try? await generator.image(at: time),
                    let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
                    let fitted = ImageFit.fit(jpeg, mediaType: "image/jpeg")
                else { continue }
                let file = folder.appendingPathComponent(String(format: "frame-%02d.jpg", index + 1))
                guard (try? fitted.data.write(to: file)) != nil else { continue }
                frames.append(file)
            }
        }
        var parts = ["[video: \(url.path)"]
        if let length { parts.append(length) }
        parts.append(frames.isEmpty ? "no frames could be read" : "\(frames.count) \(frames.count == 1 ? "frame" : "frames") from it attached")
        return AttachedMedia(note: parts.joined(separator: ", ") + "]", frames: frames)
    }

    /// "0:42", "1:05:09".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
