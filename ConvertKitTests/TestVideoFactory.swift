import AVFoundation
import CoreVideo
import Foundation

/// Synthesizes small on-disk test clips so the converter can be exercised
/// end-to-end without shipping binary fixtures.
enum TestVideoFactory {
    static func makeVideo(size: CGSize, seconds: Double = 0.5, fps: Int32 = 30) async throws -> URL {
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

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return url
    }
}
