import PhotosUI
import SwiftUI
import UIKit

/// System photo picker (videos and photos). Needs no Photos authorization (works under Limited
/// access): we read the file from the result's `itemProvider`, and
/// `preferredAssetRepresentationMode = .current` avoids a compatibility transcode
/// so we get the original.
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (NSItemProvider?) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration() // no photoLibrary -> no authorization needed
        config.filter = .any(of: [.videos, .images])
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
            parent.onPick(result.itemProvider)
        }
    }
}
