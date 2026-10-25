import AVFoundation
import CoreGraphics
import Foundation

public enum ConversionError: LocalizedError {
    case appGroupUnavailable
    case presetNotFound
    case sourceMissing
    case noVideoTrack
    case noAudioTrack
    case unreadableImage
    case unsupportedType
    case encoderUnavailable(String)
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "The App Group container is not available. Check the app's entitlements."
        case .presetNotFound: return "The selected preset could not be found."
        case .sourceMissing: return "The source file could not be found."
        case .noVideoTrack: return "The file does not contain a video track."
        case .noAudioTrack: return "The file isn't audio this device can decode."
        case .unreadableImage: return "The file isn't an image this device can decode."
        case .unsupportedType: return "Only videos, photos, and audio files can be converted."
        case .encoderUnavailable(let f): return "This device can't encode \(f)."
        case .readerFailed(let m): return "Could not read the video: \(m)"
        case .writerFailed(let m): return "Could not write the video: \(m)"
        case .cancelled: return "Conversion was cancelled."
        }
    }
}

/// Transcodes a video to a preset: H.264 + AAC in an MP4, always tone-mapped to
/// SDR (Rec.709) so HDR is stripped, scaled/cropped per the preset's framing.
///
/// Pure AVFoundation and platform-agnostic, so the same engine drives the iOS
/// app today and the macOS app later.
public final class VideoConverter {
    public init() {}

    /// Reads the source geometry + frame rate so callers (the share extension) can
    /// gate which resolution/frame-rate options to offer.
    public static func loadSourceInfo(url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return SourceInfo(orientedSize: CGSize(width: abs(rect.width), height: abs(rect.height)),
                          nominalFrameRate: fps)
    }

    /// The workhorse. `progress` is reported on a background queue in 0...1.
    public func convert(
        sourceURL: URL,
        preset: Preset,
        resolution: TargetResolution,
        frameRate: TargetFrameRate,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let (naturalSize, preferredTransform, nominalFrameRate, minFrameDuration) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration
        )
        let (sourceDataRate, videoFormats) = try await videoTrack.load(.estimatedDataRate, .formatDescriptions)
        let sourceIsHEVC = videoFormats.first.map {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC
        } ?? false

        // --- Geometry (pure, unit-tested in VideoLayoutTests). ---
        let layout = VideoLayout.compute(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            targetSize: preset.outputSize(for: resolution),
            framing: preset.framing
        )
        let renderSize = layout.renderSize
        let finalTransform = layout.transform
        let videoBitrate = Bitrate.forOutput(renderSize: renderSize, resolution: resolution, frameRate: frameRate,
                                             sourceDataRate: sourceDataRate, sourceIsHEVC: sourceIsHEVC)

        // --- Video composition: does the geometry AND forces SDR Rec.709. ---
        let fps = VideoLayout.outputFrameRate(sourceNominalFrameRate: nominalFrameRate, target: frameRate)
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = VideoLayout.outputFrameDuration(
            sourceNominalFrameRate: nominalFrameRate, sourceMinFrameDuration: minFrameDuration, target: frameRate
        )
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(finalTransform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        // --- Reader ---
        let reader = try AVAssetReader(asset: asset)
        // Requesting 8-bit output alongside the Rec.709 composition tone-maps HDR.
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ConversionError.readerFailed("cannot add video output") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
        }

        // --- Writer ---
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
                // Required with an AutoLevel profile / >30fps sources, otherwise the
                // encoder may drop frames to satisfy level constraints.
                AVVideoExpectedSourceFrameRateKey: fps,
                // Closed GOP no longer than 2s: what Instagram/YouTube ask for and
                // what keeps seeking snappy after their re-encode.
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ConversionError.writerFailed("cannot add video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil, let audioTrack {
            // Follow the source: 48 kHz camera audio stays 48 kHz (no resample to
            // 44.1), mono stays mono. Anything exotic normalizes to 48 kHz stereo.
            let asbd = try await audioTrack.load(.formatDescriptions).first
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Bitrate.audioSampleRate(source: asbd?.mSampleRate ?? 48_000),
                AVNumberOfChannelsKey: Bitrate.audioChannels(source: Int(asbd?.mChannelsPerFrame ?? 2)),
                AVEncoderBitRateKey: Bitrate.audio,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard reader.startReading() else {
            throw ConversionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.001)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            group.enter()
            let videoQueue = DispatchQueue(label: "convertkit.video")
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sample = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    progress(min(0.99, max(0, pts / totalSeconds)))
                    if !videoInput.append(sample) {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput, let audioOutput {
                group.enter()
                let audioQueue = DispatchQueue(label: "convertkit.audio")
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard reader.status == .reading,
                              let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if !audioInput.append(sample) {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if reader.status == .failed {
                    continuation.resume(throwing: ConversionError.readerFailed(
                        reader.error?.localizedDescription ?? "unknown"))
                    return
                }
                writer.finishWriting {
                    switch writer.status {
                    case .completed:
                        progress(1.0)
                        continuation.resume(returning: ())
                    case .cancelled:
                        continuation.resume(throwing: ConversionError.cancelled)
                    default:
                        continuation.resume(throwing: ConversionError.writerFailed(
                            writer.error?.localizedDescription ?? "unknown"))
                    }
                }
            }
        }

        return outputURL
    }
}
