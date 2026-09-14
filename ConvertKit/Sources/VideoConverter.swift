import AVFoundation
import CoreGraphics
import Foundation

public enum ConversionError: LocalizedError {
    case appGroupUnavailable
    case presetNotFound
    case sourceMissing
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "The App Group container is not available. Check the app's entitlements."
        case .presetNotFound: return "The selected preset could not be found."
        case .sourceMissing: return "The source video could not be found."
        case .noVideoTrack: return "The file does not contain a video track."
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

    /// Converts the source described by `job` into the App Group and returns the
    /// output URL. Convenience wrapper over ``convert(sourceURL:preset:outputURL:progress:)``.
    public func convert(job: ConversionJob, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let preset = job.preset else { throw ConversionError.presetNotFound }
        guard let source = job.sourceURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ConversionError.sourceMissing
        }
        let outDir = AppGroup.containerURL?.appendingPathComponent("Outbox", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outputURL = outDir.appendingPathComponent("\(job.outputBaseName).mp4")
        return try await convert(sourceURL: source, preset: preset, outputURL: outputURL, progress: progress)
    }

    /// The workhorse. `progress` is reported on a background queue in 0...1.
    public func convert(
        sourceURL: URL,
        preset: Preset,
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

        let (naturalSize, preferredTransform, nominalFrameRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )

        // --- Geometry (pure, unit-tested in VideoLayoutTests). ---
        let layout = VideoLayout.compute(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            preset: preset
        )
        let renderSize = layout.renderSize
        let finalTransform = layout.transform

        // --- Video composition: does the geometry AND forces SDR Rec.709. ---
        let fps = VideoLayout.outputFrameRate(sourceNominalFrameRate: nominalFrameRate, preset: preset)
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
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
                AVVideoAverageBitRateKey: preset.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ConversionError.writerFailed("cannot add video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: preset.audioBitrate,
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
