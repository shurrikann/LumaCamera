import Photos
import UIKit

final class SystemPhotoLibraryService: NSObject, PhotoLibraryService, PhotoBrowserService, PHPhotoLibraryChangeObserver {
    var onLibraryChange: (() -> Void)?
    private let imageManager = PHCachingImageManager()
    private let savingQueue = DispatchQueue(label: "photos.save", qos: .userInitiated)
    private let browsingQueue = DispatchQueue(label: "photos.browse", qos: .userInitiated)
    private let availabilityQueue = DispatchQueue(label: "photos.availability", qos: .userInitiated)
    private let metadataLock = NSLock()
    private var metadataRevision: UInt64 = 0
    private var rawCache: [String: (modified: Date?, raw: Bool)] = [:]
    private var observing = false
    // PhotoKit observes the lifetime of fetched results, not our copied LibraryPhoto values.
    // Access this result only on browsingQueue. Keep the full query, including when it is empty.
    private var observedAssets: PHFetchResult<PHAsset>?
    var existingAccess: PhotoLibraryAccess? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return nil
        default: return .denied
        }
    }

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                if status == .authorized || status == .limited, !self.observing {
                    PHPhotoLibrary.shared().register(self)
                    self.observing = true
                }
                completion(status == .authorized ? .full : status == .limited ? .limited : .denied)
            }
        }
    }

    private func photoMetadata(_ asset: PHAsset) -> LibraryPhoto {
        metadataLock.lock()
        let cached = rawCache[asset.localIdentifier]
        metadataLock.unlock()
        let raw: Bool
        if asset.mediaType == .video { raw = false }
        else if let cached, cached.modified == asset.modificationDate { raw = cached.raw }
        else {
            raw = PHAssetResource.assetResources(for: asset).contains {
                PhotoResourceKind.isRAW(typeIdentifier: $0.uniformTypeIdentifier, filename: $0.originalFilename)
            }
            metadataLock.lock()
            if rawCache.count > 5000 { rawCache.removeAll(keepingCapacity: true) }
            rawCache[asset.localIdentifier] = (asset.modificationDate, raw)
            metadataLock.unlock()
        }
        let badges = asset.mediaType == .video ? VideoCaptureBadgeStore.shared.badges(assetID: asset.localIdentifier) : nil
        return LibraryPhoto(id: asset.localIdentifier, date: asset.creationDate, isRAW: raw,
            location: asset.location.flatMap(PhotoLocation.recorded), isLive: asset.mediaSubtypes.contains(.photoLive),
            isNightComposite: asset.mediaType == .image && PhotoCaptureDiagnosticsStore.shared.isNightComposite(assetID: asset.localIdentifier),
            hasFilter: badges?.hasFilter ?? PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID: asset.localIdentifier),
            isVideo: asset.mediaType == .video,
            duration: asset.mediaType == .video ? asset.duration : nil, logLabel: badges?.logLabel, videoBadges: badges)
    }

    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) {
        let thumbnailOnly = offset == 0 && limit == 1
        metadataLock.lock()
        if !thumbnailOnly { metadataRevision &+= 1 }
        let revision = metadataRevision
        metadataLock.unlock()
        let workQueue = thumbnailOnly ? availabilityQueue : browsingQueue
        workQueue.async {
            func isCurrent() -> Bool {
                guard !thumbnailOnly else { return true }
                self.metadataLock.lock(); defer { self.metadataLock.unlock() }
                return self.metadataRevision == revision
            }
            func cancelled() { DispatchQueue.main.async { completion(PhotoPage(photos: [], hasMore: false)) } }
            guard isCurrent() else { cancelled(); return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: options)
            let start = min(max(0, offset), assets.count)
            let end = min(start + max(0, limit), assets.count)
            var photos: [LibraryPhoto] = []; photos.reserveCapacity(end - start)
            for index in start..<end {
                if index % 10 == 0, !isCurrent() { cancelled(); return }
                photos.append(self.photoMetadata(assets.object(at: index)))
            }
            guard isCurrent() else { cancelled(); return }
            if thumbnailOnly { self.browsingQueue.async { self.observedAssets = assets } }
            else { self.observedAssets = assets }
            let page = PhotoPage(photos: photos, hasMore: end < assets.count)
            DispatchQueue.main.async { completion(page) }
        }
    }

    /// Identifier-only reconciliation bypasses expensive metadata work already queued.
    func availablePhotoIDs(_ ids: [String], completion: @escaping (Set<String>?) -> Void) {
        availabilityQueue.async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var result = Set<String>()
            assets.enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
            let available = result
            DispatchQueue.main.async { completion(available) }
        }
    }

    func photoAvailability(id: String, completion: @escaping (PhotoAssetAvailability) -> Void) {
        availabilityQueue.async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil
            // A limited/denied library cannot prove that an inaccessible photograph was deleted.
            let result: PhotoAssetAvailability = found ? .available : status == .authorized ? .missing : .unknown
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func imageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        // 系统相册默认只给 SDR 基底；应用相册必须显式请求增益图 HDR。
        // 不读取 currentEDRHeadroom：请求瞬间它可能仍是1.0，PhotoKit 就会
        // 返回 tone map 后的 SDR，表现为“有时刷新不出 HDR”。
        if #available(iOS 17.0, *) {
            options.preferHDR = true
            options.targetHDRHeadroom = 4.0
        }
        return options
    }

    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            completion(nil, PhotoLibraryError.inaccessible)
            return PhotoImageRequest(cancel: {})
        }
        let options = Self.imageRequestOptions()
        let requestID = imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
            guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
            let error = info?[PHImageErrorKey] as? Error
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            DispatchQueue.main.async {
                if image != nil || error != nil || !degraded { completion(image, error) }
            }
        }
        return PhotoImageRequest { [weak self] in self?.imageManager.cancelImageRequest(requestID) }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        browsingQueue.async { [weak self] in
            guard let self else { return }
            if let assets = self.observedAssets, let changes = changeInstance.changeDetails(for: assets) {
                self.observedAssets = changes.fetchResultAfterChanges
            }
            DispatchQueue.main.async { [weak self] in self?.onLibraryChange?() }
        }
    }

    func canReloadSavedPhoto(id: String) -> Bool {
        guard let access = existingAccess, access != .denied else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil
    }

    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.writeDenied)) }
                return
            }
            var assetID: String?
            PHPhotoLibrary.shared().performChanges({
                assetID = PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                DispatchQueue.main.async {
                    if success, let assetID { completion(.success(assetID)) }
                    else { completion(.failure(error ?? PhotoLibraryError.missingIdentifier)) }
                }
            }
        }
    }

    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.writeDenied)) }
                return
            }
            var assetID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
                assetID = request.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                DispatchQueue.main.async {
                    if success, let assetID { completion(.success(assetID)) }
                    else { completion(.failure(error ?? PhotoLibraryError.missingIdentifier)) }
                }
            }
        }
    }

    func saveLivePhoto(stillImage: Data, movieURL: URL, location: PhotoLocation?, creationDate: Date?, completion: @escaping (Result<String, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.writeDenied)) }
                return
            }
            self.savingQueue.async {
                let stagedMovie = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhoto-Paired-" + UUID().uuidString + ".mov")
                do { try FileManager.default.copyItem(at: movieURL, to: stagedMovie) }
                catch { DispatchQueue.main.async { completion(.failure(error)) }; return }
                var assetID: String?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    if let location, location.isValid { request.location = location.clLocation }
                    request.creationDate = creationDate
                    let photoOptions = PHAssetResourceCreationOptions()
                    photoOptions.originalFilename = "Luma-Live-\(UUID().uuidString).jpg"
                    photoOptions.uniformTypeIdentifier = "public.jpeg"
                    request.addResource(with: .photo, data: stillImage, options: photoOptions)
                    let movieOptions = PHAssetResourceCreationOptions()
                    movieOptions.originalFilename = "Luma-Live-Motion-\(UUID().uuidString).mov"
                    movieOptions.uniformTypeIdentifier = "com.apple.quicktime-movie"
                    movieOptions.shouldMoveFile = false
                    request.addResource(with: .pairedVideo, fileURL: stagedMovie, options: movieOptions)
                    assetID = request.placeholderForCreatedAsset?.localIdentifier
                }) { success, error in
                    try? FileManager.default.removeItem(at: stagedMovie)
                    DispatchQueue.main.async {
                        if success, let assetID { completion(.success(assetID)) }
                        else { completion(.failure(error ?? PhotoLibraryError.missingIdentifier)) }
                    }
                }
            }
        }
    }

    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.writeDenied)) }; return
            }
            self.savingQueue.async {
                let staged: PhotoLibraryStagedResources
                let originalStaged: PhotoLibraryStagedResources?
                do {
                    staged = try PhotoLibraryStagedResources(photo.resources)
                    do { originalStaged = try photo.unfilteredOriginal.map { try PhotoLibraryStagedResources([$0]) } }
                    catch { staged.cleanup(); throw error }
                } catch { DispatchQueue.main.async { completion(.failure(error)) }; return }
                var assetID: String?
                var originalID: String?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    if let location = photo.location, location.isValid { request.location = location.clLocation }
                    if let date = photo.diagnostics?.parameters?.capturedAt { request.creationDate = date }
                    staged.add(to: request)
                    assetID = request.placeholderForCreatedAsset?.localIdentifier
                    if let originalStaged {
                        let original = PHAssetCreationRequest.forAsset()
                        if let location = photo.location, location.isValid { original.location = location.clLocation }
                        // Keep the filtered result ahead of its companion in the date-sorted gallery.
                        original.creationDate = (photo.diagnostics?.parameters?.capturedAt ?? Date()).addingTimeInterval(-0.001)
                        originalStaged.add(to: original)
                        originalID = original.placeholderForCreatedAsset?.localIdentifier
                    }
                }) { success, error in
                    staged.cleanup(); originalStaged?.cleanup()
                    if success, let originalID {
                        if var diagnostics = photo.diagnostics {
                            if var parameters = diagnostics.parameters {
                                parameters.filterID = FilmStyle.original.rawValue; parameters.filterName = FilmStyle.original.title; parameters.filterIntensity = 0; parameters.filterAdjustments = FilterAdjustments()
                                diagnostics.parameters = parameters
                            }
                            PhotoCaptureDiagnosticsStore.shared.save(diagnostics,assetID:originalID)
                        }
                        PhotoCaptureDiagnosticsStore.shared.setFilterApplied(false,assetID:originalID)
                    }
                    if success, let assetID, let diagnostics = photo.diagnostics {
                        if !PhotoCaptureDiagnosticsStore.shared.save(diagnostics, assetID: assetID) {
                            NSLog("Capture diagnostics could not be saved; photo was saved successfully.")
                        }
                    }
                    if let error { NSLog("PhotoKit capture save failed: %@", String(describing: error as NSError)) }
                    DispatchQueue.main.async {
                        if success, let assetID { completion(.success(assetID)) }
                        else { completion(.failure(error ?? PhotoLibraryError.missingIdentifier)) }
                    }
                }
            }
        }
    }

    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        delete(assetIDs: [assetID], completion: completion)
    }

    func delete(assetIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        let ids = Array(Set(assetIDs))
        guard !ids.isEmpty else { completion(.success(())); return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.readDenied)) }
                return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            if status == .limited && assets.count != ids.count {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.inaccessible)) }; return
            }
            guard assets.count > 0 else {
                // Full access confirms absence. Limited access cannot establish whether the asset exists.
                DispatchQueue.main.async {
                    completion(status == .authorized ? .success(()) : .failure(PhotoLibraryError.inaccessible))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets) }) { success, error in
                DispatchQueue.main.async {
                    if success { completion(.success(())) }
                    else { completion(.failure(error ?? PhotoLibraryError.inaccessible)) }
                }
            }
        }
    }
}
