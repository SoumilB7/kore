import AVFoundation
import AVKit
import AppKit
import KoreUI
import WebKit

/// An animated SVG plays, as vectors in a web view: in its file tab, then from a composer chip in
/// the chat's viewer. Each time, two pictures of it half a second apart differ.
final class AnimatedSVGPlays: ChatStoryline {
    override class var tags: Set<Tag> { [.files, .chat] }

    static let path = "art/pulse.svg"
    static let name = "pulse.svg"
    static let text = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
          <rect x="4" y="20" width="40" height="40" fill="#e5484d">
            <animate attributeName="x" values="4;76;4" dur="1s" repeatCount="indefinite"/>
          </rect>
        </svg>
        """

    override func steps() -> [any Step] {
        [WriteFiles([(Self.path, Self.text)])] + super.steps()
            + FileTabState.open(Self.path) + [
                Expect("the SVG in the SVG renderer") { $0.app.workspace?.storyActiveRenderer == "svg" },
                SVGPlays(where: "its tab", shot: "svg-tab-page"),
                ShowChatTab(),
                ExpectElement(.id(StoryID.Viewer.svg), .absent),
                Do("Attach the SVG") { story in
                    try story.activeChat().storyAttach([story.folder.appendingPathComponent(Self.path)])
                },
                Expect("its chip to show it") { try $0.activeChat().storyChipShowsPicture(Self.name) },
                Press(.id(StoryID.Composer.attachment(Self.name))),
                SVGPlays(where: "the chat's viewer", shot: "svg-viewer-page"),
                Key(.escape),
                ExpectElement(.id(StoryID.Viewer.svg), .absent),
            ]
    }
}

/// A one-second video attached: its chip shows its first frame; opened, AVKit's player shows it,
/// paused. Sent, the message's chip opens it the same way.
final class VideoAttachmentOpens: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    static let name = "clip.mov"

    override func steps() -> [any Step] {
        super.steps() + [
            WriteVideo(Self.name),
            Do("Attach the video") { story in
                try story.activeChat().storyAttach([story.folder.appendingPathComponent(Self.name)])
            },
            Expect("its chip to show its first frame") { try $0.activeChat().storyChipShowsPicture(Self.name) },
            Snapshot("video-chip"),
            Press(.id(StoryID.Composer.attachment(Self.name))),
            PlayerPaused(),
            Snapshot("video-viewer"),
            Key(.escape),
            ExpectElement(.id(StoryID.Viewer.player), .absent),
            Send("What happens in this clip"), TurnFinished(1),
            Expect("the message's chip to show its first frame") { try $0.activeChat().storyChipShowsPicture(Self.name, sent: true) },
            Press(.id(StoryID.Transcript.attachment(Self.name))),
            PlayerPaused(),
            Press(.id(StoryID.Viewer.close)),
            ExpectElement(.id(StoryID.Viewer.player), .absent),
        ]
    }
}

/// Back to the chat's tab, the first.
private struct ShowChatTab: Step {
    var label: String { "Show the chat's tab" }

    func run(_ story: StoryContext) async throws {
        story.app.workspace?.storySelect(tabAt: 0)
        try await story.until("the chat's tab to be the active one") {
            story.app.workspace.map { !$0.tabs.isEmpty && $0.activeTab === $0.tabs[0] } ?? false
        }
    }
}

/// The SVG's web view is up, has drawn, and draws something else half a second later. The
/// second picture is saved as `<shot>.png` (the window's snapshot can't see into a web view).
private struct SVGPlays: Step {
    let place: String
    let shot: String
    init(where place: String, shot: String) {
        self.place = place
        self.shot = shot
    }
    var label: String { "The SVG plays in \(place)" }
    var timeout: Duration? { .seconds(15) }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(.id(StoryID.Viewer.svg))
        guard let view = element.registeredView as? WKWebView else { throw StoryFailure.other("the SVG isn't in a web view") }
        // WebKit pauses animation in a covered window, as it should; the storyline's window may
        // be under the owner's.
        if view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        for _ in 0..<20 {
            if let first = await Self.picture(view), first.inked {
                try await Task.sleep(for: .milliseconds(500))
                if let second = await Self.picture(view), second.inked, second.bytes != first.bytes {
                    let png = NSBitmapImageRep(cgImage: second.image).representation(using: .png, properties: [:])
                    try? png?.write(to: story.outputs.appendingPathComponent(shot + ".png"))
                    return
                }
            } else {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw StoryFailure.expectation("the SVG in \(place) to change over half a second")
    }

    private struct Picture {
        let image: CGImage
        let bytes: Data
        /// Something is drawn (the page is transparent where the SVG isn't).
        let inked: Bool
    }

    @MainActor private static func picture(_ view: WKWebView) async -> Picture? {
        guard view.window != nil, let image = try? await view.takeSnapshot(configuration: nil),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = cg.dataProvider?.data as Data?
        else { return nil }
        let alpha = cg.alphaInfo
        let offset = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst ? 0 : 3
        let step = cg.bitsPerPixel / 8
        var inked = false
        if step == 4 {
            var index = offset
            while index < data.count {
                if data[index] != 0 { inked = true; break }
                index += step
            }
        } else {
            inked = data.contains { $0 != 0 }
        }
        return Picture(image: cg, bytes: data, inked: inked)
    }
}

/// AVKit's player is up with the video in it, not playing.
private struct PlayerPaused: Step {
    var label: String { "The player shows the video, paused" }
    var timeout: Duration? { .seconds(15) }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(.id(StoryID.Viewer.player))
        guard let view = element.registeredView as? AVPlayerView else { throw StoryFailure.other("no AVKit player") }
        try await story.until("the player to have the video, paused") {
            guard let player = view.player, let item = player.currentItem else { return false }
            return item.status == .readyToPlay && player.rate == 0 && player.timeControlStatus == .paused
        }
    }
}

/// A one-second H.264 movie, 64 × 48, ten frames of changing colour, written into the folder.
private struct WriteVideo: Step {
    let name: String
    init(_ name: String) { self.name = name }
    var label: String { "Write a one-second video, \(name)" }

    func run(_ story: StoryContext) async throws {
        try await Self.write(story.folder.appendingPathComponent(name))
    }

    nonisolated static func write(_ url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
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
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw StoryFailure.other("the video writer has no buffers") }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixels = buffer else { throw StoryFailure.other("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 + frame * 20), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw StoryFailure.other("the video wasn't written") }
    }
}
