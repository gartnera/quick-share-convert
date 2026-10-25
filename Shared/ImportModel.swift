import Combine
import ConvertKit
import Foundation
import UniformTypeIdentifiers

/// Progress of pulling a file into the App Group before conversion. Shared by
/// the share extension and the app (Photos picker / Files importer), so all of
/// them drive the exact same `ConfigView`.
@MainActor
final class ImportModel: ObservableObject {
    enum State: Equatable { case importing, ready, failed(String) }
    @Published var state: State = .importing
    /// Known up front from the shared item's type, so the right options show
    /// while the file is still importing. Nil when the type isn't supported.
    @Published var kind: MediaKind?
    /// What we learned about the file once imported — used to gate options.
    @Published var source: MediaSource?

    var inboxFileName: String?
    var originalName: String = "file"

    /// Imports an item from the share sheet or Photos picker. The kind must be
    /// detectable from the provider's registered types.
    func load(from provider: NSItemProvider) {
        guard let kind = MediaKind.detect(typeIdentifiers: provider.registeredTypeIdentifiers) else {
            return failUnsupported()
        }
        begin(kind)
        run { try await InboxImport.importItem(provider, kind: kind) }
    }

    /// Imports a file picked with the Files importer (e.g. a downloaded song).
    func load(fileURL url: URL) {
        guard let kind = MediaKind.detect(typeIdentifiers: InboxImport.typeIdentifiers(of: url)) else {
            return failUnsupported()
        }
        begin(kind)
        run { try InboxImport.importFile(url, kind: kind) }
    }

    private func failUnsupported() {
        begin(nil)
        state = .failed(ConversionError.unsupportedType.localizedDescription)
    }

    /// The job for the imported file, or nil if it isn't ready yet.
    func makeJob(_ settings: ConversionSettings) -> ConversionJob? {
        guard let fileName = inboxFileName else { return nil }
        let safeName = originalName.replacingOccurrences(of: "/", with: "-")
        return ConversionJob(sourceFileName: fileName,
                             outputBaseName: "\(safeName.isEmpty ? "file" : safeName)-\(settings.nameSuffix)",
                             settings: settings)
    }

    /// Deletes the imported source (when the user cancels).
    func discard() {
        if let fileName = inboxFileName, let url = AppGroup.inboxURL?.appendingPathComponent(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
        inboxFileName = nil
    }

    /// Bumped per import so a slow earlier import can't overwrite a newer one.
    private var generation = 0

    private func begin(_ kind: MediaKind?) {
        generation += 1
        self.kind = kind
        source = nil
        inboxFileName = nil
        state = .importing
    }

    private func run(_ importer: @escaping @Sendable () async throws -> InboxImport.Imported) {
        guard let kind = self.kind else { return }
        let generation = self.generation
        Task {
            do {
                let imported = try await importer()
                let source = try await MediaSource.load(url: imported.url, kind: kind)
                guard generation == self.generation else {
                    try? FileManager.default.removeItem(at: imported.url)
                    return
                }
                inboxFileName = imported.url.lastPathComponent
                originalName = imported.originalName
                self.source = source
                state = .ready
            } catch {
                guard generation == self.generation else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Moves (or copies) a shared file into the App Group inbox, where the app
/// converts it.
enum InboxImport {
    struct Imported: Sendable { let url: URL; let originalName: String }

    /// Requests the provider's most specific type of `kind` so we get the
    /// original bytes, then moves the delivered temp file into the inbox. `move`
    /// is a near-instant rename on the same volume instead of copying a
    /// (possibly multi-hundred-MB) file; falls back to copy across volumes.
    static func importItem(_ provider: NSItemProvider, kind: MediaKind) async throws -> Imported {
        let typeID = kind.preferredTypeIdentifier(in: provider.registeredTypeIdentifiers)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Imported, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else {
                    cont.resume(throwing: error ?? ConversionError.sourceMissing)
                    return
                }
                cont.resume(with: Result { try place(url, move: true, kind: kind) })
            }
        }
    }

    /// The file's type, read while holding its security scope (on a device,
    /// files from iCloud Drive or other providers are unreadable without it,
    /// even for metadata), plus the type its extension implies as a fallback.
    static func typeIdentifiers(of url: URL) -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let content = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let byExtension = UTType(filenameExtension: url.pathExtension)
        return [content, byExtension].compactMap { $0?.identifier }
    }

    /// Copies a security-scoped URL from the Files importer into the inbox (it
    /// belongs to another app or a file provider, so it can't be moved).
    static func importFile(_ url: URL, kind: MediaKind) throws -> Imported {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try place(url, move: false, kind: kind)
    }

    private static func place(_ url: URL, move: Bool, kind: MediaKind) throws -> Imported {
        guard let inbox = AppGroup.inboxURL else { throw ConversionError.appGroupUnavailable }
        let ext = url.pathExtension.isEmpty ? (kind.utType.preferredFilenameExtension ?? "bin") : url.pathExtension
        let dest = inbox.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let originalName = url.deletingPathExtension().lastPathComponent
        try? FileManager.default.removeItem(at: dest)
        if !move || (try? FileManager.default.moveItem(at: url, to: dest)) == nil {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return Imported(url: dest, originalName: originalName.isEmpty ? "file" : originalName)
    }
}
