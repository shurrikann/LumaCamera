import UIKit
import CoreImage

struct PhotoInfoRow: Identifiable, Codable, Equatable {
    let title: String
    let value: String
    var id: String { title }
}
struct PhotoDetails {
    let rows: [PhotoInfoRow]
    var captureParameters: PhotoCaptureParameters? = nil
    var location: PhotoLocation? = nil
    var capturedAt: Date? = nil
}
struct PhotoAdjustments: Codable, Equatable {
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var quarterTurns = 0
    var crop = PhotoCropRectangle.full
    var flipHorizontal = false
    var flipVertical = false
    var straightenAngle = 0.0
    var filterID = FilmStyle.original.rawValue
    var filterIntensity = 0.8
    var filterAdjustments = FilterAdjustments()
    var rawDevelopment: RAWDevelopmentSettings? = nil
    init() {}
    private enum CodingKeys: String, CodingKey { case exposure, contrast, saturation, quarterTurns, filterID, filterIntensity, filterAdjustments, crop, flipHorizontal, flipVertical, straightenAngle, rawDevelopment }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        crop = (try c.decodeIfPresent(PhotoCropRectangle.self, forKey: .crop) ?? .full).clamped
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        let angle = try c.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0
        straightenAngle = angle.isFinite ? min(max(angle, -45), 45) : 0
        filterID = try c.decodeIfPresent(String.self, forKey: .filterID) ?? FilmStyle.original.rawValue
        filterIntensity = try c.decodeIfPresent(Double.self, forKey: .filterIntensity) ?? 0.8
        filterAdjustments = try c.decodeIfPresent(FilterAdjustments.self, forKey: .filterAdjustments) ?? FilterAdjustments()
        rawDevelopment = try c.decodeIfPresent(RAWDevelopmentSettings.self,forKey:.rawDevelopment)
    }
    var usesFilter: Bool { filterID != FilmStyle.original.rawValue && filterIntensity > 0 }
    func apply(to source: CIImage, grainPhase: Double = 0, rawControlsApplied: Bool = false) -> CIImage {
        let selected = FilmStyle(rawValue: filterID) ?? .original
        let style = FilmStyle.availableStyles.contains(selected) ? selected : .original
        let look = CaptureLook(style: style, intensity: filterIntensity.isFinite ? min(max(filterIntensity, 0), 1) : 0.8, grainPhase: grainPhase,
            tone: rawDevelopment.flatMap { PhotoTone(rawValue:$0.tone) } ?? .natural,
            adjustments:rawControlsApplied ? AdaptiveRAWDeveloper.withoutRAWControls(filterAdjustments) : filterAdjustments,
            virtualAperture:rawDevelopment?.virtualAperture)
        let styled = rawControlsApplied ? AdaptiveDynamicRenderer.filtered(source,look:look,hdr:rawDevelopment?.hdr == true) : Imaging.filtered(source,look:look)
        var image = styled.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if flipHorizontal { image = image.oriented(.upMirrored) }
        if flipVertical { image = image.oriented(.downMirrored) }
        if straightenAngle.isFinite, abs(straightenAngle) > 0.0001 {
            let extent = image.extent, angle = min(max(straightenAngle, -45), 45) * .pi / 180
            let scale = max(abs(cos(angle)) + extent.height/extent.width*abs(sin(angle)), abs(cos(angle)) + extent.width/extent.height*abs(sin(angle)))
            image = image.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: -angle).scaledBy(x: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY)).cropped(to: extent)
        }
        image = image.cropped(to: crop.imageRect(in: image.extent))
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
struct PhotoEditResult {
    let preview: UIImage
    let resource: PhotoResource
    var filterApplied: Bool? = nil
    var copiedAssetID: String? = nil
}
final class PhotoEditSession: Identifiable {
    let id = UUID()
    let source: CIImage
    let initialAdjustments: PhotoAdjustments
    let rawDevelopment: RAWPhotoDevelopment?
    let liveCommit: ((PhotoAdjustments, Bool, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void)?
    var supportsLiveEditing: Bool { liveCommit != nil }
    private let copy: ((PhotoAdjustments, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void)?
    var supportsSaveCopy: Bool { copy != nil }
    private let commit: (PhotoAdjustments, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void
    init(source: CIImage, initialAdjustments: PhotoAdjustments = PhotoAdjustments(), rawDevelopment: RAWPhotoDevelopment? = nil, liveCommit: ((PhotoAdjustments, Bool, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void)? = nil, copy: ((PhotoAdjustments, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void)? = nil, commit: @escaping (PhotoAdjustments, @escaping (Result<PhotoEditResult, Error>) -> Void) -> Void) {
        self.source = source; self.initialAdjustments = initialAdjustments; self.rawDevelopment = rawDevelopment
        self.liveCommit = liveCommit; self.copy = copy; self.commit = commit
    }
    func saveLive(_ adjustments: PhotoAdjustments, asCopy: Bool, completion: @escaping (Result<PhotoEditResult, Error>) -> Void) {
        guard let liveCommit else { completion(.failure(PhotoDetailError.editingUnsupported)); return }
        liveCommit(adjustments, asCopy, completion)
    }
    func saveCopy(_ adjustments: PhotoAdjustments, completion: @escaping (Result<PhotoEditResult, Error>) -> Void) {
        guard let copy else { completion(.failure(PhotoDetailError.editingUnsupported)); return }; copy(adjustments, completion)
    }
    func save(_ adjustments: PhotoAdjustments, completion: @escaping (Result<PhotoEditResult, Error>) -> Void) { commit(adjustments, completion) }
}
protocol PhotoDetailService: AnyObject {
    func details(id: String, completion: @escaping (Result<PhotoDetails, Error>) -> Void) -> PhotoImageRequest
    func shareResources(id: String, completion: @escaping (Result<[PhotoResource], Error>) -> Void) -> PhotoImageRequest
    func openEditor(id: String, completion: @escaping (Result<PhotoEditSession, Error>) -> Void) -> PhotoImageRequest
}
enum PhotoDetailError: LocalizedError {
    case unavailable, editingUnsupported
    var errorDescription: String? { self == .editingUnsupported ? "此照片暂不支持编辑。" : "照片暂时无法读取，请检查相册权限或网络。" }
}
