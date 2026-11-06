import Foundation
import UIKit

/// Composition root: concrete platform services are assembled only here.
@MainActor
enum AppDependencies {
    #if DEBUG
    /// Allows hardware integration tests to exercise the visible app without starting a competing session.
    static weak var runningAppCameraModel: CameraViewModel?
    #endif
    static func makeCameraModel(automaticallySave: Bool = true, photoService: (PhotoLibraryService & PhotoBrowserService)? = nil, filterSettings: FilterSettingsStore? = nil, preferencesStore: CapturePreferencesStore? = nil) -> CameraViewModel {
        let service: PhotoLibraryService & PhotoBrowserService = photoService ?? defaultPhotoService()
        let library = PhotoLibraryViewModel(service: service)
        let gallery = GalleryViewModel(browser: service, library: library)
        let camera = CameraEngine()
        camera.onPhotoCaptured = { [weak library] image in library?.acceptPhoto(image) }
        camera.onCaptureThumbnailReady = { [weak library] image in library?.acceptPhoto(image) }
        camera.onCaptureCompleted = { [weak library] photo in
            guard let photo else { return } // 失败终结仍通知请求方，不清空上一张成功成片。
            library?.acceptCapture(photo, automaticallySave: automaticallySave)
        }
        camera.canCapture = { [weak library] in library?.canAcceptNewCapture == true }
        return CameraViewModel(camera: camera, library: library, gallery: gallery, filterSettings: filterSettings,
                               preferencesStore: preferencesStore ?? (automaticallySave ? nil : CapturePreferencesStore(defaults: nil)))
    }

    private static func defaultPhotoService() -> PhotoLibraryService & PhotoBrowserService {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS"] == "1" {
            // 真机诊断明确启用时，连异常收尾恢复的默认保存回调也不能写入用户相册。
            // 显式注入的内存替身仍按原契约工作；正常运行与 Release 均不启用此隔离。
            print("DIAGNOSTIC-PHOTOS-READONLY enabled")
            return DiagnosticReadOnlyPhotoService()
        }
        #endif
        return SystemPhotoLibraryService()
    }
}

#if DEBUG
/// 诊断相册只读适配器：浏览仍读取真实资产，所有写入/删除入口直接失败，不调用 PhotoKit 修改 API。
final class DiagnosticReadOnlyPhotoService: PhotoLibraryService, PhotoBrowserService {
    private let reader: PhotoBrowserService
    private(set) var blockedMutationCount = 0

    init(reader: PhotoBrowserService = SystemPhotoLibraryService()) { self.reader = reader }
    var onLibraryChange: (() -> Void)? {
        get { reader.onLibraryChange }
        set { reader.onLibraryChange = newValue }
    }
    var existingAccess: PhotoLibraryAccess? { reader.existingAccess }
    func canReloadSavedPhoto(id: String) -> Bool { true }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { reader.authorize(completion: completion) }
    func availablePhotoIDs(_ ids: [String], completion: @escaping (Set<String>?) -> Void) { reader.availablePhotoIDs(ids, completion: completion) }
    func photoAvailability(id: String, completion: @escaping (PhotoAssetAvailability) -> Void) { reader.photoAvailability(id: id, completion: completion) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { reader.fetchPhotos(offset: offset, limit: limit, completion: completion) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { reader.requestImage(id: id, size: size, completion: completion) }

    private func deny<T>(_ operation: String, _ completion: (Result<T, Error>) -> Void) {
        blockedMutationCount += 1
        print("DIAGNOSTIC-PHOTOS-BLOCKED operation=\(operation)")
        completion(.failure(PhotoLibraryError.writeDenied))
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { deny("image", completion) }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) { deny("capture", completion) }
    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void) { deny("video", completion) }
    func saveLivePhoto(stillImage: Data, movieURL: URL, location: PhotoLocation?, creationDate: Date?, completion: @escaping (Result<String, Error>) -> Void) { deny("live", completion) }
    func delete(assetIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) { deny("delete-batch", completion) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { deny("delete", completion) }
}
#endif
