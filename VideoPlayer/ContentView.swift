import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct VideoPhotoPicker: UIViewControllerRepresentable {
  let onVideosPicked: ([URL]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onVideosPicked: onVideosPicked) }

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .videos
    configuration.selectionLimit = 0
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let onVideosPicked: ([URL]) -> Void
    init(onVideosPicked: @escaping ([URL]) -> Void) { self.onVideosPicked = onVideosPicked }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      guard !results.isEmpty else { return }
      let group = DispatchGroup()
      let lock = NSLock()
      var copiedURLs: [URL] = []

      for result in results {
        let provider = result.itemProvider
        guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { continue }
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
          defer { group.leave() }
          guard let url else { return }
          let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
          let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photos-\(UUID().uuidString).\(ext)")
          do {
            if FileManager.default.fileExists(atPath: stableURL.path) {
              try FileManager.default.removeItem(at: stableURL)
            }
            try FileManager.default.copyItem(at: url, to: stableURL)
            lock.lock(); copiedURLs.append(stableURL); lock.unlock()
          } catch { }
        }
      }

      group.notify(queue: .main) { self.onVideosPicked(copiedURLs) }
    }
  }
}

struct VideoItem: Identifiable, Codable, Hashable {
  let id: UUID
  let fileName: String
  let storedName: String
  var lastPosition: Double
  var duration: Double
  var addedAt: Date = Date()
}

@MainActor
final class VideoLibrary: ObservableObject {
  @Published var items: [VideoItem] = [] { didSet { save() } }
  private let key = "video.library.v2"
  private let legacyKey = "video.library.v1"
  init() { load() }
  private var documents: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }
  func url(for item: VideoItem) -> URL { documents.appendingPathComponent(item.storedName) }

  func importVideo(_ source: URL) async throws {
    let originalName = source.lastPathComponent
    let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
    let stored = "\(UUID().uuidString).\(ext)"
    let destination = documents.appendingPathComponent(stored)
    try await Task.detached(priority: .userInitiated) {
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      var coordinatorError: NSError?
      var operationError: Error?
      NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) {
        coordinatedURL in
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: coordinatedURL, to: destination)
        } catch { operationError = error }
      }
      if let operationError { throw operationError }
      if let coordinatorError { throw coordinatorError }
      guard FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
    }.value
    guard FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let asset = AVURLAsset(url: destination)
    let seconds = (try? await asset.load(.duration).seconds) ?? 0
    items.insert(
      VideoItem(
        id: UUID(), fileName: originalName, storedName: stored, lastPosition: 0,
        duration: seconds.isFinite ? seconds : 0), at: 0)
  }

  func downloadVideo(from remoteURL: URL) async throws {
    guard let scheme = remoteURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      throw NSError(
        domain: "VideoDownload",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Enter a valid http or https link."]
      )
    }

    let firstResult = try await downloadResource(remoteURL)
    if firstResult.isVideo {
      try await saveDownloadedVideo(
        temporaryURL: firstResult.temporaryURL,
        response: firstResult.response,
        sourceURL: firstResult.finalURL
      )
      return
    }

    guard firstResult.isHTML else {
      throw NSError(
        domain: "VideoDownload",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The link did not return a downloadable video or a supported webpage containing a video file."]
      )
    }

    let htmlData = try Data(contentsOf: firstResult.temporaryURL)
    guard let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) else {
      throw NSError(
        domain: "VideoDownload",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The webpage could not be read."]
      )
    }

    guard let candidate = extractVideoURL(fromHTML: html, baseURL: firstResult.finalURL) else {
      throw NSError(
        domain: "VideoDownload",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No direct downloadable video was found on this webpage. Protected/DRM streaming pages are not supported."]
      )
    }

    let videoResult = try await downloadResource(candidate)
    guard videoResult.isVideo else {
      throw NSError(
        domain: "VideoDownload",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "The video link found on the webpage did not return a downloadable video file."]
      )
    }

    try await saveDownloadedVideo(
      temporaryURL: videoResult.temporaryURL,
      response: videoResult.response,
      sourceURL: videoResult.finalURL
    )
  }

  private struct DownloadResourceResult {
    let temporaryURL: URL
    let response: URLResponse
    let finalURL: URL
    let isVideo: Bool
    let isHTML: Bool
  }

  private func downloadResource(_ url: URL) async throws -> DownloadResourceResult {
    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

    let (temporaryURL, response) = try await URLSession.shared.download(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw NSError(
        domain: "VideoDownload",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "The website returned HTTP \(http.statusCode)."]
      )
    }

    let finalURL = response.url ?? url
    let mime = response.mimeType?.lowercased() ?? ""
    let responseExtension = (response.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
    let urlExtension = finalURL.pathExtension.lowercased()
    let knownVideoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    let isVideo = mime.hasPrefix("video/")
      || knownVideoExtensions.contains(responseExtension)
      || knownVideoExtensions.contains(urlExtension)
    let isHTML = mime.contains("text/html") || mime.contains("application/xhtml")

    return DownloadResourceResult(
      temporaryURL: temporaryURL,
      response: response,
      finalURL: finalURL,
      isVideo: isVideo,
      isHTML: isHTML
    )
  }

  private func extractVideoURL(fromHTML html: String, baseURL: URL) -> URL? {
    let patterns = [
      #"<meta[^>]+(?:property|name)=[\"'](?:og:video(?::url)?|twitter:player:stream)[\"'][^>]+content=[\"']([^\"']+)[\"']"#,
      #"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"'](?:og:video(?::url)?|twitter:player:stream)[\"']"#,
      #"<video[^>]+src=[\"']([^\"']+)[\"']"#,
      #"<source[^>]+src=[\"']([^\"']+)[\"'][^>]*(?:type=[\"']video/[^\"']+[\"'])?"#
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
      let range = NSRange(html.startIndex..<html.endIndex, in: html)
      guard let match = regex.firstMatch(in: html, options: [], range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: html) else { continue }

      let raw = String(html[valueRange])
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#x2F;", with: "/")
        .replacingOccurrences(of: "\\/", with: "/")

      if let absolute = URL(string: raw), absolute.scheme != nil {
        return absolute
      }
      if let relative = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
        return relative
      }
    }
    return nil
  }

  private func saveDownloadedVideo(
    temporaryURL: URL,
    response: URLResponse,
    sourceURL: URL
  ) async throws {
    var originalName = response.suggestedFilename ?? sourceURL.lastPathComponent
    if originalName.isEmpty { originalName = "Downloaded Video.mp4" }

    var ext = (originalName as NSString).pathExtension
    if ext.isEmpty {
      ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
      originalName = (originalName as NSString).deletingPathExtension + "." + ext
    }

    let stored = "\(UUID().uuidString).\(ext)"
    let destination = documents.appendingPathComponent(stored)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)

    let asset = AVURLAsset(url: destination)
    let seconds = (try? await asset.load(.duration).seconds) ?? 0
    guard seconds.isFinite, seconds > 0 else {
      try? FileManager.default.removeItem(at: destination)
      throw NSError(
        domain: "VideoDownload",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "The downloaded file is not a playable video."]
      )
    }

    items.insert(
      VideoItem(
        id: UUID(),
        fileName: originalName,
        storedName: stored,
        lastPosition: 0,
        duration: seconds
      ),
      at: 0
    )
  }

  func convertVideoToMP3(_ item: VideoItem) async throws -> URL {
    try await convertMediaToMP3(sourceURL: url(for: item), preferredName: item.fileName)
  }

  func downloadMP3(from remoteURL: URL) async throws -> URL {
    guard let scheme = remoteURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      throw NSError(domain: "AudioDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid http or https link."])
    }

    let first = try await downloadResource(remoteURL)
    var media = first
    if !first.isVideo {
      guard first.isHTML else {
        throw NSError(domain: "AudioDownload", code: 2, userInfo: [NSLocalizedDescriptionKey: "The link did not return downloadable media."])
      }
      let htmlData = try Data(contentsOf: first.temporaryURL)
      guard let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1),
            let candidate = extractVideoURL(fromHTML: html, baseURL: first.finalURL) else {
        throw NSError(domain: "AudioDownload", code: 3, userInfo: [NSLocalizedDescriptionKey: "No downloadable media file was exposed by this webpage."])
      }
      media = try await downloadResource(candidate)
    }

    guard media.isVideo else {
      throw NSError(domain: "AudioDownload", code: 4, userInfo: [NSLocalizedDescriptionKey: "The resolved link is not a supported video file."])
    }

    let name = media.response.suggestedFilename ?? media.finalURL.lastPathComponent
    defer { try? FileManager.default.removeItem(at: media.temporaryURL) }
    return try await convertMediaToMP3(sourceURL: media.temporaryURL, preferredName: name)
  }

  private func convertMediaToMP3(sourceURL: URL, preferredName: String) async throws -> URL {
    let audioDirectory = documents.appendingPathComponent("Audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    let base = (preferredName as NSString).deletingPathExtension.isEmpty ? "Audio" : (preferredName as NSString).deletingPathExtension
    var destination = audioDirectory.appendingPathComponent(base).appendingPathExtension("mp3")
    if FileManager.default.fileExists(atPath: destination.path) {
      destination = audioDirectory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6))").appendingPathExtension("mp3")
    }
    try await MP3Encoder.encode(assetURL: sourceURL, outputURL: destination)
    return destination
  }

  func updatePosition(_ id: UUID, position: Double) {
    if let i = items.firstIndex(where: { $0.id == id }) { items[i].lastPosition = position }
  }
  func delete(_ item: VideoItem) {
    try? FileManager.default.removeItem(at: url(for: item))
    items.removeAll { $0.id == item.id }
  }
  func delete(at offsets: IndexSet) { offsets.map { items[$0] }.forEach(delete) }
  private func load() {
    if let data = UserDefaults.standard.data(forKey: key),
      let decoded = try? JSONDecoder().decode([VideoItem].self, from: data)
    {
      items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
      return
    }
    if let data = UserDefaults.standard.data(forKey: legacyKey),
      let old = try? JSONDecoder().decode([LegacyVideoItem].self, from: data)
    {
      items = old.map {
        VideoItem(
          id: $0.id, fileName: $0.fileName, storedName: $0.storedName,
          lastPosition: $0.lastPosition, duration: $0.duration)
      }.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }
  }
  private func save() {
    if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
  }
}
private struct LegacyVideoItem: Codable {
  let id: UUID
  let fileName: String
  let storedName: String
  var lastPosition: Double
  var duration: Double
}

enum LibraryTab: Hashable { case recent, library, download, settings }

struct ContentView: View {
  @StateObject private var library = VideoLibrary()
  @State private var tab: LibraryTab = .recent
  @AppStorage("playerSkipSeconds") private var skipSeconds = 10.0
  @AppStorage("playerSubtitleSize") private var subtitleSize = 20.0
  @AppStorage("playerSubtitleDelay") private var subtitleDelay = 0.0
  @AppStorage("videoFavorites") private var favoriteData = Data()
  @State private var librarySearch = ""
  @State private var librarySort = 0
  @State private var favoritesOnly = false
  @AppStorage("libraryGridView") private var libraryGridView = false
  @AppStorage("cinemaAccent") private var cinemaAccent = 0
  @AppStorage("cinemaAppearance") private var cinemaAppearance = 0
  private var accent: Color { cinemaAccent == 1 ? .cyan : (cinemaAccent == 2 ? .indigo : .blue) }
  private var favoriteIDs: Set<String> { Set((try? JSONDecoder().decode([String].self, from: favoriteData)) ?? []) }
  private func toggleFavorite(_ item: VideoItem) {
    var ids = favoriteIDs
    if ids.contains(item.id.uuidString) { ids.remove(item.id.uuidString) } else { ids.insert(item.id.uuidString) }
    favoriteData = (try? JSONEncoder().encode(Array(ids))) ?? Data()
  }
  @State private var importing = false
  @State private var showingPhotos = false
  @State private var showImportSources = false
  @State private var selected: VideoItem?
  @State private var isImportingVideo = false
  @State private var importError: String?
  @State private var downloadLink = ""
  @AppStorage("recentDownloadLinks") private var recentDownloadLinks = ""
  @State private var downloadFilter = 0
  @State private var downloadSearch = ""
  @State private var isDownloading = false
  @State private var downloadMessage: String?
  @State private var generatedAudioURL: URL?
  @State private var isConvertingAudio = false
  @AppStorage("autoPlay") private var autoPlay = true
  @AppStorage("rememberPosition") private var rememberPosition = true

  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { homePage.navigationTitle("Home") }.tabItem {
        Label("Home", systemImage: "house.fill")
      }.tag(LibraryTab.recent)
      NavigationStack { libraryPage(recentOnly: false).navigationTitle("Library") }.tabItem {
        Label("Library", systemImage: "play.rectangle.on.rectangle")
      }.tag(LibraryTab.library)
      NavigationStack { downloadView.navigationTitle("Download") }.tabItem {
        Label("Download", systemImage: "arrow.down.circle")
      }.tag(LibraryTab.download)
      NavigationStack { settingsView.navigationTitle("Settings") }.tabItem {
        Label("More", systemImage: "square.grid.2x2")
      }.tag(LibraryTab.settings)
    }
    .tint(accent)
    .preferredColorScheme(cinemaAppearance == 1 ? .light : (cinemaAppearance == 2 ? nil : .dark))
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.movie, .video, .mpeg4Movie], allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let source = urls.first else { return }
        isImportingVideo = true
        Task {
          do { try await library.importVideo(source) } catch {
            importError = error.localizedDescription
          }
          isImportingVideo = false
        }
      case .failure(let error): importError = error.localizedDescription
      }
    }
    .sheet(isPresented: $showingPhotos) {
      VideoPhotoPicker { urls in
        guard !urls.isEmpty else { return }
        isImportingVideo = true
        Task {
          for source in urls {
            do {
              try await library.importVideo(source)
              try? FileManager.default.removeItem(at: source)
            } catch {
              importError = error.localizedDescription
            }
          }
          isImportingVideo = false
        }
      }
      .ignoresSafeArea()
    }
    .confirmationDialog("Add Videos", isPresented: $showImportSources, titleVisibility: .visible) {
      Button("Choose from Photos") { showingPhotos = true }
      Button("Choose from Files") { importing = true }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Photos shows videos in your Photos library. Files lets you choose videos from On My iPhone, iCloud Drive, and other file providers.")
    }
    .fullScreenCover(item: $selected) { item in
      PlayerScreen(item: item, url: library.url(for: item), autoPlay: autoPlay) { position in
        if rememberPosition { library.updatePosition(item.id, position: position) }
      }
    }
    .alert(
      "Video Import Failed",
      isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(importError ?? "Unknown error")
    }
    .alert(
      "Download",
      isPresented: Binding(get: { downloadMessage != nil }, set: { if !$0 { downloadMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(downloadMessage ?? "")
    }
    .overlay {
      if isImportingVideo || isDownloading || isConvertingAudio {
        ZStack {
          Color.black.opacity(0.35).ignoresSafeArea()
          VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(isConvertingAudio ? "Creating MP3…" : (isDownloading ? "Downloading Video…" : "Importing Video…")).font(.headline)
            Text(isConvertingAudio ? "Audio conversion time depends on the length of the video." : (isDownloading ? "Downloading from the link. Large videos can take several minutes." : "Keep Video Player open. Very large videos may take several minutes.")).font(
              .caption
            ).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(30)
        }
      }
    }
  }

  private var homePage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Your personal cinema").font(.subheadline).foregroundStyle(.secondary)
            Text("Ready to watch").font(.largeTitle.bold())
          }
          Spacer()
          Button { showImportSources = true } label: {
            Image(systemName: "plus").font(.title3.weight(.semibold))
              .frame(width: 48, height: 48).background(.blue.opacity(0.15), in: Circle())
          }.accessibilityLabel("Import videos")
        }
        let continuing = library.items.filter { $0.lastPosition > 5 && $0.duration > 0 && $0.lastPosition < $0.duration - 10 }
        if !continuing.isEmpty {
          Text("Continue Watching").font(.title2.bold())
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
              ForEach(continuing.prefix(12)) { item in
                Button { selected = item } label: {
                  VStack(alignment: .leading, spacing: 7) {
                    VideoThumbnail(url: library.url(for: item))
                      .frame(width: 230, height: 130).clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(item.fileName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    ProgressView(value: min(item.lastPosition / max(item.duration, 1), 1))
                  }.frame(width: 230, alignment: .leading)
                }.buttonStyle(.plain)
              }
            }
          }
        }
        HStack {
          Text("Recently Added").font(.title2.bold())
          Spacer()
          Button("See All") { tab = .library }.font(.subheadline)
        }
        if library.items.isEmpty { emptyView }
        else { LazyVStack(spacing: 10) { ForEach(library.items.prefix(12)) { videoRow($0) } } }
      }.padding(18)
    }.background(Color(uiColor: .systemGroupedBackground))
  }

  private var sortedLibraryItems: [VideoItem] {
    let filtered = library.items.filter { item in
      (!favoritesOnly || favoriteIDs.contains(item.id.uuidString)) &&
      (librarySearch.isEmpty || item.fileName.localizedCaseInsensitiveContains(librarySearch))
    }
    switch librarySort {
    case 1: return filtered.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    case 2: return filtered.sorted { $0.duration > $1.duration }
    default: return filtered.sorted { $0.addedAt > $1.addedAt }
    }
  }

  @ViewBuilder private func libraryPage(recentOnly: Bool) -> some View {
    Group {
      if libraryGridView {
        ScrollView {
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
            ForEach(sortedLibraryItems) { item in
              Button { selected = item } label: {
                VStack(alignment: .leading, spacing: 7) {
                  VideoThumbnail(url: library.url(for: item))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                  Text(item.fileName).font(.subheadline.weight(.semibold)).lineLimit(2)
                  Text(format(item.duration)).font(.caption).foregroundStyle(.secondary)
                  if item.lastPosition > 1 && item.duration > 0 {
                    ProgressView(value: min(item.lastPosition / item.duration, 1))
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain).contextMenu {
                Button { toggleFavorite(item) } label: {
                  Label(favoriteIDs.contains(item.id.uuidString) ? "Remove Favorite" : "Add Favorite", systemImage: "heart")
                }
                ShareLink(item: library.url(for: item)) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { library.delete(item) } label: { Label("Delete", systemImage: "trash") }
              }
            }
          }.padding(16)
          if sortedLibraryItems.isEmpty { VStack(spacing: 10) { Image(systemName: "play.rectangle").font(.largeTitle); Text("No Videos").font(.headline); Text("Import a video or change your search.").font(.caption) }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30) }
        }
      } else {
        List {
          if sortedLibraryItems.isEmpty {
            Text(library.items.isEmpty ? "Import videos to start your library." : "No matching videos.").foregroundStyle(.secondary)
          } else { ForEach(sortedLibraryItems) { item in videoRow(item) } }
        }
      }
    }
    .searchable(text: $librarySearch, prompt: "Search videos")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button { favoritesOnly.toggle() } label: {
          Image(systemName: favoritesOnly ? "heart.fill" : "heart")
        }.accessibilityLabel("Show favorites")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button { libraryGridView.toggle() } label: {
          Image(systemName: libraryGridView ? "list.bullet" : "square.grid.2x2")
        }.accessibilityLabel(libraryGridView ? "List view" : "Grid view")
        Menu {
          Picker("Sort Videos", selection: $librarySort) {
            Text("Recently Added").tag(0)
            Text("Name").tag(1)
            Text("Longest First").tag(2)
          }
        } label: { Image(systemName: "arrow.up.arrow.down") }
        Button { showImportSources = true } label: { Image(systemName: "plus") }
          .disabled(isImportingVideo)
      }
    }
  }

  private func videoRow(_ item: VideoItem) -> some View {
    HStack(spacing: 12) {
      Button {
        selected = item
      } label: {
        HStack(spacing: 14) {
          VideoThumbnail(url: library.url(for: item)).frame(width: 112, height: 64).clipShape(
            RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 6) {
            Text(item.fileName).font(.headline).lineLimit(2)
            Text(item.duration > 0 ? format(item.duration) : "Video").font(.caption)
              .foregroundStyle(.secondary)
            if item.lastPosition > 1 && item.duration > 0 {
              ProgressView(value: min(item.lastPosition / item.duration, 1))
            }
          }
        }
      }.buttonStyle(.plain)
      Spacer(minLength: 4)
      Menu {
        Button {
          selected = item
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        Button {
          selected = item
        } label: {
          Label("Edit Video", systemImage: "slider.horizontal.3")
        }
        Button { toggleFavorite(item) } label: {
          Label(favoriteIDs.contains(item.id.uuidString) ? "Remove Favorite" : "Add to Favorites", systemImage: "heart")
        }
        Button {
          convertToMP3(item)
        } label: {
          Label("Convert to MP3", systemImage: "waveform.badge.plus")
        }
        ShareLink(item: library.url(for: item)) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
          library.delete(item)
        } label: {
          Label("Delete Video", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis").font(.title3).frame(width: 36, height: 44).contentShape(
          Rectangle())
      }
    }
    .contextMenu {
      Button {
        selected = item
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      Button {
        selected = item
      } label: {
        Label("Edit Video", systemImage: "slider.horizontal.3")
      }
      Button {
        convertToMP3(item)
      } label: {
        Label("Convert to MP3", systemImage: "waveform.badge.plus")
      }
      Button(role: .destructive) {
        library.delete(item)
      } label: {
        Label("Delete Video", systemImage: "trash")
      }
    }
  }

  private var emptyView: some View {
    VStack(spacing: 18) {
      Spacer()
      Image(systemName: "play.rectangle").font(.system(size: 58)).foregroundStyle(.secondary)
      Text("No Videos").font(.title2).fontWeight(.semibold)
      Text("Add videos from Photos or Files to start watching.").foregroundStyle(.secondary)
        .multilineTextAlignment(.center).padding(.horizontal, 32)
      Button {
        showImportSources = true
      } label: {
        Label("Add Videos", systemImage: "plus").font(.headline)
      }.buttonStyle(.borderedProminent)
      Spacer()
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var downloadView: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          Image(systemName: "arrow.down.circle.fill")
            .font(.largeTitle).foregroundStyle(accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("Downloads Hub").font(.headline)
            Text("Save direct media links and manage downloaded files")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.vertical, 6)
      }
      Section("New Download") {
        TextField("Paste a video or media URL", text: $downloadLink)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        HStack {
          Button {
            startDownload()
          } label: {
            Label(isDownloading ? "Downloading…" : "Video", systemImage: "film")
          }
          .disabled(isDownloading || isConvertingAudio || downloadLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          Button {
            startMP3Download()
          } label: {
            Label(isConvertingAudio ? "Converting…" : "MP3", systemImage: "waveform")
          }
          .disabled(isDownloading || isConvertingAudio || downloadLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if isDownloading || isConvertingAudio {
          ProgressView()
          Text("Please keep the app open until the transfer completes.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let generatedAudioURL {
          ShareLink(item: generatedAudioURL) {
            Label("Share Last MP3", systemImage: "square.and.arrow.up")
          }
        }
      }
      if !recentDownloadLinks.isEmpty {
        Section("Recent Links") {
          ForEach(recentDownloadLinks.components(separatedBy: "\n").filter { !$0.isEmpty }, id: \.self) { link in
            Button {
              downloadLink = link
            } label: {
              Label(link, systemImage: "clock.arrow.circlepath")
                .lineLimit(1)
            }
          }
          Button("Clear Recent Links", role: .destructive) { recentDownloadLinks = "" }
        }
      }
      Section("Downloaded Videos") {
        TextField("Search saved videos", text: $downloadSearch)
        Picker("View", selection: $downloadFilter) {
          Text("All").tag(0)
          Text("Newest").tag(1)
          Text("Name").tag(2)
        }.pickerStyle(.segmented)
        let matching = library.items.filter { downloadSearch.isEmpty || $0.fileName.localizedCaseInsensitiveContains(downloadSearch) }
        let ordered = downloadFilter == 2
          ? matching.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
          : matching.sorted { $0.addedAt > $1.addedAt }
        if ordered.isEmpty {
          Label("No matching videos", systemImage: "film.stack").foregroundStyle(.secondary)
        } else {
          ForEach(ordered) { item in
            HStack {
              Image(systemName: "film").foregroundStyle(accent)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1)
                Text(item.addedAt, style: .date).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button { selected = item } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
              ShareLink(item: library.url(for: item)) { Image(systemName: "square.and.arrow.up") }
            }
          }
        }
      }
      Section("Supported Links") {
        Text("Direct MP4, MOV, M4V and supported downloadable media links work best. DRM-protected streams and websites without exposed media files are not supported.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private func rememberDownloadLink(_ link: String) {
    var links = recentDownloadLinks.components(separatedBy: "\n").filter { !$0.isEmpty && $0 != link }
    links.insert(link, at: 0)
    recentDownloadLinks = links.prefix(8).joined(separator: "\n")
  }

  private func startDownload() {
    let text = downloadLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let remoteURL = URL(string: text) else {
      downloadMessage = "The link is not a valid URL."
      return
    }
    isDownloading = true
    Task {
      do {
        try await library.downloadVideo(from: remoteURL)
        rememberDownloadLink(text)
        downloadLink = ""
        downloadMessage = "Video downloaded and added to your library."
        tab = .recent
      } catch {
        downloadMessage = error.localizedDescription
      }
      isDownloading = false
    }
  }

  private func convertToMP3(_ item: VideoItem) {
    guard !isConvertingAudio else { return }
    isConvertingAudio = true
    Task {
      do {
        let output = try await library.convertVideoToMP3(item)
        generatedAudioURL = output
        downloadMessage = "MP3 created: \(output.lastPathComponent). Open the Download tab to share it."
        tab = .download
      } catch {
        downloadMessage = error.localizedDescription
      }
      isConvertingAudio = false
    }
  }

  private func startMP3Download() {
    let text = downloadLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let remoteURL = URL(string: text) else {
      downloadMessage = "The link is not a valid URL."
      return
    }
    isConvertingAudio = true
    Task {
      do {
        let output = try await library.downloadMP3(from: remoteURL)
        rememberDownloadLink(text)
        generatedAudioURL = output
        downloadLink = ""
        downloadMessage = "MP3 created: \(output.lastPathComponent)"
      } catch {
        downloadMessage = error.localizedDescription
      }
      isConvertingAudio = false
    }
  }

  private var settingsView: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $cinemaAppearance) {
          Text("Cinema Dark").tag(0)
          Text("Light").tag(1)
          Text("System").tag(2)
        }
        Picker("Accent", selection: $cinemaAccent) {
          Text("Blue").tag(0)
          Text("Cyan").tag(1)
          Text("Indigo").tag(2)
        }
        Toggle("Grid Library", isOn: $libraryGridView)
      }
      Section("Playback") {
        Toggle("Auto Play", isOn: $autoPlay)
        Toggle("Remember Playback Position", isOn: $rememberPosition)
        Picker("Skip Interval", selection: $skipSeconds) {
          Text("5 seconds").tag(5.0)
          Text("10 seconds").tag(10.0)
          Text("15 seconds").tag(15.0)
          Text("30 seconds").tag(30.0)
        }
      }
      Section("Subtitles") {
        Slider(value: $subtitleSize, in: 14...32, step: 2)
        LabeledContent("Font Size", value: "\(Int(subtitleSize)) pt")
        Slider(value: $subtitleDelay, in: -5...5, step: 0.5)
        LabeledContent("Subtitle Delay", value: String(format: "%+.1f s", subtitleDelay))
      }

      Section("Library") {
        Button {
          showImportSources = true
        } label: {
          Label("Add Videos from Photos or Files", systemImage: "plus")
        }

        Text(
          "Use Photos for videos in your photo library, or Files for videos in On My iPhone, iCloud Drive, and other file providers. Imported videos are copied into Video Player for offline playback."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section("Tools") {
        Text("Use the menu beside a video to edit, convert to MP3, share, or delete it.")
          .font(.footnote).foregroundStyle(.secondary)
        if let generatedAudioURL { ShareLink(item: generatedAudioURL) { Label("Share Last MP3", systemImage: "waveform") } }
      }
      Section("Performance") {
        Button { ThumbnailStore.shared.clearCache() } label: {
          Label("Clear Thumbnail Cache", systemImage: "trash.slash")
        }
        Text("Thumbnails are cached for smoother scrolling. Clearing the cache does not delete videos.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section("About") {
        LabeledContent("App", value: "Video Player")
        LabeledContent("Version", value: "1.1")
      }
    }
  }
  private func format(_ seconds: Double) -> String {
    let s = Int(seconds)
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
      : String(format: "%d:%02d", s / 60, s % 60)
  }
}

@MainActor
final class ThumbnailStore {
  static let shared = ThumbnailStore()
  private let cache = NSCache<NSString, UIImage>()
  private var requests: [String: Task<UIImage?, Never>] = [:]
  private init() { cache.countLimit = 160; cache.totalCostLimit = 80 * 1024 * 1024 }
  private var diskFolder: URL {
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VideoThumbnails", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  func clearCache() {
    cache.removeAllObjects()
    try? FileManager.default.removeItem(at: diskFolder)
  }
  private func diskURL(for url: URL) -> URL {
    // Imported video names are UUIDs, so they are safe, stable cache keys.
    diskFolder.appendingPathComponent(url.lastPathComponent + ".jpg")
  }

  func thumbnail(for url: URL) async -> UIImage? {
    let key = url.path
    if let existing = cache.object(forKey: key as NSString) { return existing }
    let cachedFile = diskURL(for: url)
    if let diskImage = UIImage(contentsOfFile: cachedFile.path) {
      cache.setObject(diskImage, forKey: key as NSString)
      return diskImage
    }
    if let request = requests[key] { return await request.value }
    let request = Task.detached(priority: .utility) { () -> UIImage? in
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 480, height: 300)
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
      defer { generator.cancelAllCGImageGeneration() }
      if let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) {
        return UIImage(cgImage: cg)
      }
      if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
        return UIImage(cgImage: cg)
      }
      return nil
    }
    requests[key] = request
    let image = await request.value
    requests[key] = nil
    if let image {
      cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
      if let jpeg = image.jpegData(compressionQuality: 0.72) {
        let destination = diskURL(for: url)
        Task.detached(priority: .utility) { try? jpeg.write(to: destination, options: .atomic) }
      }
    }
    return image
  }
}

struct VideoThumbnail: View {
  let url: URL
  @State private var image: UIImage?
  var body: some View {
    ZStack {
      Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
      if let image { Image(uiImage: image).resizable().scaledToFill() }
      else { Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.secondary) }
    }
    .clipped()
    .task(id: url) { image = await ThumbnailStore.shared.thumbnail(for: url) }
  }
}
