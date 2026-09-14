import ConvertKit
import Foundation
import UniformTypeIdentifiers

/// Imports a video chosen with `PHPickerViewController` into the App Group inbox.
///
/// Uses the picker result's `NSItemProvider` — which needs **no Photos
/// authorization** and works under Limited access — rather than resolving a
/// `PHAsset` (which Limited access blocks). With the picker's
/// `preferredAssetRepresentationMode = .current`, the provider yields the
/// original representation instead of a compatibility transcode.
enum PhotoLibraryImport {
    struct Imported { let inboxFileName: String; let originalName: String; let source: SourceInfo }

    static func importOriginal(from provider: NSItemProvider) async throws -> Imported {
        let imported = try await moveIntoInbox(provider)
        let source = try await VideoConverter.loadSourceInfo(url: imported.url)
        return Imported(inboxFileName: imported.url.lastPathComponent,
                        originalName: imported.originalName, source: source)
    }

    private struct Moved { let url: URL; let originalName: String }

    /// Request the provider's most-specific movie type so we get the original
    /// bytes, then move (rename) the delivered temp file into the App Group.
    private static func moveIntoInbox(_ provider: NSItemProvider) async throws -> Moved {
        let typeID = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .movie) == true
        } ?? UTType.movie.identifier

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Moved, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else {
                    cont.resume(throwing: error ?? ConversionError.sourceMissing)
                    return
                }
                guard let inbox = AppGroup.inboxURL else {
                    cont.resume(throwing: ConversionError.appGroupUnavailable)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let dest = inbox.appendingPathComponent("\(UUID().uuidString).\(ext)")
                let originalName = url.deletingPathExtension().lastPathComponent
                try? FileManager.default.removeItem(at: dest)
                do {
                    do { try FileManager.default.moveItem(at: url, to: dest) }
                    catch { try FileManager.default.copyItem(at: url, to: dest) }
                    cont.resume(returning: Moved(url: dest, originalName: originalName.isEmpty ? "video" : originalName))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
