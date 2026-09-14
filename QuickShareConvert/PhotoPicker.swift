import PhotosUI
import SwiftUI
import UIKit

/// System photo picker configured with the shared library so results carry an
/// `assetIdentifier` — the key that lets us fetch the untouched original via
/// PhotoKit (unlike the share sheet, which hands over an exported copy).
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (String?) -> Void   // PHAsset local identifier, or nil if none
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else { parent.onCancel(); return }
            parent.onPick(result.assetIdentifier)
        }
    }
}
