import ConvertKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Root of the share extension. Loads the shared video, shows the preset picker,
/// then copies the file into the App Group, records a job, and launches the app
/// to do the (memory-heavy) conversion and present the final share sheet.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hosting: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        show(AnyView(LoadingView()))
        loadSharedVideo()
    }

    // MARK: - Loading the incoming item

    private func loadSharedVideo() {
        guard let item = (extensionContext?.inputItems.first as? NSExtensionItem),
              let provider = item.attachments?.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
              }) else {
            fail("No video was shared.")
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { return }
            guard let url, error == nil else {
                DispatchQueue.main.async { self.fail(error?.localizedDescription ?? "Could not read the video.") }
                return
            }
            // The provided URL is a short-lived temp file; copy it into the App
            // Group inbox now, while it's still valid.
            let result = Self.copyIntoInbox(from: url)
            DispatchQueue.main.async {
                switch result {
                case .success(let inboxURL):
                    self.showPicker(sourceFileName: inboxURL.lastPathComponent,
                                    originalName: url.deletingPathExtension().lastPathComponent)
                case .failure(let err):
                    self.fail(err.localizedDescription)
                }
            }
        }
    }

    private static func copyIntoInbox(from url: URL) -> Result<URL, Error> {
        guard let inbox = AppGroup.inboxURL else {
            return .failure(ConversionError.appGroupUnavailable)
        }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let dest = inbox.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Picker

    private func showPicker(sourceFileName: String, originalName: String) {
        let view = PresetPickerView(
            onSelect: { [weak self] preset in
                self?.handoff(sourceFileName: sourceFileName, originalName: originalName, preset: preset)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: "QuickShareConvert", code: -1))
            }
        )
        show(AnyView(view))
    }

    private func handoff(sourceFileName: String, originalName: String, preset: Preset) {
        let safeName = originalName.replacingOccurrences(of: "/", with: "-")
        let job = ConversionJob(
            sourceFileName: sourceFileName,
            outputBaseName: "\(safeName.isEmpty ? "video" : safeName)-\(preset.id)",
            presetID: preset.id
        )
        do {
            try job.write()
        } catch {
            fail(error.localizedDescription)
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

    private func fail(_ message: String) {
        show(AnyView(FailView(message: message) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "QuickShareConvert", code: -1))
        }))
    }

    private func show(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let controller = UIHostingController(rootView: view)
        addChild(controller)
        controller.view.frame = view is EmptyView ? .zero : self.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(controller.view)
        controller.didMove(toParent: self)
        hosting = controller
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading video…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailView: View {
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
