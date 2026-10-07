import AVFoundation
import Foundation
import LAME

enum MP3EncoderError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case encoderFailed
    case cannotCreateOutput

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This video does not contain an audio track."
        case .readerFailed(let message): return "Unable to read the video's audio: \(message)"
        case .encoderFailed: return "MP3 encoding failed."
        case .cannotCreateOutput: return "Unable to create the MP3 file."
        }
    }
}

enum MP3Encoder {
    static func encode(assetURL: URL, outputURL: URL, bitrateKbps: Int32 = 192) async throws {
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MP3EncoderError.noAudioTrack
        }

        let sampleRate: Double = 44_100
        let channels: Int32 = 2
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MP3EncoderError.readerFailed("Unsupported audio track.") }
        reader.add(output)

        try? FileManager.default.removeItem(at: outputURL)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw MP3EncoderError.cannotCreateOutput
        }
        defer { try? handle.close() }

        guard let lame = lame_init() else { throw MP3EncoderError.encoderFailed }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, channels)
        lame_set_brate(lame, bitrateKbps)
        lame_set_quality(lame, 2)
        guard lame_init_params(lame) >= 0 else { throw MP3EncoderError.encoderFailed }

        guard reader.startReading() else {
            throw MP3EncoderError.readerFailed(reader.error?.localizedDescription ?? "Unknown reader error")
        }

        let mp3BufferSize = 1_048_576
        var mp3Buffer = [UInt8](repeating: 0, count: mp3BufferSize)

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else { continue }

            let sampleCount = length / MemoryLayout<Int16>.size / Int(channels)
            let pcm = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            let encoded = mp3Buffer.withUnsafeMutableBufferPointer { mp3Ptr in
                lame_encode_buffer_interleaved(
                    lame,
                    UnsafeMutablePointer(mutating: pcm),
                    Int32(sampleCount),
                    mp3Ptr.baseAddress,
                    Int32(mp3BufferSize)
                )
            }
            guard encoded >= 0 else { throw MP3EncoderError.encoderFailed }
            if encoded > 0 { try handle.write(contentsOf: Data(mp3Buffer.prefix(Int(encoded)))) }
        }

        if reader.status == .failed {
            throw MP3EncoderError.readerFailed(reader.error?.localizedDescription ?? "Unknown reader error")
        }

        let flushed = mp3Buffer.withUnsafeMutableBufferPointer { ptr in
            lame_encode_flush(lame, ptr.baseAddress, Int32(mp3BufferSize))
        }
        guard flushed >= 0 else { throw MP3EncoderError.encoderFailed }
        if flushed > 0 { try handle.write(contentsOf: Data(mp3Buffer.prefix(Int(flushed)))) }
    }
}
