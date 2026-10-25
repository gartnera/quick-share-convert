import Foundation
import UniformTypeIdentifiers

public extension MediaKind {
    /// The broad type a shared file must conform to for this kind.
    var utType: UTType {
        switch self {
        case .video: return .movie
        case .photo: return .image
        case .audio: return .audio
        }
    }

    /// Classifies a shared item by its registered type identifiers. Movies are
    /// checked first so a video that also advertises an image/audio type is
    /// still treated as video.
    static func detect(typeIdentifiers: [String]) -> MediaKind? {
        let types = typeIdentifiers.compactMap(UTType.init)
        return [MediaKind.video, .audio, .photo].first { kind in
            types.contains { $0.conforms(to: kind.utType) }
        }
    }

    /// The most specific registered type of this kind. Requesting it (e.g.
    /// `com.apple.quicktime-movie` or `public.heic`) gets the ORIGINAL bytes;
    /// asking for the abstract type can make Photos transcode first.
    func preferredTypeIdentifier(in typeIdentifiers: [String]) -> String {
        typeIdentifiers.first { UTType($0)?.conforms(to: utType) == true } ?? utType.identifier
    }
}

/// What we learned about a source file, per kind. Drives option gating in the UI.
public enum MediaSource: Equatable, Sendable {
    case video(SourceInfo)
    case photo(PhotoInfo)
    case audio(AudioInfo)

    public static func load(url: URL, kind: MediaKind) async throws -> MediaSource {
        switch kind {
        case .video: return .video(try await VideoConverter.loadSourceInfo(url: url))
        case .photo: return .photo(try PhotoConverter.loadSourceInfo(url: url))
        case .audio: return .audio(try AudioConverter.loadSourceInfo(url: url))
        }
    }
}

/// Runs a `ConversionJob` with the converter for its kind, writing into the
/// App Group outbox.
public final class MediaConverter {
    private let video = VideoConverter()
    private let photo = PhotoConverter()
    private let audio = AudioConverter()

    public init() {}

    public func convert(job: ConversionJob, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let source = job.sourceURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ConversionError.sourceMissing
        }
        let outDir = AppGroup.containerURL?.appendingPathComponent("Outbox", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = outDir.appendingPathComponent(job.outputBaseName)

        switch job.settings {
        case let .video(presetID, resolution, frameRate):
            guard let preset = Preset.preset(withID: presetID) else { throw ConversionError.presetNotFound }
            return try await video.convert(sourceURL: source, preset: preset,
                                           resolution: resolution, frameRate: frameRate,
                                           outputURL: base.appendingPathExtension("mp4"), progress: progress)
        case .photo(let options):
            let url = try await photo.convert(sourceURL: source, options: options,
                                              outputURL: base.appendingPathExtension(options.format.fileExtension))
            progress(1.0)
            return url
        case .audio(let options):
            return try await audio.convert(sourceURL: source, options: options,
                                           outputURL: base.appendingPathExtension(options.codec.fileExtension),
                                           progress: progress)
        }
    }
}
