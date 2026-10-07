import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct VideoItem: Identifiable, Codable, Hashable {
    let id: UUID
    let fileName: String
    let storedName: String
    var lastPosition: Double
    var duration: Double
}

@MainActor
final class VideoLibrary: ObservableObject {
    @Published var items: [VideoItem] = [] { didSet { save() } }
    private let key = "video.library.v1"

    init() { load() }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func url(for item: VideoItem) -> URL { documents.appendingPathComponent(item.storedName) }

    func importVideo(_ source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let stored = "\(UUID().uuidString).\(ext)"
        let destination = documents.appendingPathComponent(stored)
        try FileManager.default.copyItem(at: source, to: destination)
        let asset = AVURLAsset(url: destination)
        Task {
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            items.insert(VideoItem(id: UUID(), fileName: source.lastPathComponent, storedName: stored, lastPosition: 0, duration: seconds.isFinite ? seconds : 0), at: 0)
        }
    }

    func updatePosition(_ id: UUID, position: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastPosition = position
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { try? FileManager.default.removeItem(at: url(for: items[index])) }
        items.remove(atOffsets: offsets)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([VideoItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }
    private func save() { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) } }
}

struct ContentView: View {
    @StateObject private var library = VideoLibrary()
    @State private var importing = false
    @State private var selected: VideoItem?

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView("No Videos", systemImage: "play.rectangle", description: Text("Import a video from the Files app to start watching."))
                } else {
                    List {
                        ForEach(library.items) { item in
                            Button { selected = item } label: {
                                HStack(spacing: 14) {
                                    VideoThumbnail(url: library.url(for: item)).frame(width: 112, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.fileName).font(.headline).lineLimit(2)
                                        Text(item.duration > 0 ? format(item.duration) : "Video").font(.caption).foregroundStyle(.secondary)
                                        if item.lastPosition > 1 && item.duration > 0 {
                                            ProgressView(value: min(item.lastPosition / item.duration, 1))
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }.onDelete(perform: library.delete)
                    }
                }
            }
            .navigationTitle("Videos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { importing = true } label: { Image(systemName: "plus") } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { try? library.importVideo(url) }
            }
            .fullScreenCover(item: $selected) { item in
                PlayerScreen(item: item, url: library.url(for: item)) { position in library.updatePosition(item.id, position: position) }
            }
        }
    }
    private func format(_ seconds: Double) -> String { let s = Int(seconds); return String(format: "%d:%02d", s/60, s%60) }
}

struct VideoThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "play.fill").foregroundStyle(.white) }
        }.clipped().task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) { image = UIImage(cgImage: cg) }
        }
    }
}
