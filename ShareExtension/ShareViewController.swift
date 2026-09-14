import ConvertKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// ImportModel + ConfigView live in Shared/ConfigView.swift (compiled into both
// the app and this extension) so both drive the exact same UI.

/// Root of the share extension. Shows the config picker right away and imports
/// the file in the background. Nothing is transcoded here — the file is moved
/// (not copied) into the App Group and the app does the conversion later.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hosting: UIHostingController<AnyView>?
    private let model = ImportModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let provider = firstMovieProvider() else {
            show(AnyView(FailView(message: "No video was shared.") { [weak self] in self?.cancel() }))
            return
        }
        showConfig()          // instant
        startImport(provider) // background
    }

    private func firstMovieProvider() -> NSItemProvider? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else { return nil }
        return item.attachments?.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
    }

    // MARK: - Background import

    private func startImport(_ provider: NSItemProvider) {
        Task { [weak self] in
            do {
                let imported = try await Self.importIntoInbox(provider)
                let info = try await VideoConverter.loadSourceInfo(url: imported.url)
                await MainActor.run {
                    guard let self else { return }
                    self.model.inboxFileName = imported.url.lastPathComponent
                    self.model.originalName = imported.originalName
                    self.model.source = info
                    self.model.state = .ready
                }
            } catch {
                await MainActor.run { self?.model.state = .failed(error.localizedDescription) }
            }
        }
    }

    private struct Imported { let url: URL; let originalName: String }

    /// The most specific movie type the provider actually offers. Requesting this
    /// (e.g. `com.apple.quicktime-movie` for an HEVC clip) makes Photos hand back
    /// the ORIGINAL bytes instead of transcoding to a generic/compatible format —
    /// asking for the abstract `public.movie` can trigger an H.264 conversion.
    private static func preferredMovieType(_ provider: NSItemProvider) -> String {
        provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .movie) == true
        } ?? UTType.movie.identifier
    }

    /// Grabs the shared file and moves it into the App Group inbox. `move` makes
    /// this a near-instant rename on the same volume instead of copying the whole
    /// (possibly multi-hundred-MB) file; falls back to copy across volumes.
    private static func importIntoInbox(_ provider: NSItemProvider) async throws -> Imported {
        let typeID = preferredMovieType(provider)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Imported, Error>) in
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
                    cont.resume(returning: Imported(url: dest, originalName: originalName))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Picker + hand-off

    private func showConfig() {
        let view = ConfigView(
            model: model,
            onConvert: { [weak self] preset, resolution, frameRate in
                self?.handoff(preset: preset, resolution: resolution, frameRate: frameRate)
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        show(AnyView(view))
    }

    private func handoff(preset: Preset, resolution: TargetResolution, frameRate: TargetFrameRate) {
        guard let fileName = model.inboxFileName else { return } // ConfigView only converts when ready
        let safeName = model.originalName.replacingOccurrences(of: "/", with: "-")
        let job = ConversionJob(
            sourceFileName: fileName,
            outputBaseName: "\(safeName.isEmpty ? "video" : safeName)-\(preset.id)",
            presetID: preset.id,
            resolution: resolution,
            frameRate: frameRate
        )
        do {
            try job.write()
        } catch {
            show(AnyView(FailView(message: error.localizedDescription) { [weak self] in self?.cancel() }))
            return
        }
        openHostApp(URL(string: "\(AppGroup.urlScheme)://convert")!)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions can't call `UIApplication.shared`; walk the responder chain to
    /// find the application and open the app's URL scheme.
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }

    // MARK: - Helpers

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "QuickShareConvert", code: -1))
    }

    private func show(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let controller = UIHostingController(rootView: view)
        addChild(controller)
        controller.view.frame = self.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(controller.view)
        controller.didMove(toParent: self)
        hosting = controller
    }
}

struct FailView: View {
    let message: String
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: onDismiss).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
