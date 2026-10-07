import AVKit
import SwiftUI
import UniformTypeIdentifiers

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

enum LibraryTab: Hashable { case recent, library, settings }

struct ContentView: View {
  @StateObject private var library = VideoLibrary()
  @State private var tab: LibraryTab = .recent
  @State private var importing = false
  @State private var selected: VideoItem?
  @State private var isImportingVideo = false
  @State private var importError: String?
  @AppStorage("autoPlay") private var autoPlay = true
  @AppStorage("rememberPosition") private var rememberPosition = true

  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { libraryPage(recentOnly: true).navigationTitle("Recent") }.tabItem {
        Label("Recent", systemImage: "clock")
      }.tag(LibraryTab.recent)
      NavigationStack { libraryPage(recentOnly: false).navigationTitle("Library") }.tabItem {
        Label("Library", systemImage: "play.rectangle.on.rectangle")
      }.tag(LibraryTab.library)
      NavigationStack { settingsView.navigationTitle("Settings") }.tabItem {
        Label("Settings", systemImage: "gearshape")
      }.tag(LibraryTab.settings)
    }
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.movie, .video], allowsMultipleSelection: false
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
    .overlay {
      if isImportingVideo {
        ZStack {
          Color.black.opacity(0.35).ignoresSafeArea()
          VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Importing Video…").font(.headline)
            Text("Keep Video Player open. Very large videos may take several minutes.").font(
              .caption
            ).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(30)
        }
      }
    }
  }

  @ViewBuilder private func libraryPage(recentOnly: Bool) -> some View {
    let displayItems = recentOnly ? Array(library.items.prefix(20)) : library.items
    Group {
      if displayItems.isEmpty {
        emptyView
      } else {
        List {
          ForEach(displayItems) { item in videoRow(item) }.onDelete { offsets in
            if !recentOnly { library.delete(at: offsets) }
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          importing = true
        } label: {
          Image(systemName: "plus")
        }.disabled(isImportingVideo)
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
      Text("Import a video from the Files app to start watching.").foregroundStyle(.secondary)
        .multilineTextAlignment(.center).padding(.horizontal, 32)
      Button {
        importing = true
      } label: {
        Label("Import Video", systemImage: "plus").font(.headline)
      }.buttonStyle(.borderedProminent)
      Spacer()
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var settingsView: some View {
    Form {
      Section("Playback") {
        Toggle("Auto Play", isOn: $autoPlay)
        Toggle("Remember Playback Position", isOn: $rememberPosition)
      }

      Section("Library") {
        Button {
          importing = true
        } label: {
          Label("Import Video", systemImage: "plus")
        }

        Text(
          "Small and large videos are copied into Video Player so they remain available offline."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
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

struct VideoThumbnail: View {
  let url: URL
  @State private var image: UIImage?
  var body: some View {
    ZStack {
      Rectangle().fill(.black.opacity(0.85))
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: "play.fill").foregroundStyle(.white)
      }
    }.clipped().task {
      let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      g.appliesPreferredTrackTransform = true
      if let cg = try? g.copyCGImage(
        at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
      {
        image = UIImage(cgImage: cg)
      }
    }
  }
}
