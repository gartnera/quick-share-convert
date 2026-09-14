import ConvertKit
import Foundation
import Photos
import UniformTypeIdentifiers

/// Pulls the UNTOUCHED original video resource for a picked asset straight into
/// the App Group inbox via PhotoKit — no Photos-side export/transcode, so the
/// true codec/resolution/frame rate survive. This is the app-only path (the
/// share extension can't get a PHAsset identifier).
enum PhotoLibraryImport {
    struct Imported { let inboxFileName: String; let originalName: String; let source: SourceInfo }

    static func importOriginal(assetID: String) async throws -> Imported {
        guard await ensureAuthorized() else { throw ConversionError.sourceMissing }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw ConversionError.sourceMissing
        }
        // `.video` is the untouched capture (reveals the true frame rate);
        // fall back to the rendered edit or whatever exists.
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first else {
            throw ConversionError.noVideoTrack
        }
        guard let inbox = AppGroup.inboxURL else { throw ConversionError.appGroupUnavailable }

        let ext = UTType(res.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"
        let dest = inbox.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // download from iCloud if needed
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: res, toFile: dest, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        let source = try await VideoConverter.loadSourceInfo(url: dest)
        let name = (res.originalFilename as NSString).deletingPathExtension
        return Imported(inboxFileName: dest.lastPathComponent,
                        originalName: name.isEmpty ? "video" : name,
                        source: source)
    }

    private static func ensureAuthorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    cont.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }
}
