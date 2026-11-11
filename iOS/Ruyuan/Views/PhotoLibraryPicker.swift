import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

/// System picker grants access only to the selected item. No library-wide permission.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onFinish: (Result<UIImage?, Error>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let finish: (Result<UIImage?, Error>) -> Void
        init(_ finish: @escaping (Result<UIImage?, Error>) -> Void) { self.finish = finish }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first else { finish(.success(nil)); return }
            // Images are decoded/downsampled on the item provider's background callback.
            item.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
                let result: Result<UIImage?, Error>
                if let error { result = .failure(error) }
                else if let data, data.count <= 30_000_000,
                        let source = CGImageSourceCreateWithData(data as CFData, nil),
                        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2560,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary) {
                    result = .success(UIImage(cgImage: cg))
                } else { result = .failure(AnalysisError.invalidImage) }
                DispatchQueue.main.async { self?.finish(result) }
            }
        }
    }
}
