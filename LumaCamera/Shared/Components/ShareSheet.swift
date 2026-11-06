import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    var resources: [PhotoResource] = []
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var items: [Any] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for resource in resources {
                let url = folder.appendingPathComponent(resource.filename)
                try resource.data.write(to: url); items.append(url)
            }
        } catch { items = [] }
        let controller = UIActivityViewController(activityItems: items.isEmpty ? [image] : items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
