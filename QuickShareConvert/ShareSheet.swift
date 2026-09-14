import SwiftUI
import UIKit

/// Thin wrapper around `UIActivityViewController` — the final destination picker.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
