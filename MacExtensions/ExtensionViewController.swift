import AppKit
import ConvertKit
import SwiftUI

/// Root of both macOS extensions: the Share extension (Share menus) and the
/// Action extension (Finder › Quick Actions). Same flow as the iOS share
/// extension: show the options right away, move the file into the App Group in
/// the background, then hand the job to the app, which does the conversion.
@objc(ExtensionViewController)
final class ExtensionViewController: NSViewController {
    private var hosting: NSHostingView<AnyView>?
    private let model = ImportModel()

    override func loadView() {
        // No nib: the content is SwiftUI.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 560))
        preferredContentSize = view.frame.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        NSWorkspace.shared.open(URL(string: "\(AppGroup.urlScheme)://convert")!)
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Helpers

    private func cancel() {
        model.discard()
        // A plain completion, not cancelRequest: hosts show any cancel error
        // (even a custom-domain "cancelled" one) as a failure alert.
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func show(_ content: AnyView) {
        if let hosting {
            hosting.rootView = content
            return
        }
        let hosting = NSHostingView(rootView: content)
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        self.hosting = hosting
    }
}
