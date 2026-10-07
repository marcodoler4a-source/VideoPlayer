import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import Vision


struct SystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  let fillVideo: Bool
  @Binding var videoScale: CGFloat

  func makeCoordinator() -> Coordinator {
    Coordinator(videoScale: $videoScale)
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect

    let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
    pinch.cancelsTouchesInView = false
    pinch.delegate = context.coordinator
    controller.view.addGestureRecognizer(pinch)
    context.coordinator.controller = controller
    context.coordinator.applyScale(videoScale)
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    controller.player = player
    controller.showsPlaybackControls = true
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect
    context.coordinator.controller = controller
    context.coordinator.applyScale(videoScale)
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    @Binding var videoScale: CGFloat
    weak var controller: AVPlayerViewController?
    private var scaleAtPinchStart: CGFloat = 1

    init(videoScale: Binding<CGFloat>) {
      _videoScale = videoScale
      super.init()
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began:
        scaleAtPinchStart = videoScale
      case .changed, .ended:
        let proposed = scaleAtPinchStart * recognizer.scale
        videoScale = min(max(proposed, 0.65), 2.5)
        applyScale(videoScale)
      default:
        break
      }
    }

    func applyScale(_ scale: CGFloat) {
      guard let view = controller?.contentOverlayView ?? controller?.view else { return }
      // Scale only the video presentation container while leaving Apple's playback controls usable.
      // AVPlayerViewController redraws its controls above this transform as they appear/disappear.
      controller?.view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

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

      SystemPlayerView(player: player, fillVideo: fillVideo, videoScale: $videoScale)
        .clipped()
        .ignoresSafeArea()

      if subtitlesEnabled, let cue = activeSubtitle {
        VStack {
          Spacer()
          Text(cue.text)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, controls ? 86 : 28)
        }
        .allowsHitTesting(false)
      }

      if controls {
        controlsView
          .transition(.opacity)
      }
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
    .sheet(isPresented: $showEditor) {
      VideoEditorView(url: url)
    }
  }

  private var controlsView: some View {
    VStack {
      HStack {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }

        Spacer()
      }
      .padding(.top, 10)
      .padding(.horizontal, 14)

      Spacer()

      HStack {
        Spacer()
        Menu {
          Section("Subtitles") {
            Button { importingSubtitle = true } label: {
              Label("Add Subtitle", systemImage: "captions.bubble")
            }
            if !subtitleCues.isEmpty {
              Button { subtitlesEnabled.toggle() } label: {
                Label(
                  subtitlesEnabled ? "Turn Subtitles Off" : "Turn Subtitles On",
                  systemImage: subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble"
                )
              }
              Button(role: .destructive) {
                subtitleCues.removeAll()
                subtitleName = nil
              } label: {
                Label("Remove Subtitle", systemImage: "trash")
              }
            }
          }

          Section("Display") {
            Button("Fit Video") { fillVideo = false; videoScale = 1 }
            Button("Fill Screen") { fillVideo = true; videoScale = 1 }
            Button("Reset Pinch Zoom") { videoScale = 1; fillVideo = false }
            Button { rotateVideo() } label: {
              Label("Rotate", systemImage: "rotate.right")
            }
          }

          Section("Playback") {
            Menu("Playback Speed") {
              ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                Button("\(speed, specifier: "%g")×") {
                  rate = Float(speed)
                  if player.timeControlStatus == .playing { player.rate = rate }
                }
              }
            }
            Menu("Volume") {
              Button("100%") { setVolume(1) }
              Button("75%") { setVolume(0.75) }
              Button("50%") { setVolume(0.5) }
              Button("25%") { setVolume(0.25) }
              Button(volume == 0 ? "Unmute" : "Mute") { setVolume(volume == 0 ? 1 : 0) }
            }
          }

          Section("Editing") {
            Button { showEditor = true } label: {
              Label("Edit Video", systemImage: "slider.horizontal.3")
            }
          }

          Section("Picture in Picture") {
            Text("Start the video, then leave the app. iPhone will automatically use Picture in Picture when available.")
          }
        } label: {
          Image(systemName: "wrench.and.screwdriver.fill")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
      }
      .padding(.trailing, 12)
      .padding(.bottom, 120)
    }
    .foregroundStyle(.white)
  }

  private func toolIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 18, weight: .semibold))
      .frame(width: 46, height: 46)
      .background(.ultraThinMaterial, in: Circle())
  }

  private func setVolume(_ value: Double) {
    volume = min(max(value, 0), 1)
    player.volume = Float(volume)
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
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("Audio session setup failed: \(error.localizedDescription)")
    }
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
  private func rotateVideo() {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    let isLandscape = scene.interfaceOrientation.isLandscape
    requestOrientation(isLandscape ? .portrait : .landscapeRight)
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
  @State private var detectedTextRegions: [DetectedTextRegion] = []
  @State private var eraseTextRegions: [DetectedTextRegion] = []
  @State private var detectingEmbeddedText = false

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
        Section("Text") {
          TextField("Add text to video", text: $overlayText)
          if !overlayText.isEmpty {
            Button(role: .destructive) {
              overlayText = ""
            } label: {
              Label("Remove Added Text", systemImage: "eraser")
            }
          }
        }

        Section("Erase Embedded Text") {
          Text("Detect text that is already burned into the video, then choose which text areas to erase. The erased background is reconstructed approximately from nearby pixels.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            detectEmbeddedText()
          } label: {
            HStack {
              if detectingEmbeddedText { ProgressView().padding(.trailing, 6) }
              Label(detectingEmbeddedText ? "Detecting…" : "Detect Text at Start Time", systemImage: "viewfinder")
            }
          }
          .disabled(detectingEmbeddedText)

          if !detectedTextRegions.isEmpty {
            ForEach(detectedTextRegions) { region in
              Button {
                if !eraseTextRegions.contains(where: { $0.id == region.id }) {
                  eraseTextRegions.append(region)
                }
              } label: {
                HStack {
                  Image(systemName: eraseTextRegions.contains(where: { $0.id == region.id }) ? "checkmark.circle.fill" : "circle")
                  Text(region.text.isEmpty ? "Detected text area" : region.text)
                    .lineLimit(1)
                  Spacer()
                  Image(systemName: "eraser")
                }
              }
            }
          }

          if !eraseTextRegions.isEmpty {
            Button(role: .destructive) {
              eraseTextRegions.removeAll()
            } label: {
              Label("Clear Embedded Text Eraser", systemImage: "arrow.uturn.backward")
            }
          }
        }
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

  private func detectEmbeddedText() {
    detectingEmbeddedText = true
    detectedTextRegions.removeAll()

    Task {
      do {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: trimStart, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        detectedTextRegions = observations.compactMap { observation in
          guard let candidate = observation.topCandidates(1).first else { return nil }
          return DetectedTextRegion(text: candidate.string, normalizedRect: observation.boundingBox)
        }

        if detectedTextRegions.isEmpty {
          errorMessage = "No embedded text was detected at the selected start time. Move the trim start slider to a frame where the text is visible and try again."
        }
      } catch {
        errorMessage = "Text detection failed: \(error.localizedDescription)"
      }
      detectingEmbeddedText = false
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
          || !eraseTextRegions.isEmpty
        {
          let base = AVVideoComposition(asset: composition) { request in
            var image = request.sourceImage.clampedToExtent()
            if !eraseTextRegions.isEmpty {
              image = eraseEmbeddedText(in: image, regions: eraseTextRegions)
            }
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

struct DetectedTextRegion: Identifiable, Hashable {
  let id = UUID()
  let text: String
  let normalizedRect: CGRect
}

private func eraseEmbeddedText(in image: CIImage, regions: [DetectedTextRegion]) -> CIImage {
  var result = image
  let extent = image.extent

  for region in regions {
    var rect = CGRect(
      x: extent.minX + region.normalizedRect.minX * extent.width,
      y: extent.minY + region.normalizedRect.minY * extent.height,
      width: region.normalizedRect.width * extent.width,
      height: region.normalizedRect.height * extent.height
    )

    let padding = max(6, min(rect.width, rect.height) * 0.18)
    rect = rect.insetBy(dx: -padding, dy: -padding).intersection(extent)
    guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }

    let sampleRect = rect.insetBy(dx: -padding * 1.5, dy: -padding * 1.5).intersection(extent)
    let average = CIFilter.areaAverage()
    average.inputImage = result
    average.extent = sampleRect

    guard let onePixel = average.outputImage else { continue }
    let fill = onePixel
      .transformed(by: CGAffineTransform(scaleX: rect.width, y: rect.height))
      .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
      .cropped(to: rect)

    result = fill.composited(over: result)
  }

  return result.cropped(to: extent)
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
  case blackAndWhite = "Black & White"
  case cinematic = "Cinematic"
  case mono = "Mono"
  case noir = "Noir"
  case vivid = "Vivid"
  case warm = "Warm"
  case cool = "Cool"
  var id: String { rawValue }
  func apply(to image: CIImage) -> CIImage {
    switch self {
    case .none: return image
    case .blackAndWhite:
      let f = CIFilter.colorControls()
      f.inputImage = image
      f.saturation = 0
      f.contrast = 1.08
      return f.outputImage ?? image
    case .cinematic:
      let controls = CIFilter.colorControls()
      controls.inputImage = image
      controls.saturation = 0.88
      controls.contrast = 1.18
      controls.brightness = -0.015
      let graded = controls.outputImage ?? image
      let vignette = CIFilter.vignette()
      vignette.inputImage = graded
      vignette.intensity = 0.65
      vignette.radius = 1.7
      return vignette.outputImage ?? graded
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
