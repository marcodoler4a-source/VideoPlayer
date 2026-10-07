import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct PlayerScreen: View {
    let item: VideoItem
    let url: URL
    let onClose: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var current: Double = 0
    @State private var duration: Double = 1
    @State private var playing = false
    @State private var controls = true
    @State private var rate: Float = 1
    @State private var observer: Any?
    @State private var importingSubtitle = false
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var subtitleName: String?
    @State private var subtitlesEnabled = true

    init(item: VideoItem, url: URL, onClose: @escaping (Double) -> Void) {
        self.item = item; self.url = url; self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea().onTapGesture { withAnimation { controls.toggle() } }
            if subtitlesEnabled, let cue = activeSubtitle {
                VStack {
                    Spacer()
                    Text(cue.text)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, controls ? 105 : 34)
                }
                .allowsHitTesting(false)
            }
            if controls {
                VStack {
                    HStack {
                        Button { close() } label: { Image(systemName: "xmark").font(.title3).padding(12).background(.ultraThinMaterial, in: Circle()) }
                        Spacer()
                        HStack(spacing: 10) {
                            Menu {
                                Button { importingSubtitle = true } label: { Label("Add SRT Subtitle", systemImage: "captions.bubble") }
                                if !subtitleCues.isEmpty {
                                    Button { subtitlesEnabled.toggle() } label: { Label(subtitlesEnabled ? "Turn Subtitles Off" : "Turn Subtitles On", systemImage: subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble") }
                                    Button(role: .destructive) { subtitleCues = []; subtitleName = nil } label: { Label("Remove Subtitle", systemImage: "trash") }
                                }
                            } label: {
                                Image(systemName: subtitleCues.isEmpty ? "captions.bubble" : "captions.bubble.fill")
                                    .padding(12).background(.ultraThinMaterial, in: Circle())
                            }
                            Menu {
                                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                                    Button("\(speed, specifier: "%g")×") { rate = Float(speed); if playing { player.rate = rate } }
                                }
                            } label: { Text("\(Double(rate), specifier: "%g")×").padding(.horizontal, 14).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()) }
                        }
                    }.padding()
                    Spacer()
                    HStack(spacing: 38) {
                        Button { seek(by: -10) } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                        Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 48)).frame(width: 70) }
                        Button { seek(by: 10) } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
                    }.foregroundStyle(.white)
                    Spacer()
                    VStack(spacing: 8) {
                        Slider(value: Binding(get: { current }, set: { value in current = value; player.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }), in: 0...max(duration, 1))
                        HStack { Text(format(current)); Spacer(); Text("-" + format(max(duration-current, 0))) }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }.padding().background(.ultraThinMaterial)
                }.foregroundStyle(.white).transition(.opacity)
            }
        }
        .statusBarHidden()
        .onAppear { setup() }
        .onDisappear { cleanup() }
        .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let subtitleURL = urls.first else { return }
            loadSubtitle(from: subtitleURL)
        }
    }

    private var activeSubtitle: SubtitleCue? {
        subtitleCues.first { current >= $0.start && current <= $0.end }
    }

    private func loadSubtitle(from source: URL) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else { return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let parsed = SRTParser.parse(text)
        guard !parsed.isEmpty else { return }
        subtitleCues = parsed
        subtitleName = source.lastPathComponent
        subtitlesEnabled = true
    }

    private func setup() {
        if item.lastPosition > 1 { player.seek(to: CMTime(seconds: item.lastPosition, preferredTimescale: 600)) }
        Task { if let d = try? await player.currentItem?.asset.load(.duration).seconds, d.isFinite { duration = d } }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in current = time.seconds.isFinite ? time.seconds : 0 }
        player.play(); player.rate = rate; playing = true
    }
    private func toggle() { if playing { player.pause() } else { player.play(); player.rate = rate }; playing.toggle() }
    private func seek(by delta: Double) { let target = min(max(current + delta, 0), duration); player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) }
    private func close() { onClose(current); player.pause(); dismiss() }
    private func cleanup() { onClose(current); player.pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil } }
    private func format(_ seconds: Double) -> String { let s = max(Int(seconds),0); return s >= 3600 ? String(format:"%d:%02d:%02d",s/3600,(s%3600)/60,s%60) : String(format:"%d:%02d",s/60,s%60) }
}
