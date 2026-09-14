import Foundation

/// Shared identifiers used to hand work between the share extension and the app.
///
/// The App Group is the pipe: the extension copies the picked video into the
/// group container and writes a `ConversionJob`; the main app reads both.
public enum AppGroup {
    /// The App Group id. Injected at build time from `BUNDLE_ID_PREFIX` via the
    /// host bundle's `AppGroupIdentifier` Info.plist key, so it stays in sync
    /// with the `.entitlements` files without hardcoding it here. Falls back to
    /// the default prefix (e.g. in unit tests, which don't touch the container).
    public static let identifier: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !value.isEmpty {
            return value
        }
        return "group.com.agartner.quickshareconvert"
    }()

    /// Custom URL scheme the extension uses to launch the app.
    public static let urlScheme = "quickshareconvert"

    /// Root of the shared container, or nil if the App Group isn't configured.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Directory where the extension drops source videos waiting to be converted.
    public static var inboxURL: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File that holds the single pending job descriptor.
    public static var pendingJobURL: URL? {
        containerURL?.appendingPathComponent("pendingJob.json", isDirectory: false)
    }
}
