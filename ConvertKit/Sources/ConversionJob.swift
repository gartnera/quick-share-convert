import Foundation

/// The kind of media being converted; decides which converter and options apply.
public enum MediaKind: String, Codable, Sendable {
    case video, photo, audio
}

/// What to produce, per media kind.
public enum ConversionSettings: Codable, Hashable, Sendable {
    /// Re-frame to a preset's aspect at a resolution + frame rate (H.264/AAC MP4).
    case video(presetID: String, resolution: TargetResolution, frameRate: TargetFrameRate)
    /// Keep the photo's aspect; re-encode (and optionally downscale) it.
    case photo(PhotoOptions)
    /// Re-encode an audio file to AAC in an .m4a.
    case audio(AudioOptions)

    public var kind: MediaKind {
        switch self {
        case .video: return .video
        case .photo: return .photo
        case .audio: return .audio
        }
    }

    /// Appended to the source name for the output file, e.g. "clip-ig.reels".
    public var nameSuffix: String {
        switch self {
        case .video(let presetID, _, _): return presetID
        case .photo(let o): return o.size.nameTag
        case .audio(let o): return o.codec.isLossy ? "\(o.bitrate.rawValue / 1000)k" : o.codec.rawValue
        }
    }

    /// Shown while converting, e.g. "Converting for Reels / Stories".
    public var progressTitle: String {
        switch self {
        case .video(let presetID, _, _):
            return "Converting for \(Preset.preset(withID: presetID)?.name ?? "video")"
        case .photo: return "Compressing photo"
        case .audio: return "Converting audio"
        }
    }
}

/// A unit of work handed from the share extension to the main app.
///
/// The extension copies the picked file into the App Group inbox and writes one
/// of these to `AppGroup.pendingJobURL`. The app reads it, converts, and clears it.
public struct ConversionJob: Codable, Sendable {
    /// File name (not full path) of the source file inside `AppGroup.inboxURL`.
    public let sourceFileName: String
    /// Preferred output file name (without extension) for the converted result.
    public let outputBaseName: String
    public let settings: ConversionSettings
    public let createdAt: Date

    public init(sourceFileName: String, outputBaseName: String, settings: ConversionSettings,
                createdAt: Date = Date()) {
        self.sourceFileName = sourceFileName
        self.outputBaseName = outputBaseName
        self.settings = settings
        self.createdAt = createdAt
    }

    public var sourceURL: URL? {
        AppGroup.inboxURL?.appendingPathComponent(sourceFileName)
    }

    // MARK: - Persistence

    public func write() throws {
        guard let url = AppGroup.pendingJobURL else { throw ConversionError.appGroupUnavailable }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func readPending() -> ConversionJob? {
        guard let url = AppGroup.pendingJobURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversionJob.self, from: data)
    }

    public static func clearPending() {
        guard let url = AppGroup.pendingJobURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
