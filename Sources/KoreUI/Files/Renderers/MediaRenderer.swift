import AVFoundation
import AVKit
import SwiftUI

/// Audio and video in AVKit's player (VS Code's media preview): video fitted with the inline
/// controls; audio as its name over the controls. It never plays on its own, pauses when the
/// tab is left, and comes back at the same time.
struct MediaFileView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var player = Local<AVPlayer?>(nil)
    @StateObject private var state = Local(MediaState.loading)
    /// The video's own size (points), which it's never scaled past.
    @StateObject private var natural = Local<CGSize?>(nil)
    @StateObject private var duration = Local<String?>(nil)
    private var url: URL { file.url }

    enum MediaState { case loading, video, audio, failed }

    var body: some View {
        ZStack {
            switch state.value {
            case .loading:
                RendererLoading()
            case .failed:
                RendererState.cantRender(file, reason: "Its format isn't one macOS plays.", context: context, hasRaw: false)
            case .video:
                if let player = player.value {
                    PlayerHost(player: player)
                        .frame(maxWidth: natural.value?.width ?? .infinity, maxHeight: natural.value?.height ?? .infinity)
                }
            case .audio:
                if let player = player.value {
                    VStack(spacing: Size.Media.audioGlyphGap) {
                        Image(systemName: "waveform").font(Chrome.glyphMedia).foregroundStyle(Theme.tertiary)
                        Text(url.lastPathComponent).font(Chrome.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                        if let duration = duration.value {
                            Text(duration).font(Chrome.labelDigits).foregroundStyle(Theme.secondary)
                        }
                        PlayerHost(player: player)
                            .frame(maxWidth: Size.Media.audioControlsWidth)
                            .frame(height: Size.Media.audioControls)
                    }
                    .padding(.horizontal, Space.xxxl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: context.reloadToken) { await load() }
        .onDisappear {
            if let player = player.value {
                positions[url] = player.currentTime()
                player.pause()
            }
            player.value = nil
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else {
            state.value = .failed
            return
        }
        let track = (try? await asset.loadTracks(withMediaType: .video))?.first
        let video = track != nil
        if let track, let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let turned = size.applying(transform)
            natural.value = CGSize(width: abs(turned.width), height: abs(turned.height))
        }
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        duration.value = seconds.isFinite && seconds > 0 ? Self.clock(seconds) : nil
        var facts = [duration.value, FileEditorView.size(Int(file.size))].compactMap { $0 }
        if let size = natural.value { facts.insert("\(Int(size.width)) × \(Int(size.height))", at: 0) }
        context.setFacts(facts)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        if let time = positions[url] { await player.seek(to: time) }
        self.player.value?.pause()
        self.player.value = player
        state.value = video ? .video : .audio
        RenderTiming.ready(MediaRenderer.id)
    }

    /// 0:42, 3:07, 1:02:09.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Where each file was left, for coming back to its tab.
@MainActor private var positions: [URL: CMTime] = [:]

private struct PlayerHost: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

enum MediaRenderer: FileRenderer {
    static let id = "media"
    static let hasRaw = false

    static func matches(_ file: FileInfo) -> Bool { file.conforms(to: .audiovisualContent) }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(MediaFileView(file: file, context: context))
    }
}
