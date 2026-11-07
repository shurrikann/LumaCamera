import Photos
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension SystemPhotoLibraryService: PhotoDetailService {
    func details(id: String, completion: @escaping (Result<PhotoDetails, Error>) -> Void) -> PhotoImageRequest {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { _ in false }
        let requestID = asset.requestContentEditingInput(with: options) { input, info in
            guard let url = input?.fullSizeImageURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { completion(.failure(info[PHContentEditingInputErrorKey] as? Error ?? PhotoDetailError.unavailable)) }; return
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let resources = PHAssetResource.assetResources(for: asset)
            let filename = (resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }))?.originalFilename ?? url.lastPathComponent
            var rows = [PhotoInfoRow(title: "文件名称", value: filename)]
            if let type = CGImageSourceGetType(source) {
                rows.append(.init(title: "输出格式", value: UTType(type as String)?.preferredFilenameExtension?.uppercased() ?? (type as String)))
            }
            rows += PhotoCaptureDiagnostics.dimensionRows(properties: properties)
            if let date = asset.creationDate { rows.append(PhotoInfoRow(title: "拍摄时间", value: date.formatted(date: .numeric, time: .standard))) }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { rows.append(PhotoInfoRow(title: "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
            rows += PhotoCaptureDiagnostics.exposureRows(properties: properties)
            if let recipe = RAWDevelopmentRecipe.read(Dictionary(uniqueKeysWithValues:properties.map { ($0.key as String,$0.value) })) {
                rows.append(.init(title:"高动态显影",value:recipe.rawDevelopment?.adaptive == true ? "开启" : "关闭"))
                let hasRAW = resources.contains { PhotoResourceKind.isRAW(typeIdentifier:$0.uniformTypeIdentifier,filename:$0.originalFilename) }
                rows.append(.init(title:"RAW底片",value:hasRAW ? "已附带，可重新显影" : "当前资产未附带"))
            }
            var diagnostics = PhotoCaptureDiagnosticsStore.shared.load(assetID: id)
            // 仅修复延迟HDR资产：历史记录可能只有快门时EV，必须用当前最终文件补齐成片参数。
            if diagnostics?.rows.contains(where: { $0.title == "HDR处理" && $0.value == "系统延迟融合完成" }) == true {
                diagnostics?.parameters?.updateEXIF(properties)
            }
            if let diagnostics {
                rows = PhotoCaptureDiagnostics.merged(rows, with: diagnostics.detailRows)
            } else { rows.append(.init(title: "拍摄诊断", value: "未知，未记录拍摄时信息")) }
            DispatchQueue.main.async { completion(.success(PhotoDetails(rows: rows, captureParameters: diagnostics?.currentParameters,
                location: asset.location.flatMap(PhotoLocation.recorded) ?? PhotoLocation.fromGPS(properties, date: asset.creationDate ?? Date()) ?? diagnostics?.parameters?.location, capturedAt: asset.creationDate))) }
        }
        return PhotoImageRequest { asset.cancelContentEditingInputRequest(requestID) }
    }

    func shareResources(id: String, completion: @escaping (Result<[PhotoResource], Error>) -> Void) -> PhotoImageRequest {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }) else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        var selected = [resource]
        selected += resources.filter { candidate in
            candidate !== resource && PhotoResourceKind.isRAW(typeIdentifier: candidate.uniformTypeIdentifier, filename: candidate.originalFilename)
        }
        if let movie = resources.first(where: { $0.type == .fullSizePairedVideo }) ?? resources.first(where: { $0.type == .pairedVideo }) {
            selected.append(movie)
        }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default(), state = SharedPhotoDownloadCancellation()
        var exported: [PhotoResource] = []
        func download(_ index: Int) {
            guard !state.isCancelled else { return }
            guard index < selected.count else { completion(.success(exported)); return }
            let entry = selected[index], lock = NSLock()
            var data = Data()
            let id = manager.requestData(for: entry, options: options, dataReceivedHandler: { chunk in
                lock.lock(); data.append(chunk); lock.unlock()
            }) { error in
                lock.lock(); let value = data; lock.unlock()
                DispatchQueue.main.async {
                    guard !state.isCancelled else { return }
                    if let error { completion(.failure(error)); return }
                    exported.append(PhotoResource(data: value, filename: entry.originalFilename,
                        alternate: index > 0 && entry.type != .pairedVideo && entry.type != .fullSizePairedVideo,
                        pairedVideo: entry.type == .pairedVideo || entry.type == .fullSizePairedVideo))
                    download(index + 1)
                }
            }
            state.add { manager.cancelDataRequest(id) }
        }
        download(0)
        return PhotoImageRequest { state.cancel() }
    }

    func openEditor(id: String, completion: @escaping (Result<PhotoEditSession, Error>) -> Void) -> PhotoImageRequest {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject, asset.canPerform(.content) else {
            completion(.failure(PhotoDetailError.editingUnsupported)); return PhotoImageRequest(cancel: {})
        }
        let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = true
        // Resume our own recipes against the original source; other editors remain flattened.
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == "com.shurrikann.LumaCamera.photo-edit" &&
            ["1", "2", "3", "4", "5", "6"].contains(data.formatVersion) && (try? JSONDecoder().decode(PhotoAdjustments.self, from: data.data)) != nil
        }
        let downloads = SharedPhotoDownloadCancellation()
        let requestID = asset.requestContentEditingInput(with: options) { input, info in
            guard let input else { DispatchQueue.main.async { completion(.failure(info[PHContentEditingInputErrorKey] as? Error ?? PhotoDetailError.unavailable)) }; return }
            func openStandardEditor() {
            guard let url = input.fullSizeImageURL,
                  let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: false])?.oriented(forExifOrientation: input.fullSizeImageOrientation) else {
                DispatchQueue.main.async { completion(.failure(info[PHContentEditingInputErrorKey] as? Error ?? PhotoDetailError.unavailable)) }; return
            }
            let sourceMetadata = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let initial = input.adjustmentData.flatMap { data -> PhotoAdjustments? in
                guard data.formatIdentifier == "com.shurrikann.LumaCamera.photo-edit", ["1", "2", "3", "4", "5", "6"].contains(data.formatVersion) else { return nil }
                return try? JSONDecoder().decode(PhotoAdjustments.self, from: data.data)
            } ?? PhotoAdjustments()
            // A camera filter or a flattened copy is already baked into the editing source.
            let sourceRecord = PhotoCaptureDiagnosticsStore.shared.load(assetID: id)
            let sourceIsOriginal = input.adjustmentData?.formatIdentifier == "com.shurrikann.LumaCamera.photo-edit"
            let originalFilter = (sourceRecord?.bakedFilter ?? sourceRecord?.legacyEditedFilter ?? sourceRecord?.captureFilter)?.applied ?? false
            let sourceHasFilter = sourceIsOriginal ? originalFilter : PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID: id)
            let liveCommit: ((PhotoAdjustments, Bool, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void)? = asset.mediaSubtypes.contains(.photoLive) ? { adjustments, asCopy, callback in
                Task {
                    do {
                        let rendered = try PhotoEditRenderer.render(source: source, adjustments: adjustments, metadata: sourceMetadata)
                        let live = try await LivePhotoEditRenderer.render(input: input, adjustments: adjustments, copy: asCopy)
                        // Paired video must use the same file-backed import as native capture.
                        // Keep these files alive until Photos finishes validating the pair.
                        let staged = try asCopy ? PhotoLibraryStagedResources(live.resources) : nil
                        var identifier: String?
                        PHPhotoLibrary.shared().performChanges({
                            if asCopy {
                                let request = PHAssetCreationRequest.forAsset()
                                request.creationDate = asset.creationDate; request.location = asset.location
                                staged?.add(to: request)
                                identifier = request.placeholderForCreatedAsset?.localIdentifier
                            } else { PHAssetChangeRequest(for: asset).contentEditingOutput = live.output }
                        }) { success, error in
                            staged?.cleanup()
                            if let error { NSLog("Live edited save failed: %@", String(describing: error as NSError)) }
                            DispatchQueue.main.async {
                                if success {
                                    let savedID = asCopy ? identifier : id
                                    if let savedID {
                                        PhotoCaptureDiagnosticsStore.shared.copyRecord(from: id, to: savedID, adjustments: adjustments, sourceIsOriginal: sourceIsOriginal)
                                        PhotoCaptureDiagnosticsStore.shared.setFilterApplied(sourceHasFilter || adjustments.usesFilter, assetID: savedID)
                                    }
                                    var result = rendered; result.copiedAssetID = asCopy ? identifier : nil
                                    result.filterApplied = sourceHasFilter || adjustments.usesFilter
                                    callback(.success(result))
                                } else { callback(.failure(error ?? PhotoDetailError.editingUnsupported)) }
                            }
                        }
                    } catch { DispatchQueue.main.async { callback(.failure(error)) } }
                }
            } : nil
            let session = PhotoEditSession(source: source, initialAdjustments: initial, liveCommit: liveCommit, copy: { adjustments, callback in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let rendered = try PhotoEditRenderer.render(source: source, adjustments: adjustments, metadata: sourceMetadata)
                        var identifier: String?
                        PHPhotoLibrary.shared().performChanges({
                            let request = PHAssetCreationRequest.forAsset()
                            request.creationDate = asset.creationDate; request.location = asset.location
                            let options = PHAssetResourceCreationOptions(); options.originalFilename = rendered.resource.filename
                            request.addResource(with: .photo, data: rendered.resource.data, options: options)
                            identifier = request.placeholderForCreatedAsset?.localIdentifier
                        }) { success, error in
                            DispatchQueue.main.async {
                                if success, let identifier {
                                    PhotoCaptureDiagnosticsStore.shared.copyRecord(from: id, to: identifier, adjustments: adjustments, sourceIsOriginal: sourceIsOriginal)
                                    PhotoCaptureDiagnosticsStore.shared.setFilterApplied(sourceHasFilter || adjustments.usesFilter, assetID: identifier)
                                    var result = rendered; result.filterApplied = sourceHasFilter || adjustments.usesFilter; result.copiedAssetID = identifier; callback(.success(result))
                                } else { callback(.failure(error ?? PhotoDetailError.unavailable)) }
                            }
                        }
                    } catch { DispatchQueue.main.async { callback(.failure(error)) } }
                }
            }) { adjustments, callback in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = PHContentEditingOutput(contentEditingInput: input)
                        let result = try PhotoEditRenderer.render(source: source, adjustments: adjustments, metadata: sourceMetadata)
                        try result.resource.data.write(to: output.renderedContentURL, options: .atomic)
                        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.shurrikann.LumaCamera.photo-edit", formatVersion: "4", data: try JSONEncoder().encode(adjustments))
                        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest(for: asset).contentEditingOutput = output }) { success, error in
                            DispatchQueue.main.async {
                                if success { PhotoCaptureDiagnosticsStore.shared.copyRecord(from: id, to: id, adjustments: adjustments, sourceIsOriginal: sourceIsOriginal); PhotoCaptureDiagnosticsStore.shared.setFilterApplied(sourceHasFilter || adjustments.usesFilter, assetID: id); var saved = result; saved.filterApplied = sourceHasFilter || adjustments.usesFilter; callback(.success(saved)) }
                                else { callback(.failure(error ?? PhotoDetailError.editingUnsupported)) }
                            }
                        }
                    } catch { DispatchQueue.main.async { callback(.failure(error)) } }
                }
            }
            DispatchQueue.main.async { completion(.success(session)) }
            }
            RAWPhotoEditLoader.open(asset:asset,input:input,cancel:downloads) { result in
                guard !downloads.isCancelled else { return }
                switch result {
                case .success(let session?): DispatchQueue.main.async { completion(.success(session)) }
                case .success(nil): openStandardEditor()
                case .failure(let error): DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
        return PhotoImageRequest { downloads.cancel(); asset.cancelContentEditingInputRequest(requestID) }
    }
}

/// Resource downloads outlive the detail view only while their share sheet needs them.
final class SharedPhotoDownloadCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [() -> Void] = []
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func add(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); action() }
        else { actions.append(action); lock.unlock() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = actions; actions = []; lock.unlock()
        pending.forEach { $0() }
    }
}
