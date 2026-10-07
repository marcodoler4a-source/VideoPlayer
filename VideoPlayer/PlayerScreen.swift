import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

struct PlayerScreen: View {
  let item: VideoItem
  let url: URL
  let autoPlay: Bool
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
  @State private var volume: Double = 1
  @State private var videoScale: CGFloat = 1
  @State private var fillVideo = false
  @State private var showEditor = false

  init(item: VideoItem, url: URL, autoPlay: Bool = true, onClose: @escaping (Double) -> Void) {
    self.item = item
    self.url = url
    self.autoPlay = autoPlay
    self.onClose = onClose
    _player = State(initialValue: AVPlayer(url: url))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VideoPlayer(player: player)
        .aspectRatio(contentMode: fillVideo ? .fill : .fit)
        .scaleEffect(videoScale)
        .clipped().ignoresSafeArea()
        .onTapGesture { withAnimation { controls.toggle() } }
      if subtitlesEnabled, let cue = activeSubtitle {
        VStack {
          Spacer()
          Text(cue.text).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).background(
              .black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8)
            ).padding(.horizontal, 24).padding(.bottom, controls ? 150 : 34)
        }.allowsHitTesting(false)
      }
      if controls { controlsView }
    }
    .statusBarHidden()
    .onAppear { setup() }
    .onDisappear { cleanup() }
    .fileImporter(
      isPresented: $importingSubtitle,
      allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let u = urls.first else { return }
      loadSubtitle(from: u)
    }
    .sheet(isPresented: $showEditor) { VideoEditorView(url: url) }
  }

  private var controlsView: some View {
    VStack {
      HStack {
        Button {
          close()
        } label: {
          Image(systemName: "xmark").font(.title3).padding(12).background(
            .ultraThinMaterial, in: Circle())
        }
        Spacer()
        Menu {
          Button {
            importingSubtitle = true
          } label: {
            Label("Add Subtitle", systemImage: "captions.bubble")
          }
          if !subtitleCues.isEmpty {
            Button {
              subtitlesEnabled.toggle()
            } label: {
              Label(
                subtitlesEnabled ? "Turn Subtitles Off" : "Turn Subtitles On",
                systemImage: "captions.bubble")
            }
            Button(role: .destructive) {
              subtitleCues = []
              subtitleName = nil
            } label: {
              Label("Remove Subtitle", systemImage: "trash")
            }
          }
        } label: {
          Image(systemName: subtitleCues.isEmpty ? "captions.bubble" : "captions.bubble.fill")
            .padding(12).background(.ultraThinMaterial, in: Circle())
        }
        Menu {
          Button {
            requestOrientation(.portrait)
          } label: {
            Label("Portrait", systemImage: "iphone")
          }
          Button {
            requestOrientation(.landscapeRight)
          } label: {
            Label("Landscape", systemImage: "iphone.landscape")
          }
          Divider()
          Button {
            fillVideo = false
            videoScale = 1
          } label: {
            Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
          }
          Button {
            fillVideo = true
            videoScale = 1
          } label: {
            Label("Fill", systemImage: "arrow.up.left.and.arrow.down.right")
          }
          Divider()
          Button {
            showEditor = true
          } label: {
            Label("Edit Video", systemImage: "slider.horizontal.3")
          }
        } label: {
          Image(systemName: "ellipsis.circle").font(.title2).padding(8).background(
            .ultraThinMaterial, in: Circle())
        }
        Menu {
          ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
            Button("\(speed, specifier: "%g")×") {
              rate = Float(speed)
              if playing { player.rate = rate }
            }
          }
        } label: {
          Text("\(Double(rate), specifier: "%g")×").padding(.horizontal, 12).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
      }.padding()
      Spacer()
      HStack(spacing: 38) {
        Button {
          seek(by: -10)
        } label: {
          Image(systemName: "gobackward.10").font(.system(size: 34))
        }
        Button {
          toggle()
        } label: {
          Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 48)).frame(
            width: 70)
        }
        Button {
          seek(by: 10)
        } label: {
          Image(systemName: "goforward.10").font(.system(size: 34))
        }
      }.foregroundStyle(.white)
      Spacer()
      VStack(spacing: 9) {
        HStack(spacing: 10) {
          Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
          Slider(value: $volume, in: 0...1).onChange(of: volume) { player.volume = Float($0) }
        }
        HStack(spacing: 10) {
          Image(systemName: "rectangle.expand.vertical")
          Slider(value: $videoScale, in: 0.7...2.0)
          Text("\(Int(videoScale * 100))%").font(.caption.monospacedDigit()).frame(width: 42)
        }
        Slider(
          value: Binding(
            get: { current },
            set: {
              current = $0
              player.seek(to: CMTime(seconds: $0, preferredTimescale: 600))
            }), in: 0...max(duration, 1))
        HStack {
          Text(format(current))
          Spacer()
          Text("-" + format(max(duration - current, 0)))
        }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
      }.padding().background(.ultraThinMaterial)
    }.foregroundStyle(.white).transition(.opacity)
  }

  private var activeSubtitle: SubtitleCue? {
    subtitleCues.first { current >= $0.start && current <= $0.end }
  }
  private func loadSubtitle(from source: URL) {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: source) else { return }
    let text =
      String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    let parsed = SRTParser.parse(text)
    guard !parsed.isEmpty else { return }
    subtitleCues = parsed
    subtitleName = source.lastPathComponent
    subtitlesEnabled = true
  }
  private func setup() {
    if item.lastPosition > 1 {
      player.seek(to: CMTime(seconds: item.lastPosition, preferredTimescale: 600))
    }
    Task {
      if let d = try? await player.currentItem?.asset.load(.duration).seconds, d.isFinite {
        duration = d
      }
    }
    observer = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { time in current = time.seconds.isFinite ? time.seconds : 0 }
    player.volume = Float(volume)
    if autoPlay {
      player.play()
      player.rate = rate
      playing = true
    }
  }
  private func toggle() {
    if playing {
      player.pause()
    } else {
      player.play()
      player.rate = rate
    }
    playing.toggle()
  }
  private func seek(by delta: Double) {
    let t = min(max(current + delta, 0), duration)
    player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
  }
  private func close() {
    onClose(current)
    player.pause()
    requestOrientation(.portrait)
    dismiss()
  }
  private func cleanup() {
    onClose(current)
    player.pause()
    if let observer {
      player.removeTimeObserver(observer)
      self.observer = nil
    }
  }
  private func format(_ seconds: Double) -> String {
    let s = max(Int(seconds), 0)
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
      : String(format: "%d:%02d", s / 60, s % 60)
  }
  private func requestOrientation(_ orientation: UIInterfaceOrientation) {
    guard
      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }
    let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscape : .portrait
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
  }
}

struct VideoEditorView: View {
  let url: URL
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer
  @State private var duration: Double = 1
  @State private var trimStart: Double = 0
  @State private var trimEnd: Double = 1
  @State private var crop: CropPreset = .original
  @State private var filter: FilterPreset = .none
  @State private var overlayText = ""
  @State private var exporting = false
  @State private var exportURL: URL?
  @State private var errorMessage: String?

  init(url: URL) {
    self.url = url
    _player = State(initialValue: AVPlayer(url: url))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Preview") {
          VideoPlayer(player: player).frame(height: 220).listRowInsets(EdgeInsets())
        }
        Section("Trim") {
          HStack {
            Text("Start")
            Slider(value: $trimStart, in: 0...max(trimEnd - 0.1, 0.1))
            Text(time(trimStart)).monospacedDigit()
          }
          HStack {
            Text("End")
            Slider(value: $trimEnd, in: min(trimStart + 0.1, duration)...max(duration, 1))
            Text(time(trimEnd)).monospacedDigit()
          }
        }
        Section("Crop") {
          Picker("Crop", selection: $crop) {
            ForEach(CropPreset.allCases) { Text($0.rawValue).tag($0) }
          }
        }
        Section("Filter") {
          Picker("Filter", selection: $filter) {
            ForEach(FilterPreset.allCases) { Text($0.rawValue).tag($0) }
          }
        }
        Section("Text") { TextField("Add text to video", text: $overlayText) }
        Section {
          Button {
            exportEditedVideo()
          } label: {
            HStack {
              Spacer()
              if exporting { ProgressView().padding(.trailing, 8) }
              Text(exporting ? "Exporting…" : "Save Edited Video")
              Spacer()
            }
          }.disabled(exporting)
        }
        if let exportURL {
          Section("Finished") {
            ShareLink(item: exportURL) {
              Label("Share / Save Edited Video", systemImage: "square.and.arrow.up")
            }
            Text(exportURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Edit Video").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
      .task {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration).seconds) ?? 1
        duration = max(d, 0.1)
        trimEnd = duration
      }
      .alert(
        "Edit Failed",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Unknown error")
      }
    }
  }

  private func exportEditedVideo() {
    exporting = true
    exportURL = nil
    Task {
      do {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let range = CMTimeRange(
          start: CMTime(seconds: trimStart, preferredTimescale: 600),
          duration: CMTime(seconds: max(trimEnd - trimStart, 0.1), preferredTimescale: 600))
        if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
          let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
          videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
          let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
        var videoComposition: AVVideoComposition?
        if filter != .none || crop != .original
          || !overlayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          let base = AVVideoComposition(asset: composition) { request in
            var image = request.sourceImage.clampedToExtent()
            image = filter.apply(to: image)
            if crop != .original {
              let rect = crop.rect(in: image.extent)
              image = image.cropped(to: rect).transformed(
                by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            }
            request.finish(with: image.cropped(to: image.extent), context: nil)
          }
          if !overlayText.isEmpty {
            guard let mutableBase = base.mutableCopy() as? AVMutableVideoComposition else {
              throw NSError(
                domain: "VideoEditor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to prepare the text overlay composition."]
              )
            }

            let parent = CALayer()
            let videoLayer = CALayer()
            let textLayer = CATextLayer()
            parent.frame = CGRect(origin: .zero, size: mutableBase.renderSize)
            videoLayer.frame = parent.frame
            textLayer.string = overlayText
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
            textLayer.alignmentMode = .center
            textLayer.fontSize = 36
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.frame = CGRect(
              x: 30,
              y: 40,
              width: max(mutableBase.renderSize.width - 60, 100),
              height: 60
            )
            parent.addSublayer(videoLayer)
            parent.addSublayer(textLayer)
            mutableBase.animationTool = AVVideoCompositionCoreAnimationTool(
              postProcessingAsVideoLayer: videoLayer,
              in: parent
            )
            videoComposition = mutableBase
          } else {
            videoComposition = base
          }
        }
        guard
          let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
          throw NSError(
            domain: "VideoEditor", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to create exporter."])
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(
          "Edited-\(UUID().uuidString).mp4")
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        await exporter.export()
        if exporter.status == .completed {
          exportURL = out
        } else {
          throw exporter.error
            ?? NSError(
              domain: "VideoEditor", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Export failed."])
        }
      } catch { errorMessage = error.localizedDescription }
      exporting = false
    }
  }
  private func time(_ s: Double) -> String {
    let v = max(Int(s), 0)
    return String(format: "%d:%02d", v / 60, v % 60)
  }
}

enum CropPreset: String, CaseIterable, Identifiable {
  case original = "Original"
  case square = "Square 1:1"
  case portrait = "Portrait 9:16"
  case landscape = "Landscape 16:9"
  var id: String { rawValue }
  func rect(in extent: CGRect) -> CGRect {
    let ratio: CGFloat =
      self == .square
      ? 1 : self == .portrait ? 9 / 16 : self == .landscape ? 16 / 9 : extent.width / extent.height
    let current = extent.width / extent.height
    if current > ratio {
      let w = extent.height * ratio
      return CGRect(x: extent.midX - w / 2, y: extent.minY, width: w, height: extent.height)
    } else {
      let h = extent.width / ratio
      return CGRect(x: extent.minX, y: extent.midY - h / 2, width: extent.width, height: h)
    }
  }
}
enum FilterPreset: String, CaseIterable, Identifiable {
  case none = "None"
  case mono = "Mono"
  case noir = "Noir"
  case vivid = "Vivid"
  case warm = "Warm"
  case cool = "Cool"
  var id: String { rawValue }
  func apply(to image: CIImage) -> CIImage {
    switch self {
    case .none: return image
    case .mono:
      let f = CIFilter.photoEffectMono()
      f.inputImage = image
      return f.outputImage ?? image
    case .noir:
      let f = CIFilter.photoEffectNoir()
      f.inputImage = image
      return f.outputImage ?? image
    case .vivid:
      let f = CIFilter.colorControls()
      f.inputImage = image
      f.saturation = 1.35
      f.contrast = 1.12
      return f.outputImage ?? image
    case .warm:
      let f = CIFilter.temperatureAndTint()
      f.inputImage = image
      f.neutral = CIVector(x: 6500, y: 0)
      f.targetNeutral = CIVector(x: 5000, y: 0)
      return f.outputImage ?? image
    case .cool:
      let f = CIFilter.temperatureAndTint()
      f.inputImage = image
      f.neutral = CIVector(x: 6500, y: 0)
      f.targetNeutral = CIVector(x: 8000, y: 0)
      return f.outputImage ?? image
    }
  }
}

extension UIWindowScene {
  fileprivate var keyWindow: UIWindow? { windows.first(where: \.isKeyWindow) }
}
