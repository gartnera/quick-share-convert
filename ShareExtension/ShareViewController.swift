import ConvertKit
import SwiftUI
import UIKit

// ImportModel + ConfigView live in Shared/ (compiled into both the app and this
// extension) so both drive the exact same UI.

/// Root of the share extension. Shows the config picker right away and imports
/// the file in the background. Nothing is converted here — the file is moved
/// (not copied) into the App Group and the app does the conversion later.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hosting: UIHostingController<AnyView>?
    private let model = ImportModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let provider = firstMediaProvider() else {
            show(AnyView(FailView(message: "No video, photo, or audio file was shared.") { [weak self] in self?.cancel() }))
            return
        }
        showConfig()               // instant
        model.load(from: provider) // background
    }

    private func firstMediaProvider() -> NSItemProvider? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else { return nil }
        return item.attachments?.first { MediaKind.detect(typeIdentifiers: $0.registeredTypeIdentifiers) != nil }
    }

    // MARK: - Picker + hand-off

    private func showConfig() {
        let view = ConfigView(
            model: model,
            onConvert: { [weak self] settings in self?.handoff(settings) },
            onCancel: { [weak self] in self?.cancel() }
        )
        show(AnyView(view))
    }

    private func handoff(_ settings: ConversionSettings) {
        guard let job = model.makeJob(settings) else { return } // ConfigView only converts when ready
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
