import Foundation

/// A unit of work handed from the share extension to the main app.
///
/// The extension copies the picked video into the App Group inbox and writes one
/// of these to `AppGroup.pendingJobURL`. The app reads it, converts, and clears it.
public struct ConversionJob: Codable, Sendable {
    /// File name (not full path) of the source video inside `AppGroup.inboxURL`.
    public let sourceFileName: String
    /// Preferred output file name (without extension) for the converted result.
    public let outputBaseName: String
    /// Chosen preset id (see `Preset.all`).
    public let presetID: String
    public let resolution: TargetResolution
    public let frameRate: TargetFrameRate
    public let createdAt: Date

    public init(sourceFileName: String, outputBaseName: String, presetID: String,
                resolution: TargetResolution, frameRate: TargetFrameRate, createdAt: Date = Date()) {
        self.sourceFileName = sourceFileName
        self.outputBaseName = outputBaseName
        self.presetID = presetID
        self.resolution = resolution
        self.frameRate = frameRate
        self.createdAt = createdAt
    }

    public var preset: Preset? { Preset.preset(withID: presetID) }

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
