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
  let onVideoTap: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(videoScale: $videoScale, onVideoTap: onVideoTap)
  }

  func makeUIViewController(context: Context) -> PlayerContainerController {
    let container = PlayerContainerController()
    container.playerController.player = player
    container.playerController.showsPlaybackControls = true
    container.playerController.allowsPictureInPicturePlayback = true
    container.playerController.canStartPictureInPictureAutomaticallyFromInline = true
    container.playerController.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect

    let pinch = UIPinchGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePinch(_:))
    )
    pinch.cancelsTouchesInView = false
    pinch.delegate = context.coordinator
    container.view.addGestureRecognizer(pinch)

    let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
    tap.cancelsTouchesInView = false
    tap.delegate = context.coordinator
    container.view.addGestureRecognizer(tap)

    let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.cancelsTouchesInView = false
    doubleTap.delegate = context.coordinator
    container.view.addGestureRecognizer(doubleTap)
    tap.require(toFail: doubleTap)

    let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
    pan.minimumNumberOfTouches = 2
    pan.maximumNumberOfTouches = 2
    pan.cancelsTouchesInView = false
    pan.delegate = context.coordinator
    container.view.addGestureRecognizer(pan)

    context.coordinator.container = container
    container.videoScale = videoScale
    return container
  }

  func updateUIViewController(_ container: PlayerContainerController, context: Context) {
    container.playerController.player = player
    container.playerController.showsPlaybackControls = true
    container.playerController.allowsPictureInPicturePlayback = true
    container.playerController.canStartPictureInPictureAutomaticallyFromInline = true
    container.playerController.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect
    context.coordinator.container = container
    context.coordinator.onVideoTap = onVideoTap
    container.videoScale = videoScale
    container.updatePlayerFrame()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    @Binding var videoScale: CGFloat
    weak var container: PlayerContainerController?
    private var scaleAtPinchStart: CGFloat = 1
    private var panStart: CGPoint = .zero
    var onVideoTap: () -> Void

    init(videoScale: Binding<CGFloat>, onVideoTap: @escaping () -> Void) {
      _videoScale = videoScale
      self.onVideoTap = onVideoTap
      super.init()
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
      if recognizer.state == .ended { onVideoTap() }
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began:
        scaleAtPinchStart = videoScale
      case .changed, .ended:
        let proposed = scaleAtPinchStart * recognizer.scale
        // Resize the player viewport instead of applying a transform. This keeps
        // Apple's native buttons at their normal size while the video area changes.
        videoScale = min(max(proposed, 1), 3)
        container?.videoScale = videoScale
        container?.updatePlayerFrame()
      default:
        break
      }
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      videoScale = videoScale > 1.05 ? 1 : 2
      container?.videoScale = videoScale
      if videoScale == 1 { container?.videoOffset = .zero }
      container?.updatePlayerFrame()
      onVideoTap()
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard let container = container, videoScale > 1 else { return }
      switch recognizer.state {
      case .began: panStart = container.videoOffset
      case .changed, .ended:
        let delta = recognizer.translation(in: container.view)
        container.videoOffset = CGPoint(x: panStart.x + delta.x, y: panStart.y + delta.y)
        container.updatePlayerFrame()
      default: break
      }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

final class PlayerContainerController: UIViewController {
  let playerController = AVPlayerViewController()
  var videoScale: CGFloat = 1
  var videoOffset: CGPoint = .zero

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    addChild(playerController)
    view.addSubview(playerController.view)
    playerController.didMove(toParent: self)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updatePlayerFrame()
  }

  func updatePlayerFrame() {
    guard isViewLoaded else { return }
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let width = bounds.width * videoScale
    let height = bounds.height * videoScale
    playerController.view.transform = .identity
    playerController.view.bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let maxX = max(0, (width - bounds.width) / 2)
    let maxY = max(0, (height - bounds.height) / 2)
    videoOffset.x = min(max(videoOffset.x, -maxX), maxX)
    videoOffset.y = min(max(videoOffset.y, -maxY), maxY)
    if videoScale <= 1 { videoOffset = .zero }
    playerController.view.center = CGPoint(x: bounds.midX + videoOffset.x, y: bounds.midY + videoOffset.y)
    playerController.view.clipsToBounds = true
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
  @State private var observer: Any?
  @State private var importingSubtitle = false
  @State private var subtitleCues: [SubtitleCue] = []
  @State private var subtitleName: String?
  @State private var subtitlesEnabled = true
  @State private var videoScale: CGFloat = 1
  @State private var fillVideo = false
  @State private var showEditor = false
  @State private var showTools = false
  @State private var toolsVisible = false
  @State private var toolsVisibilityTask: Task<Void, Never>?
  @AppStorage("playerSubtitleSize") private var subtitleSize = 20.0
  @AppStorage("playerSubtitleDelay") private var subtitleDelay = 0.0

  init(item: VideoItem, url: URL, autoPlay: Bool = true, onClose: @escaping (Double) -> Void) {
    self.item = item
    self.url = url
    self.autoPlay = autoPlay
    self.onClose = onClose
    _player = State(initialValue: AVPlayer(url: url))
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.ignoresSafeArea()

      // AVPlayerViewController owns the transport, scrubber, speed and PiP UI.
      SystemPlayerView(player: player, fillVideo: fillVideo, videoScale: $videoScale, onVideoTap: { revealTools() })
        .ignoresSafeArea()

      if subtitlesEnabled, let cue = activeSubtitle {
        VStack {
          Spacer()
          Text(cue.text)
            .font(.system(size: subtitleSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 110)
        }
        .allowsHitTesting(false)
      }

      // Native-style, compact tools shortcut. Keep it at the same vertical
      // level as the lower-right AVKit auxiliary control, above the scrubber.
      VStack {
        Spacer()
        HStack {
          if toolsVisible {
            Button {
              toolsVisibilityTask?.cancel()
              toolsVisible = false
              showTools = true
            } label: {
              Image(systemName: "slider.horizontal.3")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .accessibilityLabel("Video tools")
          }
          Spacer()
        }
        .padding(.leading, 16)
        .padding(.bottom, 38)
      }
      .animation(.easeInOut(duration: 0.25), value: toolsVisible)
      .allowsHitTesting(toolsVisible)

      // Swipe down from the very top edge to exit full-screen playback.
      // This replaces the removed custom Close button.
      VStack(spacing: 0) {
        Color.clear
          .contentShape(Rectangle())
          .frame(height: 16)
          .gesture(DragGesture(minimumDistance: 28).onEnded { value in
            if value.translation.height > 90 { close() }
          })
        Spacer()
      }

    }
    .statusBarHidden()
    .onAppear { setup(); revealTools() }
    .onDisappear { toolsVisibilityTask?.cancel(); cleanup() }
    .fileImporter(
      isPresented: $importingSubtitle,
      allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let u = urls.first else { return }
      loadSubtitle(from: u)
    }
    .sheet(isPresented: $showEditor) { VideoEditorView(url: url) }
    .sheet(isPresented: $showTools, onDismiss: { revealTools() }) { toolsSheet }
  }

  private func revealTools() {
    toolsVisibilityTask?.cancel()
    toolsVisible = true
    toolsVisibilityTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 3_000_000_000)
      } catch { return }
      guard !Task.isCancelled, !showTools else { return }
      toolsVisible = false
    }
  }

  private var toolsSheet: some View {
    NavigationStack {
      Form {
        Section("Subtitles") {
          Button("Import SRT Subtitle") { showTools = false; importingSubtitle = true }
          if !subtitleCues.isEmpty {
            Toggle("Show Imported Subtitles", isOn: $subtitlesEnabled)
            Text(subtitleName ?? "Imported subtitles")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("Remove Imported Subtitles", role: .destructive) {
              subtitleCues.removeAll()
              subtitleName = nil
            }
          }
          HStack {
            Text("Subtitle Size")
            Spacer()
            Text("\(Int(subtitleSize)) pt").foregroundStyle(.secondary)
          }
          Slider(value: $subtitleSize, in: 14...36, step: 1)
          HStack {
            Text("Subtitle Delay")
            Spacer()
            Text("\(subtitleDelay, specifier: "%.1f")s").foregroundStyle(.secondary)
          }
          Slider(value: $subtitleDelay, in: -5...5, step: 0.1)
        }
        Section("Display & Zoom") {
          Picker("Video Framing", selection: $fillVideo) {
            Text("Fit Entire Video").tag(false)
            Text("Fill Screen").tag(true)
          }
          .pickerStyle(.segmented)
          HStack {
            Label("Zoom", systemImage: "plus.magnifyingglass")
            Spacer()
            Text(String(format: "%.1f×", Double(videoScale))).monospacedDigit().foregroundStyle(.secondary)
          }
          Slider(value: $videoScale, in: 1...3, step: 0.1)
          Button { videoScale = 1 } label: {
            Label("Reset Zoom to 1×", systemImage: "arrow.counterclockwise")
          }
          Text("Pinch with two fingers to zoom, drag with two fingers to pan, or double-tap to toggle zoom. Zoom adjusts the player viewport; native iPhone controls may also be affected.")
            .font(.footnote).foregroundStyle(.secondary)
          Button { rotateVideo() } label: { Label("Rotate Screen", systemImage: "rotate.right") }
        }
        Section("Video Editing") {
          Button { showTools = false; showEditor = true } label: {
            Label("Open Video Editor", systemImage: "slider.horizontal.3")
          }
          Text("Trim, crop, apply filters, add text, or erase embedded text. Review the edit before replacing the original file.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Text("Playback, scrubbing, speed and Picture in Picture are managed by the iPhone's built-in video player controls.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Video Tools")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showTools = false } } }
    }
  }

  private var itemTitle: String {
    let title = url.deletingPathExtension().lastPathComponent
    return title.isEmpty ? "Video" : title.replacingOccurrences(of: "_", with: " ")
  }

  private var activeSubtitle: SubtitleCue? {
    // Binary search keeps subtitle lookup fast even for long films.
    let target = current - subtitleDelay
    var low = 0
    var high = subtitleCues.count
    while low < high {
      let middle = (low + high) / 2
      if subtitleCues[middle].start <= target { low = middle + 1 }
      else { high = middle }
    }
    guard low > 0 else { return nil }
    let cue = subtitleCues[low - 1]
    return target <= cue.end ? cue : nil
  }
  private func loadSubtitle(from source: URL) {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: source) else { return }
    let text =
      String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    let parsed = SRTParser.parse(text)
    guard !parsed.isEmpty else { return }
    subtitleCues = parsed.sorted { $0.start < $1.start }
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
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { time in current = time.seconds.isFinite ? time.seconds : 0 }
    if autoPlay {
      player.play()
    }
  }
  private func close() {
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
    player.replaceCurrentItem(with: nil)
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
  @State private var editorSection = 0
  @State private var crop: CropPreset = .original
  @State private var filter: FilterPreset = .none
  @State private var overlayText = ""
  @State private var overlayEmoji = ""
  @State private var overlayPosition = 0.5
  @State private var overlaySize = 36.0
  @State private var overlayColor = 0
  @State private var filterIntensity = 1.0
  @State private var exporting = false
  @State private var exportURL: URL?
  @State private var errorMessage: String?
  @State private var detectedTextRegions: [DetectedTextRegion] = []
  @State private var eraseTextRegions: [DetectedTextRegion] = []
  @State private var detectingEmbeddedText = false
  @State private var eraseFrame: UIImage?
  @State private var erasePreview: UIImage?
  @State private var eraseEnabled = false
  @State private var eraseSelectionStart: CGPoint?
  @State private var eraseSelectionEnd: CGPoint?
  @State private var confirmReplace = false
  @State private var savedMessage: String?

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
          Text("Select a start and end point. Use the step buttons for precise adjustments.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Text("Start")
            Slider(value: $trimStart, in: 0...max(trimEnd - 0.1, 0.1))
            Text(time(trimStart)).monospacedDigit()
          }
          HStack {
            Button { trimStart = max(0, trimStart - 0.1) } label: { Image(systemName: "minus.circle") }
            Spacer()
            Text("Start ±0.1s").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { trimStart = min(trimEnd - 0.1, trimStart + 0.1) } label: { Image(systemName: "plus.circle") }
          }
          .buttonStyle(.borderless)
          HStack {
            Text("End")
            Slider(value: $trimEnd, in: min(trimStart + 0.1, duration)...max(duration, 1))
            Text(time(trimEnd)).monospacedDigit()
          }
          HStack {
            Button { trimEnd = max(trimStart + 0.1, trimEnd - 0.1) } label: { Image(systemName: "minus.circle") }
            Spacer()
            Text("End ±0.1s").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { trimEnd = min(duration, trimEnd + 0.1) } label: { Image(systemName: "plus.circle") }
          }
          .buttonStyle(.borderless)
          HStack {
            Label("Selected duration", systemImage: "clock")
            Spacer()
            Text(time(max(0, trimEnd - trimStart))).monospacedDigit().foregroundStyle(.secondary)
          }
          Button { player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600)); player.pause() } label: {
            Label("Preview from Trim Start", systemImage: "play.rectangle")
          }
        }
        Section("Crop") {
          Picker("Crop", selection: $crop) {
            ForEach(CropPreset.allCases) { Text($0.rawValue).tag($0) }
          }
        }
        Section("Filters & Color") {
          Picker("Look", selection: $filter) {
            ForEach(FilterPreset.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.menu)
          if filter != .none {
            HStack {
              Text("Strength")
              Slider(value: $filterIntensity, in: 0...1)
              Text("\(Int(filterIntensity * 100))%")
                .monospacedDigit().frame(width: 45)
            }
          }
          Text("Filters are applied to the exported video. Original leaves colors unchanged.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Stickers & Emoji") {
          TextField("Paste or type emoji stickers", text: $overlayEmoji)
          HStack(spacing: 16) {
            ForEach(["❤️", "😂", "🔥", "✨", "🎉", "😍"], id: \.self) { emoji in
              Button(emoji) { overlayEmoji += emoji }
                .buttonStyle(.borderless)
            }
          }
          Text("Choose one or more emoji to overlay on the video.")
            .font(.caption).foregroundStyle(.secondary)
          if !overlayEmoji.isEmpty {
            Button("Remove Stickers", role: .destructive) { overlayEmoji = "" }
          }
        }
        Section("Text & Overlay Position") {
          TextField("Add text to video", text: $overlayText)
          if !overlayText.isEmpty || !overlayEmoji.isEmpty {
            HStack {
              Text("Overlay size")
              Slider(value: $overlaySize, in: 20...90)
              Text("\(Int(overlaySize))").monospacedDigit()
            }
            Picker("Text color", selection: $overlayColor) {
              Text("White").tag(0)
              Text("Yellow").tag(1)
              Text("Cyan").tag(2)
              Text("Black").tag(3)
            }
            HStack {
              Text("Vertical position")
              Slider(value: $overlayPosition, in: 0.1...0.9)
            }
            Text("Text and emoji are included in the exported video.")
              .font(.caption).foregroundStyle(.secondary)
          }
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

          Text("Draw over the text in the frame below. The selected rectangle is erased throughout the exported video.")
            .font(.caption)
          if let eraseFrame {
            GeometryReader { geometry in
              Image(uiImage: eraseFrame)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                  if let start = eraseSelectionStart, let end = eraseSelectionEnd {
                    Rectangle()
                      .stroke(Color.red, lineWidth: 2)
                      .background(Color.red.opacity(0.2))
                      .frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                      .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                  }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    if eraseSelectionStart == nil { eraseSelectionStart = value.startLocation }
                    eraseSelectionEnd = value.location
                  }
                  .onEnded { value in
                    guard let start = eraseSelectionStart else { return }
                    let end = value.location
                    let bounds = CGRect(origin: .zero, size: geometry.size)
                    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)).intersection(bounds)
                    if rect.width > 3 && rect.height > 3 {
                      let normalized = CGRect(x: rect.minX / bounds.width, y: 1 - rect.maxY / bounds.height, width: rect.width / bounds.width, height: rect.height / bounds.height)
                      eraseTextRegions = [DetectedTextRegion(text: "Manual selection", normalizedRect: normalized)]
                      eraseEnabled = false
                      erasePreview = nil
                    }
                  })
            }
            .frame(height: 220)
          }
          Button("Clear Selection", role: .destructive) {
            eraseTextRegions.removeAll()
            eraseEnabled = false
            erasePreview = nil
            eraseSelectionStart = nil
            eraseSelectionEnd = nil
          }
          Button {
            detectEmbeddedText()
          } label: {
            HStack {
              if detectingEmbeddedText { ProgressView().padding(.trailing, 6) }
              Label(detectingEmbeddedText ? "Detecting…" : "Detect Text at Start Time", systemImage: "viewfinder")
            }
          }
          .disabled(detectingEmbeddedText)

          if let erasePreview, eraseEnabled {
            VStack(alignment: .leading, spacing: 6) {
              Text("Erasure preview (sample frame)").font(.caption).bold()
              Image(uiImage: erasePreview)
                .resizable().scaledToFit().frame(maxHeight: 220)
            }
          }

          if !detectedTextRegions.isEmpty {
            ForEach(detectedTextRegions) { region in
              Button {
                if !eraseTextRegions.contains(where: { $0.id == region.id }) {
                  eraseTextRegions.append(region)
                  eraseEnabled = false
                  erasePreview = nil
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
            Button {
              applyEmbeddedTextEraser()
            } label: {
              Label(eraseEnabled ? "Reapply Eraser & Refresh Preview" : "Erase Selected Text", systemImage: "eraser.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text(eraseEnabled ? "Erasure enabled. Save & Replace Original to apply it to the entire video." : "Text selected. Tap Erase Selected Text to enable removal before saving.")
              .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) {
              eraseTextRegions.removeAll()
              eraseEnabled = false
              erasePreview = nil
            } label: {
              Label("Clear Embedded Text Eraser", systemImage: "arrow.uturn.backward")
            }
          }
        }
        Section("Export & Save") {
          Text("Review the preview and selected trim range before saving. Replacing the original cannot be undone.")
            .font(.footnote).foregroundStyle(.secondary)
          Button {
            confirmReplace = true
          } label: {
            HStack {
              Spacer()
              if exporting { ProgressView().padding(.trailing, 8) }
              Text(exporting ? "Exporting…" : "Save & Replace Original")
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
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
          eraseFrame = UIImage(cgImage: cg)
        }
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration).seconds) ?? 1
        duration = max(d, 0.1)
        trimEnd = duration
      }
      .confirmationDialog("Replace original video?", isPresented: $confirmReplace) {
        Button("Replace Original Video", role: .destructive) { exportEditedVideo() }
      } message: {
        Text("The edited video will replace the existing library file. This cannot be undone.")
      }
      .alert("Video Saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
        Button("OK") { dismiss() }
      } message: { Text(savedMessage ?? "") }
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

  private func applyEmbeddedTextEraser() {
    guard !eraseTextRegions.isEmpty else { return }
    eraseEnabled = true
    guard let frame = eraseFrame, let cg = frame.cgImage else { return }
    let input = CIImage(cgImage: cg)
    let output = eraseEmbeddedText(in: input, regions: eraseTextRegions)
    let context = CIContext()
    if let preview = context.createCGImage(output, from: input.extent) {
      erasePreview = UIImage(cgImage: preview)
    }
  }

  private func detectEmbeddedText() {
    detectingEmbeddedText = true
    detectedTextRegions.removeAll()
    eraseEnabled = false
    erasePreview = nil

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
          || !overlayEmoji.isEmpty
          || (eraseEnabled && !eraseTextRegions.isEmpty)
        {
          let base = AVVideoComposition(asset: composition) { request in
            var image = request.sourceImage.clampedToExtent()
            if eraseEnabled && !eraseTextRegions.isEmpty {
              image = eraseEmbeddedText(in: image, regions: eraseTextRegions)
            }
            if filterIntensity > 0 {
              let filtered = filter.apply(to: image)
              if filterIntensity >= 0.999 { image = filtered }
              else {
                image = filtered.applyingFilter("CIDissolveTransition", parameters: [
                  kCIInputTargetImageKey: image,
                  kCIInputTimeKey: 1 - filterIntensity
                ])
              }
            }
            if crop != .original {
              let rect = crop.rect(in: image.extent)
              image = image.cropped(to: rect).transformed(
                by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            }
            request.finish(with: image.cropped(to: image.extent), context: nil)
          }
          if !overlayText.isEmpty || !overlayEmoji.isEmpty {
            guard let mutableBase = base.mutableCopy() as? AVMutableVideoComposition else {
              throw NSError(
                domain: "VideoEditor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to prepare the text overlay composition."]
              )
            }

            let parent = CALayer()
            let videoLayer = CALayer()
            parent.frame = CGRect(origin: .zero, size: mutableBase.renderSize)
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            let label = [overlayText, overlayEmoji].filter { !$0.isEmpty }.joined(separator: "  ")
            let textLayer = CATextLayer()
            textLayer.string = label
            textLayer.foregroundColor = [UIColor.white, .yellow, .cyan, .black][min(max(overlayColor, 0), 3)].cgColor
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.25).cgColor
            textLayer.alignmentMode = .center
            textLayer.wrapped = true
            textLayer.fontSize = CGFloat(overlaySize)
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.frame = CGRect(x: 20,
              y: mutableBase.renderSize.height * CGFloat(overlayPosition) - 65,
              width: max(mutableBase.renderSize.width - 40, 100), height: 130)
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
          player.pause()
          // Export is complete before touching the original. Replace atomically where possible.
          let manager = FileManager.default
          guard manager.fileExists(atPath: out.path),
                (try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw NSError(domain: "VideoEditor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Exported video is empty."])
          }
          _ = try manager.replaceItemAt(url, withItemAt: out, backupItemName: nil, options: [])
          savedMessage = "Original video replaced successfully."
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

    // Expand the detected box so anti-aliased text edges are also replaced.
    let padding = max(8, min(rect.width, rect.height) * 0.28)
    rect = rect.insetBy(dx: -padding, dy: -padding).intersection(extent)
    guard !rect.isNull, rect.width > 2, rect.height > 2 else { continue }

    // Reconstruct the covered pixels from a nearby clean strip. Prefer the area
    // immediately above the text; if there isn't enough room, use the strip below.
    let sampleHeight = max(2, min(rect.height, 48))
    var sampleRect = CGRect(
      x: rect.minX,
      y: rect.maxY + 2,
      width: rect.width,
      height: sampleHeight
    ).intersection(extent)

    if sampleRect.height < 2 || sampleRect.width < 2 {
      sampleRect = CGRect(
        x: rect.minX,
        y: rect.minY - sampleHeight - 2,
        width: rect.width,
        height: sampleHeight
      ).intersection(extent)
    }

    guard sampleRect.height >= 2, sampleRect.width >= 2 else { continue }

    let sample = result.cropped(to: sampleRect)
    let sx = rect.width / sampleRect.width
    let sy = rect.height / sampleRect.height
    let replacement = sample
      .transformed(by: CGAffineTransform(translationX: -sampleRect.minX, y: -sampleRect.minY))
      .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
      .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
      .cropped(to: rect)

    // Slight blur helps hide seams after stretching neighboring pixels.
    let softened = replacement
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
      .cropped(to: rect)

    result = softened.composited(over: result)
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
