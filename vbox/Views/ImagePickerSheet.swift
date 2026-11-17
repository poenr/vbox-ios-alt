import SwiftUI
import UIKit

/// iOS 15 兼容的图片选择器。
///
/// 上游用 `PhotosPicker` / `PhotosPickerItem`（SwiftUI PhotosUI，iOS 16.0+），
/// 降到 iOS 15 后改用 UIKit 原生的 `UIImagePickerController`。
struct ImagePickerSheet: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPick: (UIImage) -> Void
        let onFinish: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onPick(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
