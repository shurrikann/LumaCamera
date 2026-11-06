import Photos
import CoreImage
import UniformTypeIdentifiers
import ImageIO

/// 只接管带本应用显影配方的RAW+HEIF资产；普通照片和其他编辑器的扁平结果沿用旧流程。
enum RAWPhotoEditLoader {
    static func open(asset:PHAsset,input:PHContentEditingInput,cancel:SharedPhotoDownloadCancellation,
        completion:@escaping (Result<PhotoEditSession?,Error>) -> Void) {
        let entries = PHAssetResource.assetResources(for:asset)
        guard let raw = entries.first(where:{ PhotoResourceKind.isRAW(typeIdentifier:$0.uniformTypeIdentifier,filename:$0.originalFilename) }),
              let processed = entries.first(where:{ ($0.type == .photo || $0.type == .alternatePhoto) && !PhotoResourceKind.isRAW(typeIdentifier:$0.uniformTypeIdentifier,filename:$0.originalFilename) }) else {
            completion(.success(nil)); return
        }
        read(processed,cancel:cancel) { data in
            do {
                let bytes = try data.get()
                guard let source = CGImageSourceCreateWithData(bytes as CFData,nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
                      let captured = RAWDevelopmentRecipe.read(properties) else { completion(.success(nil)); return }
                // 仅本应用认识的配方可回到DNG。其他编辑器的结果不擅自重置。
                if let adjustment = input.adjustmentData, adjustment.formatIdentifier != "com.shurrikann.LumaCamera.photo-edit" {
                    completion(.success(nil)); return
                }
                let current = input.adjustmentData.flatMap { try? JSONDecoder().decode(PhotoAdjustments.self,from:$0.data) }
                // 无法理解的旧配方/第三方烘焙结果不能被原始底片覆盖。
                if input.adjustmentData != nil && current?.rawDevelopment?.version != 1 {
                    completion(.success(nil)); return
                }
                if input.adjustmentData == nil && entries.contains(where:{ $0.type == .adjustmentData }) {
                    completion(.success(nil)); return
                }
                let initial = current ?? captured
                read(raw,cancel:cancel) { result in
                    DispatchQueue.global(qos:.userInitiated).async {
                        do {
                            let rawData = try result.get(), developer = RAWPhotoDevelopment(raw:rawData,initial:initial,metadata:properties)
                            let base = try developer.source(initial,preview:true)
                            let session = PhotoEditSession(source:base,initialAdjustments:initial,rawDevelopment:developer,
                                copy:{ changes,callback in save(asset:asset,input:input,developer:developer,changes:changes,copy:true,completion:callback) },
                                commit:{ changes,callback in save(asset:asset,input:input,developer:developer,changes:changes,copy:false,completion:callback) })
                            DispatchQueue.main.async { if !cancel.isCancelled { completion(.success(session)) } }
                        } catch { DispatchQueue.main.async { if !cancel.isCancelled { completion(.failure(error)) } } }
                    }
                }
            } catch { completion(.failure(error)) }
        }
    }
    private static func read(_ resource:PHAssetResource,cancel:SharedPhotoDownloadCancellation,completion:@escaping (Result<Data,Error>)->Void) {
        let manager = PHAssetResourceManager.default(), options = PHAssetResourceRequestOptions(), lock = NSLock()
        options.isNetworkAccessAllowed = true
        var bytes = Data()
        let id = manager.requestData(for:resource,options:options,dataReceivedHandler:{ part in lock.lock(); bytes.append(part); lock.unlock() }) { error in
            lock.lock(); let data = bytes; lock.unlock()
            guard !cancel.isCancelled else { return }
            completion(error.map { .failure($0) } ?? .success(data))
        }
        cancel.add { manager.cancelDataRequest(id) }
    }
    private static func save(asset:PHAsset,input:PHContentEditingInput,developer:RAWPhotoDevelopment,changes:PhotoAdjustments,copy:Bool,
        completion:@escaping (Result<PhotoEditResult,Error>)->Void) {
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let rendered = try developer.render(changes)
                let output:PHContentEditingOutput?
                if !copy {
                    let editing = PHContentEditingOutput(contentEditingInput:input)
                    // 官方HEIF编辑输出入口保留HDR，不能把HEIF字节写进默认JPEG输出URL。
                    let destination = try editing.renderedContentURL(for:.heic)
                    try rendered.resource.data.write(to:destination,options:.atomic)
                    editing.adjustmentData = PHAdjustmentData(formatIdentifier:"com.shurrikann.LumaCamera.photo-edit",formatVersion:"6",data:try JSONEncoder().encode(changes))
                    output = editing
                } else { output = nil }
                let staged = try copy ? PhotoLibraryStagedResources([rendered.resource,PhotoResource(data:developer.raw,filename:"Luma-Original-"+UUID().uuidString+".dng",alternate:true)]) : nil
                var identifier:String?
                PHPhotoLibrary.shared().performChanges({
                    if copy {
                        let request = PHAssetCreationRequest.forAsset(); request.creationDate = asset.creationDate; request.location = asset.location
                        staged?.add(to:request); identifier = request.placeholderForCreatedAsset?.localIdentifier
                    } else { PHAssetChangeRequest(for:asset).contentEditingOutput = output }
                }) { success,error in
                    staged?.cleanup()
                    DispatchQueue.main.async {
                        if success {
                            let target = identifier ?? asset.localIdentifier
                            PhotoCaptureDiagnosticsStore.shared.copyRecord(from:asset.localIdentifier,to:target,adjustments:changes,sourceIsOriginal:true)
                            PhotoCaptureDiagnosticsStore.shared.setFilterApplied(changes.usesFilter,assetID:target)
                            var result = rendered; result.copiedAssetID = identifier; completion(.success(result))
                        } else { completion(.failure(error ?? PhotoDetailError.editingUnsupported)) }
                    }
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
