import SwiftUI
import UIKit

struct FileShareSheet: UIViewControllerRepresentable {
    let session: PreparedPhotoShare
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: session.urls, applicationActivities: nil)
        controller.overrideUserInterfaceStyle = .dark
        // Destinations may still be copying resources after the SwiftUI sheet changes state.
        // The activity controller retains its files through completion, independently of the grid.
        controller.completionWithItemsHandler = { [session] _, _, _, _ in withExtendedLifetime(session) {} }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
