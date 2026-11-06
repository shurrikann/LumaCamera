import SwiftUI
import CoreImage
import ImageIO

struct PhotoReview: View {
    @ObservedObject var model: PhotoLibraryViewModel
    let isDemo: Bool
    let browser: PhotoBrowserService
    let onCamera: () -> Void
    var onSwipe: ((Int) -> Void)? = nil
    var pagingBusy = false
    var pageMotion: PhotoPageAnimation? = nil
    var onPageFinished: (() -> Void)? = nil
    var onImageDisplayed: ((UIImage?) -> Void)? = nil
    var onDeletePrepared: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    @State private var retainedImage: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var share = false
    @State private var preparingShare = false
    @State private var savedShareResources: [PhotoResource] = []
    @State private var savedImageRequest: PhotoImageRequest?
    @State private var shareRequest: PhotoImageRequest?
    @State private var savedImageToken = UUID()
    @State private var shareToken = UUID()
    private var displayedImage: UIImage? { retainedImage ?? model.lastPhoto }
    private var liveSource: LivePhotoPlaybackSource? {
        guard model.hasLiveResource else { return nil }
        if let id = model.savedPhotoID { return LivePhotoPlaybackSource(assetID: id) }
        return LivePhotoPlaybackSource(resources: model.shareResources)
    }
    @State private var info = false
    @State private var preparingEdit = false
    @State private var editor: PhotoEditSession?
    @State private var request: PhotoImageRequest?
    @State private var requestToken = UUID()
    var body: some View {
        PhotoViewerLayout(image: displayedImage, date: model.lastPhotoDate, location: model.captureLocation, isRAW: model.hasRAWResource, isLive: model.hasLiveResource, hasFilter: model.hasFilterResource, isNightComposite: model.hasNightCompositeResource, liveSource: liveSource, busy: model.isBusy || preparingEdit || preparingShare, pagingBusy: pagingBusy, destructiveBusy: model.deleting || model.editing, shareBusy: preparingShare, infoVisible: info, details: captureDetails,
                          onBack: { dismiss() }, onCamera: onCamera, onShare: prepareShare, onInfo: { info.toggle() },
                          onEdit: { openEditor() }, onDelete: {
                              onDeletePrepared?()
                              model.deletePhoto { deleted in
                                  guard deleted else { return }
                                  if let onDeleted { onDeleted() } else { dismiss() }
                              }
                          }, onSwipe: share || editor != nil ? nil : onSwipe, pageMotion: pageMotion, onPageFinished: onPageFinished)
            .safeAreaInset(edge: .bottom) {
                if model.saving { ProgressView("自动保存中…").font(.caption).padding(8) }
                else if !model.photoSaved {
                    Button("保存失败，点击重试") { model.savePhoto(showSuccessMessage: false) }.font(.caption).tint(AppTheme.accent).padding(8)
                }
            }
            .sheet(isPresented: $share, onDismiss: { savedShareResources = [] }) {
                if let image = displayedImage { ShareSheet(image: image, resources: savedShareResources.isEmpty ? model.shareResources : savedShareResources) }
            }
            .sheet(item: $editor) { session in
                PhotoEditorView(session: session, library: model) { result in
                    if result.copiedAssetID != nil { return }
                    retainedImage = result.preview
                    if let id = model.savedPhotoID { model.updateSavedPreview(assetID: id, result: result) }
                    else { model.replaceUnsavedPhoto(result); model.savePhoto(showSuccessMessage: false) }
                }
            }
            .onChange(of: model.lastPhoto) { _, image in
                if let image, !model.hasReleasedCaptureResources { retainedImage = image }
                onImageDisplayed?(displayedImage)
            }
            .task(id: model.savedPhotoID) { loadSavedImage() }
            .onAppear {
                retainedImage = model.lastPhoto
                onImageDisplayed?(model.lastPhoto)
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--preview-capture-info") { info = true }
                #endif
            }
            .onDisappear {
                requestToken = UUID(); request?.cancel(); preparingEdit = false
                savedImageToken = UUID(); savedImageRequest?.cancel()
                shareToken = UUID(); shareRequest?.cancel(); preparingShare = false; savedShareResources = []
            }
            .alert("光屿相机", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                if model.failedSaveCount > 0 { Button("重试保存") { model.retryFailedSaves() } }
                Button("好", role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
    }
    private func loadSavedImage() {
        savedImageRequest?.cancel()
        let token = UUID(); savedImageToken = token
        guard let id = model.savedPhotoID else { return }
        savedImageRequest = browser.requestImage(id: id, size: CGSize(width: 2400, height: 2400)) { image, error in
            guard token == savedImageToken, model.savedPhotoID == id else { return }
            if let image { retainedImage = image; onImageDisplayed?(image) }
            else if let error { model.message = error.localizedDescription }
        }
    }

    private func prepareShare() {
        guard !preparingShare, !model.isBusy else { return }
        guard let id = model.savedPhotoID, model.hasReleasedCaptureResources else { share = true; return }
        guard let service = browser as? PhotoDetailService else { model.message = PhotoDetailError.unavailable.localizedDescription; return }
        preparingShare = true
        let token = UUID(); shareToken = token
        shareRequest = service.shareResources(id: id) { result in
            guard shareToken == token, model.savedPhotoID == id else { return }
            preparingShare = false
            switch result {
            case .success(let resources): savedShareResources = resources; share = true
            case .failure(let error): model.message = error.localizedDescription
            }
        }
    }

    private var captureDetails: PhotoDetails {
        var rows: [PhotoInfoRow] = []
        let captureRows = model.captureInfoRows
        rows += captureRows
        if !captureRows.contains(where: { $0.title == "快门时主镜头" }) {
            rows.append(PhotoInfoRow(title: "拍摄诊断", value: isDemo ? "演示画面，无真实镜头信息" : "未知，未记录拍摄时信息"))
        }
        if isDemo { rows.append(PhotoInfoRow(title: "来源", value: "模拟器演示画面")) }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-location-info") {
            var parameters = PhotoCaptureParameters()
            parameters.cameraModel = "iPhone 17 Pro"; parameters.iso = 339; parameters.exposureSeconds = 1 / 49
            parameters.aperture = 1.78; parameters.equivalentFocalLengthMM = 24; parameters.exifExposureBiasEV = 0
            let sample = [PhotoInfoRow(title: "相机", value: "iPhone 17 Pro"), PhotoInfoRow(title: "快门", value: "1/49s"), PhotoInfoRow(title: "ISO", value: "339")]
            return PhotoDetails(rows: PhotoCaptureDiagnostics.merged(sample, with: rows), captureParameters: parameters,
                                location: PhotoLocation(latitude: 34.25, longitude: 108.95), capturedAt: model.lastPhotoDate)
        }
        #endif
        return PhotoDetails(rows: rows, captureParameters: model.captureParameters, location: model.captureLocation, capturedAt: model.lastPhotoDate)
    }
    private func openEditor() {
        if let id = model.savedPhotoID, let service = browser as? PhotoDetailService {
            guard !preparingEdit else { return }
            preparingEdit = true
            let token = UUID(); requestToken = token
            request = service.openEditor(id: id) { result in
                guard requestToken == token else { return }
                preparingEdit = false
                switch result { case .success(let session): editor = session; case .failure(let error): model.message = error.localizedDescription }
            }
        } else if let raw = model.shareResources.first(where:{ $0.filename.lowercased().hasSuffix(".dng") }),
                  let processed = model.shareResources.first(where:{ !$0.alternate && !$0.pairedVideo }),
                  let image = CGImageSourceCreateWithData(processed.data as CFData,nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any],
                  let recipe = RAWDevelopmentRecipe.read(metadata) {
            // 自动保存失败的临时照片也从底片编辑；不退回已烘焙的缩略图。
            preparingEdit = true; let token = UUID(); requestToken = token
            DispatchQueue.global(qos:.userInitiated).async {
                do {
                    let developer = RAWPhotoDevelopment(raw:raw.data,initial:recipe,metadata:metadata)
                    let source = try developer.source(recipe,preview:true)
                    let session = PhotoEditSession(source:source,initialAdjustments:recipe,rawDevelopment:developer) { changes,completion in
                        DispatchQueue.global(qos:.userInitiated).async {
                            let result = Result { try developer.render(changes) }
                            DispatchQueue.main.async { completion(result) }
                        }
                    }
                    DispatchQueue.main.async { guard requestToken == token else { return }; preparingEdit = false; editor = session }
                } catch { DispatchQueue.main.async { guard requestToken == token else { return }; preparingEdit = false; model.message = error.localizedDescription } }
            }
        } else if let image = model.lastPhoto, let source = CIImage(image: image) {
            editor = PhotoEditSession(source: source) { adjustments, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try PhotoEditRenderer.render(source: source, adjustments: adjustments) }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }
}
