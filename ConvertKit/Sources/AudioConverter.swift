import AVFoundation
import Foundation

/// Output audio codec. AAC is lossy (bitrate applies); the rest are lossless.
/// (MP3/Opus aren't offered: Apple platforms don't ship an MP3 encoder.)
public enum AudioCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case aac, alac, flac, wav

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var isLossy: Bool { self == .aac }

    /// AVAudioFile picks the container from this.
    public var fileExtension: String {
        switch self {
        case .aac, .alac: return "m4a"
        case .flac: return "flac"
        case .wav: return "wav"
        }
    }

    var formatID: AudioFormatID {
        switch self {
        case .aac: return kAudioFormatMPEG4AAC
        case .alac: return kAudioFormatAppleLossless
        case .flac: return kAudioFormatFLAC
        case .wav: return kAudioFormatLinearPCM
        }
    }
}

/// AAC bitrate tier.
public enum AudioBitrate: Int, CaseIterable, Codable, Sendable, Identifiable {
    case kbps128 = 128_000
    case kbps192 = 192_000
    case kbps256 = 256_000

    public var id: Int { rawValue }
    public var label: String { "\(rawValue / 1000) kbps" }
}

public struct AudioOptions: Codable, Hashable, Sendable {
    public var codec: AudioCodec
    /// Only used when `codec` is lossy.
    public var bitrate: AudioBitrate

    public init(codec: AudioCodec = .aac, bitrate: AudioBitrate = .kbps256) {
        self.codec = codec
        self.bitrate = bitrate
    }
}

/// What we know about a shared audio file.
public struct AudioInfo: Equatable, Sendable {
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    /// Bits per sample for PCM/lossless sources, 0 for lossy ones.
    public let bitsPerChannel: Int
    public let formatID: AudioFormatID
    /// Average bits per second over the whole file (size / duration).
    public let dataRate: Double

    public init(duration: Double, sampleRate: Double, channels: Int, bitsPerChannel: Int,
                formatID: AudioFormatID, dataRate: Double) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.formatID = formatID
        self.dataRate = dataRate
    }

    public var isLossless: Bool {
        [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC].contains(formatID)
    }

    /// Short codec name for display, e.g. "MP3".
    public var codecName: String {
        switch formatID {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        default: return "audio"
        }
    }

    /// Default AAC tier: the lowest one at or above a lossy source's rate (no
    /// point spending 256 kbps on a 128 kbps MP3); 256 for lossless sources.
    public var suggestedBitrate: AudioBitrate {
        guard !isLossless, dataRate > 0 else { return .kbps256 }
        return AudioBitrate.allCases.first { Double($0.rawValue) >= dataRate * 0.95 } ?? .kbps256
    }
}

/// Re-encodes an audio file (anything Core Audio can decode: MP3, AAC/M4A, WAV,
/// AIFF, CAF, FLAC, ALAC, …) to AAC, ALAC, FLAC or WAV, carrying the song tags
/// and cover art over (see `AudioTags`).
///
/// AAC follows the video path's rules (44.1/48 kHz, mono or stereo); lossless
/// outputs keep the source's sample rate and channel count.
public final class AudioConverter {
    public init() {}

    public static func loadSourceInfo(url: URL) throws -> AudioInfo {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ConversionError.noAudioTrack }
        let asbd = file.fileFormat.streamDescription.pointee
        let duration = Double(file.length) / file.fileFormat.sampleRate
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AudioInfo(duration: duration,
                         sampleRate: asbd.mSampleRate,
                         channels: Int(asbd.mChannelsPerFrame),
                         bitsPerChannel: Int(asbd.mBitsPerChannel),
                         formatID: asbd.mFormatID,
                         dataRate: duration > 0 ? Double(bytes) * 8 / duration : 0)
    }

    /// Output settings for `options` given the source (exposed for tests).
    static func outputSettings(_ options: AudioOptions, source: AudioInfo) -> [String: Any] {
        let codec = options.codec
        var settings: [String: Any] = [AVFormatIDKey: codec.formatID]
        if codec.isLossy {
            settings[AVSampleRateKey] = Bitrate.audioSampleRate(source: source.sampleRate)
            settings[AVNumberOfChannelsKey] = Bitrate.audioChannels(source: source.channels)
            settings[AVEncoderBitRateKey] = options.bitrate.rawValue
        } else {
            // Lossy sources carry no bit depth; 16-bit is plenty for them.
            let depth = source.bitsPerChannel > 16 ? 24 : 16
            settings[AVSampleRateKey] = source.sampleRate
            settings[AVNumberOfChannelsKey] = max(1, source.channels)
            if codec == .wav {
                settings[AVLinearPCMBitDepthKey] = depth
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = false
                settings[AVLinearPCMIsNonInterleaved] = false
            } else {
                settings[AVEncoderBitDepthHintKey] = depth
            }
        }
        return settings
    }

    /// `progress` is reported on the calling task's thread in 0...1.
    public func convert(sourceURL: URL, options: AudioOptions, outputURL: URL,
                        progress: @escaping (Double) -> Void) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        let info = try Self.loadSourceInfo(url: sourceURL)
        let input = try AVAudioFile(forReading: sourceURL)

        // Decode to the source's float processing format; Core Audio converts
        // (sample rate, channels, codec) on the way into the output file.
        let format = input.processingFormat
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: outputURL, settings: Self.outputSettings(options, source: info),
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            throw ConversionError.writerFailed(error.localizedDescription)
        }

        let total = max(Double(input.length), 1)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ConversionError.readerFailed("could not allocate audio buffer")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            do { try input.read(into: buffer, frameCount: chunk) } catch {
                throw ConversionError.readerFailed(error.localizedDescription)
            }
            if buffer.frameLength == 0 { break }
            do { try output.write(from: buffer) } catch {
                throw ConversionError.writerFailed(error.localizedDescription)
            }
            progress(min(0.99, Double(input.framePosition) / total))
        }
        // AVAudioFile finalizes the file (headers, packet table) on close.
        output.close()

        // Carry the song tags + cover art over. Best effort: an untaggable file
        // is still a good conversion.
        try? await AudioTags.read(from: sourceURL).write(to: outputURL)
        progress(1.0)
        return outputURL
    }
}
