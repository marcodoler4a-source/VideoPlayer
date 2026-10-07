import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @State private var videos: [VideoItem] = []
    @State private var showingImporter = false
    @State private var selectedVideo: VideoItem?

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if videos.isEmpty {
                    emptyLibraryView
                } else {
                    videoLibraryView
                }
            }
            .navigationTitle("Video Player")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import Video")
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.movie, .video],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .fullScreenCover(item: $selectedVideo) { video in
                PlayerScreen(videoURL: video.url)
            }
        }
    }

    // MARK: - Empty Library

    private var emptyLibraryView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "play.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Videos")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Import a video from the Files app to start watching.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingImporter = true
            } label: {
                Label("Import Video", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video Library

    private var videoLibraryView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(videos) { video in
                    Button {
                        selectedVideo = video
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                importVideo(from: url)
            }

        case .failure(let error):
            print("Video import failed: \(error.localizedDescription)")
        }
    }

    private func importVideo(from sourceURL: URL) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileManager = FileManager.default

            let documentsDirectory = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            let videosDirectory = documentsDirectory
                .appendingPathComponent("Videos", isDirectory: true)

            if !fileManager.fileExists(atPath: videosDirectory.path) {
                try fileManager.createDirectory(
                    at: videosDirectory,
                    withIntermediateDirectories: true
                )
            }

            var destinationURL = videosDirectory
                .appendingPathComponent(sourceURL.lastPathComponent)

            if fileManager.fileExists(atPath: destinationURL.path) {
                let fileExtension = sourceURL.pathExtension
                let originalName = sourceURL
                    .deletingPathExtension()
                    .lastPathComponent

                let uniqueName = "\(originalName)-\(UUID().uuidString)"

                destinationURL = videosDirectory
                    .appendingPathComponent(uniqueName)
                    .appendingPathExtension(fileExtension)
            }

            try fileManager.copyItem(
                at: sourceURL,
                to: destinationURL
            )

            let video = VideoItem(url: destinationURL)

            DispatchQueue.main.async {
                videos.append(video)
            }

        } catch {
            print("Unable to copy video: \(error.localizedDescription)")
        }
    }
}

// MARK: - Video Item

struct VideoItem: Identifiable, Hashable {
    let id: UUID
    let url: URL

    init(
        id: UUID = UUID(),
        url: URL
    ) {
        self.id = id
        self.url = url
    }

    var title: String {
        url
            .deletingPathExtension()
            .lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension.uppercased()
    }
}

// MARK: - Video Card

struct VideoCard: View {
    let video: VideoItem

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(16 / 9, contentMode: .fit)

                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16)
                        )
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .clipped()

            Text(video.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !video.fileExtension.isEmpty {
                Text(video.fileExtension)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            thumbnail = await generateThumbnail(
                for: video.url
            )
        }
    }

    private func generateThumbnail(
        for url: URL
    ) async -> UIImage? {
        let asset = AVURLAsset(url: url)

        let generator = AVAssetImageGenerator(
            asset: asset
        )

        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: 600,
            height: 600
        )

        let time = CMTime(
            seconds: 1,
            preferredTimescale: 600
        )

        do {
            let cgImage = try generator.copyCGImage(
                at: time,
                actualTime: nil
            )

            return UIImage(cgImage: cgImage)

        } catch {
            print(
                "Thumbnail generation failed: \(error.localizedDescription)"
            )

            return nil
        }
    }
}
