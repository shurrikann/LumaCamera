import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit

struct AstroRecoveryItem: Codable, Identifiable {
    let id: UUID
    let kind: String
    let created: Date
    var fileName: String?
    var phase = "capturing"
    var options: AstroImageOptions
    var isVideo: Bool { kind == "星空延时" }
}

/// Serialized durable journal. A manifest only points at a fully written image;
/// MOV fragments remain in Application Support until imported or discarded.
final class AstroRecoveryJournal: @unchecked Sendable {
    static let shared = AstroRecoveryJournal(root: {
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS"] == "1" {
            return FileManager.default.temporaryDirectory.appendingPathComponent("AstroRecovery-Tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AstroRecovery", isDirectory: true)
    }())
    let root: URL
    private let queue = DispatchQueue(label: "camera.astro.recovery", qos: .utility)
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    init(root: URL) { self.root = root }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { directory(id).appendingPathComponent("record.json") }
    private func write(_ item: AstroRecoveryItem) throws {
        try FileManager.default.createDirectory(at: directory(item.id), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(item).write(to: manifest(item.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func begin(_ item: AstroRecoveryItem) { queue.async { try? self.write(item) } }
    func url(for item: AstroRecoveryItem) -> URL? {
        guard let name = item.fileName, name == (name as NSString).lastPathComponent else { return nil }
        return directory(item.id).appendingPathComponent(name)
    }
    func videoURL(id: UUID) throws -> URL {
        try queue.sync {
            var item = try JSONDecoder().decode(AstroRecoveryItem.self, from: Data(contentsOf: manifest(id)))
            item.fileName = "capture.mov"
            try write(item)
            return directory(id).appendingPathComponent("capture.mov")
        }
    }
    func image(id: UUID, image: CIImage, options: AstroImageOptions, final: Bool,
               completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                var item = try JSONDecoder().decode(AstroRecoveryItem.self, from: Data(contentsOf: self.manifest(id)))
                guard let cg = self.context.createCGImage(image, from: image.extent),
                      let data = AstroImageEncoder.encode(cg, options: options) else { throw Failure.encoding }
                let previous = self.url(for: item)
                let file = self.directory(id).appendingPathComponent(UUID().uuidString + "." + options.format.fileExtension)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                item.options = options; item.fileName = file.lastPathComponent
                item.phase = final ? "ready" : "capturing"
                try self.write(item)
                if let previous, previous != file { try? FileManager.default.removeItem(at: previous) }
                completion(.success(file))
            } catch { completion(.failure(error)) }
        }
    }
    func markReady(id: UUID, file: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                var item = try JSONDecoder().decode(AstroRecoveryItem.self, from: Data(contentsOf: self.manifest(id)))
                guard file.deletingLastPathComponent().standardizedFileURL == self.directory(id).standardizedFileURL else { throw Failure.invalidFile }
                item.fileName = file.lastPathComponent; item.phase = "ready"
                try self.write(item); completion(.success(file))
            } catch { completion(.failure(error)) }
        }
    }
    func phase(id: UUID, value: String) {
        queue.sync {
            guard var item = try? JSONDecoder().decode(AstroRecoveryItem.self, from: Data(contentsOf: manifest(id))) else { return }
            item.phase = value; try? write(item)
        }
    }
    func items(completion: @escaping ([AstroRecoveryItem]) -> Void) {
        queue.async {
            let folders = (try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)) ?? []
            let items = folders.compactMap { folder -> AstroRecoveryItem? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                      let item = try? JSONDecoder().decode(AstroRecoveryItem.self, from: data),
                      folder.lastPathComponent == item.id.uuidString, let file = self.url(for: item),
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
                return item
            }
            completion(items.sorted { $0.created < $1.created })
        }
    }
    func remove(_ id: UUID) { queue.async { try? FileManager.default.removeItem(at: self.directory(id)) } }
    enum Failure: LocalizedError {
        case encoding, invalidFile
        var errorDescription: String? { self == .encoding ? "星空恢复文件编码失败" : "恢复文件不可用" }
    }
}

@MainActor final class AstroRecoveryStore: ObservableObject {
    static let shared = AstroRecoveryStore(journal: .shared)
    @Published private(set) var items: [AstroRecoveryItem] = []
    @Published private(set) var busy: UUID?
    @Published var message: String?
    let didImportCapture = PassthroughSubject<String, Never>()
    let journal: AstroRecoveryJournal
    private var active = Set<UUID>()
    private var expired = Set<UUID>()
    private var tasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var checkpointTimes: [UUID: Double] = [:]
    private var pending = Set<UUID>()
    private var imported = Set<UUID>()
    func wasImported(_ id: UUID) -> Bool { imported.contains(id) }
    var diagnosticOnly: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS"] == "1"
    }
    init(journal: AstroRecoveryJournal) { self.journal = journal }
    func begin(kind: String, options: AstroImageOptions) -> UUID {
        let id = UUID(); active.insert(id)
        journal.begin(AstroRecoveryItem(id: id, kind: kind, created: Date(), options: options))
        return id
    }
    func protect(_ id: UUID) {
        guard tasks[id] == nil, !expired.contains(id) else { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save star capture") { [weak self] in
            Task { @MainActor in
                self?.expirationReached(id)
            }
        }
        if token != .invalid { tasks[id] = token }
    }
    func expirationReached(_ id: UUID) {
        expired.insert(id); active.remove(id); end(id); reload()
    }
    private func end(_ id: UUID) {
        if let token = tasks.removeValue(forKey: id) { UIApplication.shared.endBackgroundTask(token) }
    }
    func reload() {
        journal.items { [weak self] records in Task { @MainActor in
            guard let self else { return }; self.items = records.filter { !self.active.contains($0.id) }
        } }
    }
    func checkpoint(id: UUID, image: CIImage, options: AstroImageOptions, final: Bool = false) {
        let now = CACurrentMediaTime()
        guard final || (!pending.contains(id) && now - (checkpointTimes[id] ?? -.infinity) >= 5) else { return }
        pending.insert(id); checkpointTimes[id] = now
        journal.image(id: id, image: image, options: options, final: final) { [weak self] result in Task { @MainActor in
            guard let self else { return }; self.pending.remove(id)
            if case .failure(let error) = result { self.message = error.localizedDescription }
        } }
    }
    func keep(_ id: UUID) { active.remove(id); end(id); reload() }
    func discard(_ id: UUID) {
        active.remove(id); checkpointTimes.removeValue(forKey: id); end(id); journal.remove(id); reload()
    }
    func saveImage(id: UUID, image: CGImage, options: AstroImageOptions,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        protect(id)
        journal.image(id: id, image: CIImage(cgImage: image), options: options, final: true) { [weak self] result in Task { @MainActor in
            guard let self else { return }
            switch result {
            case .success(let file): self.importFile(id: id, file: file, video: false, captureOptions: options, opensReview: true, completion: completion)
            case .failure: self.keep(id); completion(result)
            }
        } }
    }
    func saveVideo(id: UUID, file: URL, opensReview: Bool = true, completion: @escaping (Result<URL, Error>) -> Void) {
        protect(id)
        journal.markReady(id: id, file: file) { [weak self] result in Task { @MainActor in
            guard let self else { return }
            switch result {
            case .success(let file): self.importFile(id: id, file: file, video: true, opensReview: opensReview, completion: completion)
            case .failure: self.keep(id); completion(result)
            }
        } }
    }
    private func importFile(id: UUID, file: URL, video: Bool, captureOptions: AstroImageOptions? = nil,
                            opensReview: Bool = false,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        guard !diagnosticOnly, !expired.contains(id) else { keep(id); completion(.success(file)); return }
        journal.phase(id: id, value: "importing")
        var assetID: String?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = captureOptions?.parameters?.capturedAt
            if let location = captureOptions?.parameters?.location, location.isValid {
                request.location = location.clLocation
            }
            let options = PHAssetResourceCreationOptions(); options.originalFilename = "Luma-" + file.lastPathComponent
            request.addResource(with: video ? .video : .photo, fileURL: file, options: options)
            assetID = request.placeholderForCreatedAsset?.localIdentifier
        }) { [weak self] success, error in Task { @MainActor in
            guard let self else { return }
            if success {
                if let assetID, let diagnostics = captureOptions?.diagnostics {
                    PhotoCaptureDiagnosticsStore.shared.save(diagnostics, assetID: assetID)
                }
                if opensReview, let assetID { self.didImportCapture.send(assetID) }
                self.imported.insert(id)
                self.discard(id)
                completion(.success(file))
            }
            else { self.journal.phase(id: id, value: "ready"); self.keep(id); completion(.failure(error ?? AstroRecoveryJournal.Failure.invalidFile)) }
        } }
    }
    func recover(_ item: AstroRecoveryItem) {
        guard busy == nil, let file = journal.url(for: item) else { return }
        busy = item.id; message = nil; expired.remove(item.id); protect(item.id)
        let done: (Result<URL, Error>) -> Void = { [weak self] result in
            self?.busy = nil
            if case .failure(let error) = result { self?.message = error.localizedDescription }
        }
        if item.isVideo, item.phase != "ready" {
            // Remux complete movie fragments; passthrough never re-encodes video.
            let asset = AVURLAsset(url: file)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                keep(item.id); done(.failure(AstroRecoveryJournal.Failure.invalidFile)); return
            }
            let output = file.deletingLastPathComponent().appendingPathComponent("recovered-\(UUID().uuidString).mov")
            Task { @MainActor [weak self] in
                do {
                    try await export.export(to: output, as: .mov)
                    guard let self else { return }
                    self.saveVideo(id: item.id, file: output, opensReview: false, completion: done)
                } catch {
                    guard let self else { return }
                    self.keep(item.id); done(.failure(error))
                }
            }

        } else { importFile(id: item.id, file: file, video: item.isVideo, captureOptions: item.options, completion: done) }
    }
}
