import AVFoundation
import CoreVideo
import Foundation

/// Synthesizes small on-disk test clips so the converter can be exercised
/// end-to-end without shipping binary fixtures.
enum TestVideoFactory {
    struct AudioSpec {
        let sampleRate: Double
        let channels: Int
    }

    static func makeVideo(size: CGSize, seconds: Double = 0.5, fps: Int32 = 30,
                          audio: AudioSpec? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if let audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: 96_000,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioInput = a
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int(seconds * Double(fps)))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, i % 2 == 0 ? 90 : 160,
                       CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()

        if let audioInput, let audio {
            let total = Int(seconds * audio.sampleRate)
            let chunk = 1024
            var start = 0
            while start < total {
                while !audioInput.isReadyForMoreMediaData { usleep(1000) }
                let n = min(chunk, total - start)
                audioInput.append(try makeAudioSampleBuffer(spec: audio, frames: n, startFrame: start))
                start += n
            }
            audioInput.markAsFinished()
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return url
    }

    /// A 16-bit interleaved PCM buffer holding a 440 Hz tone.
    private static func makeAudioSampleBuffer(spec: AudioSpec, frames: Int, startFrame: Int) throws -> CMSampleBuffer {
        let bytesPerFrame = 2 * spec.channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: spec.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(spec.channels),
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)

        var samples = [Int16](repeating: 0, count: frames * spec.channels)
        for i in 0..<frames {
            let v = Int16(sin(Double(startFrame + i) * 2 * .pi * 440 / spec.sampleRate) * 8000)
            for c in 0..<spec.channels { samples[i * spec.channels + c] = v }
        }
        let length = frames * bytesPerFrame
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: length, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: length)
        }

        let scale = CMTimeScale(spec.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: scale),
                                        decodeTimeStamp: .invalid)
        var sizeEntry = bytesPerFrame
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
                                          makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                          sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1, sampleSizeArray: &sizeEntry, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw NSError(domain: "TestVideoFactory", code: Int(status))
        }
        return sample
    }
}
