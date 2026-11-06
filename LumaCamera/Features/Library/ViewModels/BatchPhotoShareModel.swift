import Foundation
import Combine

final class PreparedPhotoShare: Identifiable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
    init(directory: URL, urls: [URL]) { self.directory = directory; self.urls = urls }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class BatchPhotoShareModel: ObservableObject {
    @Published private(set) var preparing = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published var prepared: PreparedPhotoShare?
    @Published var message: String?
    private var generation = UUID()
    private var request: PhotoImageRequest?
    private var directory: URL?
    deinit { request?.cancel(); if let directory { try? FileManager.default.removeItem(at: directory) } }

    func prepare(photos: [LibraryPhoto], service: PhotoFileExportService) {
        guard !preparing, prepared == nil, !photos.isEmpty else { return }
        let token = UUID(); generation = token
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoShare-" + token.uuidString)
        directory = folder; preparing = true; completedCount = 0; totalCount = photos.count; message = nil
        exportNext(photos: photos, index: 0, urls: [], folder: folder, service: service, token: token)
    }
    private func exportNext(photos: [LibraryPhoto], index: Int, urls: [URL], folder: URL, service: PhotoFileExportService, token: UUID) {
        guard generation == token else { return }
        if index == photos.count {
            request = nil; directory = nil; preparing = false
            prepared = PreparedPhotoShare(directory: folder, urls: urls)
            return
        }
        // Isolate equal original filenames and export sequentially to bound memory/network use.
        let next = service.exportPhoto(id: photos[index].id, directory: folder.appendingPathComponent(String(index))) { [weak self] result in
            // Deferring also supports synchronous errors without retaining an obsolete request.
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.request = nil
                switch result {
                case .success(let url):
                    self.completedCount = index + 1
                    self.exportNext(photos: photos, index: index + 1, urls: urls + [url], folder: folder, service: service, token: token)
                case .failure(let error):
                    self.cancelPreparation()
                    self.message = "第 \(index + 1) 张照片准备失败：\(error.localizedDescription)"
                }
            }
        }
        request = next
    }
    func cancelPreparation() {
        generation = UUID(); request?.cancel(); request = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; preparing = false
    }
}
