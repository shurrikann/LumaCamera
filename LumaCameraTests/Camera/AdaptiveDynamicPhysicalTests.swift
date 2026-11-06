import XCTest
import SwiftUI
import CoreImage
import ImageIO
import AVFoundation
import Photos
@testable import LumaCamera

private struct DynamicFormatHost:View {
    @ObservedObject var model:CameraViewModel
    let angle:Double
    var body:some View {
        CameraView(model:model).toolbarOptionsPanel
            .environment(\.captureControlAngle,angle)
            .captureControlGeometry("format.panel",model:model)
    }
}
final class AdaptiveDynamicPhysicalTests:XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testHighResolutionRAWRequestAndDecode() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onCaptureCompleted, dimensionCallback = camera.onPhotoRequestDimensionsForTesting
        UIApplication.shared.isIdleTimerDisabled = true
        var photo:CapturedPhoto?, request:CMVideoDimensions?
        camera.onCaptureCompleted = { photo = $0 }; camera.onPhotoRequestDimensionsForTesting = { request = $0 }
        defer { camera.onCaptureCompleted = callback; camera.onPhotoRequestDimensionsForTesting = dimensionCallback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ name:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(name+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setMode(.manual)
        if let main = camera.lenses.first(where:{ $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoomFactor == 1 }) { model.selectFocalLength(main) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait("主摄就绪") { camera.ready && camera.availableResolutions.contains(.high) }
        model.photoFormat = .heifPro
        try await Task.sleep(for:.milliseconds(400))
        model.photoResolution = .high; model.setAdaptiveHighDynamic(true)
        try await Task.sleep(for:.milliseconds(400))
        print("ADAPTIVE-48-BEFORE resolution=\(model.photoResolution.rawValue) options=\(model.photoOptions.resolution.rawValue) capabilities=\(camera.availableResolutions)")
        camera.capture(flashMode:.off,options:model.photoOptions)
        try await wait("48MP出片") { photo != nil && camera.pendingPhotoCount == 0 }
        let shot = try XCTUnwrap(photo), raw = try XCTUnwrap(shot.resources.first(where: { $0.alternate }))
        let filter = try XCTUnwrap(CIRAWFilter(imageData:raw.data,identifierHint:nil))
        print("ADAPTIVE-48-AFTER request=\(String(describing:request)) rawNative=\(filter.nativeSize) rawScale=\(filter.scaleFactor) rawOutput=\(String(describing:filter.outputImage?.extent)) requested=\(String(describing:shot.diagnostics?.parameters?.requestedMegapixels))")
        XCTAssertEqual(model.photoOptions.resolution,.high)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(shot.resources[0].data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded,0,nil) as? [String:Any])
        let pixels = (properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0)*(properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        XCTAssertGreaterThan(pixels,40_000_000,"不能把12MP文件记作48MP通过")
        let recipe = try XCTUnwrap(RAWDevelopmentRecipe.read(properties))
        let t = CACurrentMediaTime()
        let rendered = try RAWPhotoDevelopment(raw:raw.data,initial:recipe,metadata:properties).render(recipe)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithData(rendered.resource.data as CFData,nil))
        let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded,0,nil) as? [String:Any])
        XCTAssertEqual(values[kCGImagePropertyPixelWidth as String] as? Int,properties[kCGImagePropertyPixelWidth as String] as? Int)
        XCTAssertEqual(values[kCGImagePropertyPixelHeight as String] as? Int,properties[kCGImagePropertyPixelHeight as String] as? Int)
        print("ADAPTIVE-48-OUTPUT pixels=\(pixels) redevelopSeconds=\(CACurrentMediaTime()-t)")
    }
    #endif
    #if !targetEnvironment(simulator)
    @MainActor func testBacklitCapturePreviewAndRAWComparison() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        var photo:CapturedPhoto?, preview:UIImage?
        camera.onCaptureCompleted = { photo = $0 }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ name:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(name+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setMode(.auto); model.photoFormat = .heifPro; model.photoResolution = .standard
        model.style = .original; model.tone = .natural; model.hdr = false; model.setAdaptiveHighDynamic(true)
        try await Task.sleep(for:.seconds(2))
        camera.readNextPreviewPairForTesting { _, filtered in preview = filtered }
        try await wait("取景对照") { preview != nil }
        let start = CACurrentMediaTime()
        camera.capture(flashMode:.off,options:model.photoOptions)
        try await wait("逆光成片") { photo != nil && camera.pendingPhotoCount == 0 }
        let shot = try XCTUnwrap(photo), raw = try XCTUnwrap(shot.resources.first(where:{ $0.alternate }))
        let filter = try XCTUnwrap(CIRAWFilter(imageData:raw.data,identifierHint:nil))
        let nativeLocal = filter.localToneMapAmount
        filter.scaleFactor = Float(min(1,1000/max(filter.nativeSize.width,filter.nativeSize.height)))
        AdaptiveRAWDeveloper.configure(filter,adaptive:true,hdr:false,adjustments:FilterAdjustments())
        XCTAssertEqual(filter.localToneMapAmount,nativeLocal)
        if filter.isSharpnessSupported { XCTAssertEqual(filter.sharpnessAmount,0,"HEIF Pro RAW显影不应叠加边缘锐化") }
        if filter.isDetailSupported { XCTAssertEqual(filter.detailAmount,0,"HEIF Pro RAW显影不应叠加边缘细节增强") }
        let base = try XCTUnwrap(filter.outputImage)
        let corrected = AdaptiveDynamicRenderer.apply(base,hdr:false,context:context)
        filter.localToneMapAmount = 0.35
        let suppressed = try XCTUnwrap(filter.outputImage)
        var samples:[(String,CIImage)] = [("preview",CIImage(image:try XCTUnwrap(preview))!), ("oldRAW035",suppressed),("systemRAW",base),("corrected",corrected)]
        samples.append(("actualHEIF",try XCTUnwrap(CIImage(data:shot.resources[0].data))))
        for (label,image) in samples {
            let stats = AdaptiveDynamicRenderer.analyze(image,context:context)
            print("BACKLIT-CAPTURE variant=\(label) nativeLocal=\(nativeLocal) median=\(stats.median) white=\(stats.white) shadowEV=\(stats.shadowEV)")
            let e = image.extent, scale = min(1,1000/max(e.width,e.height)), small = image.transformed(by:.init(scaleX:scale,y:scale))
            let cg = try XCTUnwrap(context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
            let attachment = XCTAttachment(image:UIImage(cgImage:cg)); attachment.name = "Backlit-"+label; attachment.lifetime = .keepAlways; add(attachment)
        }
        print("BACKLIT-CAPTURE seconds=\(CACurrentMediaTime()-start) noPhotosWrite=true")
    }
    /// 仅在用户明确批准一次相册写入验收时，通过临时xctestrun环境变量运行。
    /// 常规全量测试默认跳过，避免向用户相册添加诊断照片。
    @MainActor func testExplicitlyAuthorizedRAWArchiveRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_ALLOW_RAW_ARCHIVE_PHOTOS"] == "1" else { throw XCTSkip("需要用户明确批准临时相册写入") }
        executionTimeAllowance = 120
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var photo:CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0 }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(camera.message ?? "相机超时"); throw CancellationError()
        }
        model.setCameraActive(true); try await wait { camera.ready }
        model.setMode(.auto); model.photoFormat = .heifPro; model.photoResolution = .standard; model.hdr = false
        model.style = .original; model.tone = .natural; model.setAdaptiveHighDynamic(true)
        try await Task.sleep(for:.seconds(1))
        camera.capture(flashMode:.off,options:model.photoOptions)
        try await wait { photo != nil && camera.pendingPhotoCount == 0 }
        let shot = try XCTUnwrap(photo), originalRAW = try XCTUnwrap(shot.resources.first(where:{ $0.alternate })).data
        let service = SystemPhotoLibraryService()
        let assetID:String = try await withCheckedThrowingContinuation { c in service.saveCapture(shot) { c.resume(with:$0) } }
        print("RAW-ARCHIVE createdAsset=\(assetID)")
        func open() async throws -> PhotoEditSession {
            try await withCheckedThrowingContinuation { c in _ = service.openEditor(id:assetID) { c.resume(with:$0) } }
        }
        do {
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers:[assetID],options:nil).firstObject)
            let resources = PHAssetResource.assetResources(for:asset)
            XCTAssertEqual(resources.filter { PhotoResourceKind.isRAW(typeIdentifier:$0.uniformTypeIdentifier,filename:$0.originalFilename) }.count,1)
            print("RAW-ARCHIVE savedResources=\(resources.map { String($0.type.rawValue)+":"+$0.uniformTypeIdentifier })")
            let session = try await open(), developer = try XCTUnwrap(session.rawDevelopment)
            XCTAssertEqual(developer.raw,originalRAW,"Photos读回的DNG必须逐字节一致")
            var changes = session.initialAdjustments; changes.filterAdjustments[.exposure] = 0.5
            changes.filterAdjustments[.temperature] = 10
            changes.rawDevelopment?.hdr = true
            _ = try await withCheckedThrowingContinuation { (c:CheckedContinuation<PhotoEditResult,Error>) in session.save(changes) { c.resume(with:$0) } }
            let reopened = try await open(), reopenedRAW = try XCTUnwrap(reopened.rawDevelopment)
            XCTAssertEqual(reopened.initialAdjustments,changes,"重新打开必须恢复显影配方")
            XCTAssertEqual(reopenedRAW.raw,originalRAW,"覆盖编辑不能破坏原DNG")
            let details:PhotoDetails = try await withCheckedThrowingContinuation { c in _ = service.details(id:assetID) { c.resume(with:$0) } }
            XCTAssertTrue(details.rows.contains { $0.title == "RAW底片" && $0.value == "已附带，可重新显影" })
            print("RAW-ARCHIVE readbackBytes=\(originalRAW.count) editedAndReopened=true hdr=true metadataRAWConfirmed=true")
        } catch {
            print("RAW-ARCHIVE failed=\(error)")
            do { try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in service.delete(assetID:assetID) { c.resume(with:$0) } }; print("RAW-ARCHIVE cleanup=true") }
            catch { print("RAW-ARCHIVE cleanup=false asset=\(assetID) error=\(error)") }
            throw error
        }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in service.delete(assetID:assetID) { c.resume(with:$0) } }
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers:[assetID],options:nil).count,0)
        print("RAW-ARCHIVE cleanup=true onlyCreatedAssetDeleted=true")
    }
    /// 共享文件名可能与Photos资源名不同，改用附件内真实拍摄时间定位用户这三张照片。
    func testSavedAdaptiveRAWResourcesByCaptureDate() async throws {
        let permission = PHPhotoLibrary.authorizationStatus(for:.readWrite)
        guard permission == .authorized || permission == .limited else { throw XCTSkip("相册未授权") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:8*3600); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dates = ["2026:10:27 13:07:37","2026:10:27 13:07:46","2026:10:27 13:09:41"].compactMap { formatter.date(from:$0) }
        var matched = 0, rawCount = 0
        for date in dates {
            let options = PHFetchOptions(); options.predicate = NSPredicate(format:"creationDate >= %@ AND creationDate <= %@",date.addingTimeInterval(-1) as NSDate,date.addingTimeInterval(1) as NSDate)
            let result = PHAsset.fetchAssets(with:.image,options:options)
            result.enumerateObjects { asset,_,_ in
                matched += 1
                let resources = PHAssetResource.assetResources(for:asset)
                let raw = resources.filter { PhotoResourceKind.isRAW(typeIdentifier:$0.uniformTypeIdentifier,filename:$0.originalFilename) }
                rawCount += raw.count
                print("SAVED-ADAPTIVE time=\(formatter.string(from:date)) resources=\(resources.map { String($0.type.rawValue)+":"+$0.uniformTypeIdentifier+":"+$0.originalFilename }) rawCount=\(raw.count)")
            }
        }
        print("SAVED-ADAPTIVE-SUMMARY matchedAssets=\(matched) rawResources=\(rawCount) access=\(permission.rawValue)")
        guard matched > 0 else { throw XCTSkip("拍摄时间内未找到授权可访问的资产，不能推断DNG丢失") }
    }
    /// 只读取用户本次提供的样片及其DNG，不向系统相册写入任何内容。
    func testUserBacklitRAWDevelopment() async throws {
        let permission = PHPhotoLibrary.authorizationStatus(for:.readWrite)
        guard permission == .authorized || permission == .limited else { throw XCTSkip("相册未授权") }
        let names:Set<String> = ["Luma-716FF960-1B97-4015-9A2D-822D663A7886.HEIC", "Luma-919DB456-460E-4642-B529-68F934F2BF49.HEIC", "Luma-F1A89CBB-A11F-4151-8EB1-CF84FF883D65.HEIC", "Luma-F0A8E599-9A75-404A-B8E7-DB3FEFEA0212.HEIC"]
        var matches:[(String,PHAssetResource)] = []
        PHAsset.fetchAssets(with:.image,options:nil).enumerateObjects { asset,_,stop in
            let resources = PHAssetResource.assetResources(for:asset)
            guard let photo = resources.first(where:{ names.map { $0.lowercased() }.contains($0.originalFilename.lowercased()) }),
                  let raw = resources.first(where:{ $0.originalFilename.lowercased().hasSuffix(".dng") }) else { return }
            matches.append((photo.originalFilename,raw)); if matches.count == names.count { stop.pointee = true }
        }
        guard !matches.isEmpty else { throw XCTSkip("样片资产中未找到DNG；不能把HEIC当RAW对照") }
        for (name,resource) in matches {
            let raw:Data = try await withCheckedThrowingContinuation { continuation in
                let data = NSMutableData(), opts = PHAssetResourceRequestOptions(); opts.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().requestData(for:resource,options:opts,dataReceivedHandler:{ data.append($0) },completionHandler:{ error in
                    if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:data as Data) }
                })
            }
            let decoder = try XCTUnwrap(CIRAWFilter(imageData:raw,identifierHint:nil))
            let originalLocal = decoder.localToneMapAmount
            decoder.scaleFactor = Float(min(1,1000/max(decoder.nativeSize.width,decoder.nativeSize.height)))
            AdaptiveRAWDeveloper.configure(decoder,adaptive:true,hdr:true,adjustments:FilterAdjustments())
            XCTAssertEqual(decoder.localToneMapAmount,originalLocal)
            let developed = try XCTUnwrap(decoder.outputImage)
            let corrected = AdaptiveDynamicRenderer.apply(developed,hdr:true,context:context)
            decoder.localToneMapAmount = 0.35
            let old = try XCTUnwrap(decoder.outputImage)
            for (label,image) in [("systemBase",developed),("old035",old),("corrected",corrected)] {
                let analysis = AdaptiveDynamicRenderer.analyze(image,context:context)
                print("BACKLIT-RAW name=\(name) variant=\(label) nativeLocal=\(originalLocal) median=\(analysis.median) white=\(analysis.white) shadowEV=\(analysis.shadowEV)")
                let cg = try XCTUnwrap(context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
                let attachment = XCTAttachment(image:UIImage(cgImage:cg)); attachment.name = name+"-"+label; attachment.lifetime = .keepAlways; add(attachment)
            }
            XCTAssertGreaterThan(AdaptiveDynamicRenderer.analyze(corrected,context:context).median,AdaptiveDynamicRenderer.analyze(old,context:context).median)
        }
    }
    #endif
    private let context = CIContext(options:[.cacheIntermediates:false])
    private func chart(_ values:[Float],width:Int = 800,height:Int = 400) -> CIImage {
        var bytes = [Float](repeating:1,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let p = (y*width+x)*4, v = values[min(values.count-1,x*values.count/width)]
            bytes[p] = v; bytes[p+1] = v*0.8; bytes[p+2] = v*0.5
        } }
        return CIImage(bitmapData:bytes.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:CGSize(width:width,height:height),
            format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
    }
    private func rgb(_ image:CIImage,x:Int,y:Int) -> [Float] {
        var value = [Float](repeating:0,count:4)
        value.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) }
        return value
    }
    private func smallPixels(_ data:Data) throws -> [Float] {
        let image = try XCTUnwrap(CIImage(data:data)), e = image.extent
        let small = image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY))
            .transformed(by:CGAffineTransform(scaleX:64/e.width,y:64/e.height))
        var values = [Float](repeating:0,count:64*64*4)
        values.withUnsafeMutableBytes { context.render(small,toBitmap:$0.baseAddress!,rowBytes:64*16,bounds:CGRect(x:0,y:0,width:64,height:64),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) }
        return values
    }
    func testSmallDeepShadowIsRecoveredWhenGlobalMedianIsAlreadyBright() throws {
        let input = chart(Array(repeating: Float(0.002), count: 5) + Array(repeating: Float(0.25), count: 90)
            + Array(repeating: Float(2), count: 5), width: 2000)
        let a = AdaptiveDynamicRenderer.analyze(input, context: context)
        print("ADAPTIVE-DEEP-ANALYSIS \(a)")
        XCTAssertGreaterThan(a.median, 0.14)
        XCTAssertEqual(a.shadowEV, 0)
        XCTAssertGreaterThan(a.deepShadowEV, 1)
        let output = AdaptiveDynamicRenderer.apply(input, hdr: false, context: context)
        XCTAssertGreaterThan(rgb(output, x: 30, y: 100)[0], rgb(input, x: 30, y: 100)[0] * 3)
        XCTAssertEqual(rgb(output, x: 1000, y: 100)[0], rgb(input, x: 1000, y: 100)[0], accuracy: 0.001,
                       "深暗部补偿不能继续抬高明亮墙面")
        let dark = chart([0, 0.0002, 0.001, 0.005, 0.02])
        XCTAssertEqual(AdaptiveDynamicRenderer.analyze(dark, context: context).deepShadowEV, 0)
        print("ADAPTIVE-DEEP-SHADOW median=\(a.median) globalEV=\(a.shadowEV) deepEV=\(a.deepShadowEV) dark-before=\(rgb(input,x:30,y:100)[0]) after=\(rgb(output,x:30,y:100)[0])")
    }

    func testLinearHighlightShadowColorAndPerformance() throws {
        let input = chart([0,0.002,0.02,0.08,0.18,0.65,2,8])
        let sdr = AdaptiveDynamicRenderer.apply(input,hdr:false,context:context)
        let hdr = AdaptiveDynamicRenderer.apply(input,hdr:true,context:context)
        XCTAssertLessThan(abs(rgb(sdr,x:50,y:100)[0]),0.0001)
        XCTAssertGreaterThan(rgb(sdr,x:250,y:100)[0],rgb(input,x:250,y:100)[0])
        let a = rgb(sdr,x:650,y:100), b = rgb(sdr,x:750,y:100)
        XCTAssertLessThan(b[0],1.3); XCTAssertGreaterThan(b[0],a[0])
        XCTAssertGreaterThan(rgb(hdr,x:750,y:100)[0],1)
        XCTAssertEqual(rgb(hdr,x:250,y:100)[0],rgb(input,x:250,y:100)[0],accuracy:0.001,
                       "PQ HDR只处理参考白以上高光，不能抬高RAW基准暗部")
        XCTAssertEqual(rgb(hdr,x:450,y:100)[0],rgb(input,x:450,y:100)[0],accuracy:0.001,
                       "PQ HDR应保留RAW中灰层次")
        XCTAssertEqual(a[0]/a[1],1.25,accuracy:0.015)
        for style in [FilmStyle.leicaM9,.fujiNC,.fujiCC,.mono] {
            let filtered = AdaptiveDynamicRenderer.filtered(input,look:CaptureLook(style:style),hdr:true)
            let lower = rgb(filtered,x:650,y:100), upper = rgb(filtered,x:750,y:100)
            XCTAssertGreaterThan(upper[0],lower[0]+0.1,"\(style)应保留HDR亮度层次")
            XCTAssertGreaterThan(upper[0],1)
        }
        let backlit = chart([0,0.0005,0.001,0.002,0.004,0.008,0.02,0.05,0.18,0.6,2,8],width:1200)
        let recovered = AdaptiveDynamicRenderer.apply(backlit,hdr:false,context:context)
        var previous:Float = -1
        for index in 0..<12 {
            let current = rgb(recovered,x:index*100+50,y:100)[0]
            XCTAssertGreaterThan(current,previous,"逆光曲线必须保持亮度次序")
            previous = current
        }
        XCTAssertGreaterThan(rgb(recovered,x:250,y:100)[0],rgb(backlit,x:250,y:100)[0]*2,"深暗部不能被门限忽略")
        let dark = chart([0,0.0002,0.001,0.005,0.02])
        XCTAssertEqual(AdaptiveDynamicRenderer.analyze(dark,context:context).shadowEV,0,"缺少大面积亮区时不能把黑夜提灰")
        let soft = chart([0.12,0.18,0.22,0.3])
        XCTAssertEqual(AdaptiveDynamicRenderer.analyze(soft,context:context).shadowEV,0)
        let large = input.transformed(by:CGAffineTransform(scaleX:3,y:3))
        var times:[Double] = []
        for _ in 0..<6 {
            let start = CACurrentMediaTime(), output = AdaptiveDynamicRenderer.apply(large,hdr:false,context:context)
            XCTAssertNotNil(context.createCGImage(output,from:output.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
            times.append(CACurrentMediaTime()-start)
        }
        print("ADAPTIVE-GPU pixels=2880000 samples=6 seconds=\(times) analysis=\(AdaptiveDynamicRenderer.analyze(input,context:context))")
    }
    #if !targetEnvironment(simulator)
    @MainActor func testCaptureRAWRecipeRedevelopmentAndExposure() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var photos:[CapturedPhoto] = []
        camera.onCaptureCompleted = { if let p = $0 { photos.append(p) } }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ name:String,_ condition:()->Bool) async throws {
            for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(name+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.photo)
        if model.currentPosition != .back { model.flipCamera(); try await wait("后置") { camera.ready && model.currentPosition == .back } }
        model.photoFormat = .heifPro; model.photoResolution = .standard; model.style = .original; model.tone = .natural
        var seconds:[Double] = []
        for pass in [0, 1, 2, 4] {
            model.setMode(pass == 1 || pass == 4 ? .manual : .auto)
            if pass == 4 {
                if let main = camera.lenses.first(where:{ $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoomFactor == 1 }) {
                    model.selectFocalLength(main)
                }
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await wait("主摄48MP能力") { camera.ready && camera.availableResolutions.contains(.high) }
                model.photoResolution = .high
            }
            if pass == 1 { model.manualExposure = true; model.iso = 100; model.shutter = log2(1.0/120); model.applyExposure() }
            model.hdr = pass == 2; model.setAdaptiveHighDynamic(true)
            if pass == 2 { model.filterAdjustments[.exposure] = 0.5; model.filterAdjustments[.temperature] = 12; model.tone = .cinematic }
            else { model.filterAdjustments = FilterAdjustments(); model.tone = .natural }
            // 编辑页窗口会让真实相机页暂停；下一组模拟返回相机，并等新路线真实出帧。
            await Task.yield()
            model.setCameraActive(true)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let readyAfter = CACurrentMediaTime()
            try await wait("规格和RAW可用") { camera.ready && model.adaptiveHighDynamicAvailable
                && !camera.highResolutionPhotoConfiguring && camera.previewFrameTimeForTesting > readyAfter }
            XCTAssertTrue(model.photoOptions.adaptiveHighDynamic)
            let config = await withCheckedContinuation { c in camera.photoOutputConfigurationForTesting { c.resume(returning:$0) } }
            print("ADAPTIVE-CONFIG pass=\(pass) \(config)")
            let start = CACurrentMediaTime(), before = photos.count
            camera.capture(flashMode:.off,options:model.photoOptions)
            try await wait("RAW+HEIF完成") { photos.count > before && camera.pendingPhotoCount == 0 }
            let photo = try XCTUnwrap(photos.last), heif = try XCTUnwrap(photo.resources.first(where:{ !$0.alternate })), raw = try XCTUnwrap(photo.resources.first(where: { $0.alternate }))
            seconds.append(CACurrentMediaTime()-start)
            XCTAssertTrue(raw.filename.hasSuffix(".dng"))
            let src = try XCTUnwrap(CGImageSourceCreateWithData(heif.data as CFData,nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any])
            let recipe = try XCTUnwrap(RAWDevelopmentRecipe.read(props))
            XCTAssertTrue(recipe.rawDevelopment?.adaptive == true); XCTAssertEqual(recipe.rawDevelopment?.hdr,pass == 2)
            if pass == 2 { HDRImageAssertions.assertHDR(src, "Adaptive HDR HEIF") }
            else { XCTAssertEqual(props[kCGImagePropertyDepth as String] as? Int, 8) }
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
            let exposure = try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double)
            XCTAssertGreaterThan(exposure,0)
            if pass == 1 { XCTAssertEqual(exposure,1.0/120,accuracy:0.001) }
            let developer = RAWPhotoDevelopment(raw:raw.data,initial:recipe,metadata:props)
            let rendered = try developer.render(recipe)
            let rs = try XCTUnwrap(CGImageSourceCreateWithData(rendered.resource.data as CFData,nil))
            let rp = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(rs,0,nil) as? [String:Any])
            XCTAssertEqual(rp[kCGImagePropertyPixelWidth as String] as? Int,props[kCGImagePropertyPixelWidth as String] as? Int)
            XCTAssertEqual(rp[kCGImagePropertyPixelHeight as String] as? Int,props[kCGImagePropertyPixelHeight as String] as? Int)
            if pass == 2 { HDRImageAssertions.assertHDR(rs, "Adaptive HDR 重新渲染") }
            else { XCTAssertEqual(rp[kCGImagePropertyDepth as String] as? Int, 8) }
            XCTAssertEqual((rp[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,1)
            XCTAssertEqual(RAWDevelopmentRecipe.read(rp),recipe)
            if pass == 2 {
                let a = try smallPixels(heif.data), b = try smallPixels(rendered.resource.data)
                let error = sqrt(zip(a,b).reduce(0) { $0+Double(($1.0-$1.1)*($1.0-$1.1)) } / Double(a.count))
                XCTAssertLessThan(error,0.025); print("ADAPTIVE-HDR-RECIPE rmse=\(error) toneAndRAWControls=true")
                XCTAssertEqual(try developer.preview(recipe).cgImage?.bitsPerComponent,16)
                XCTAssertTrue((rp[kCGImagePropertyProfileName as String] as? String ?? "").contains("PQ"))
            }
            if pass == 0 {
                let a = try smallPixels(heif.data), b = try smallPixels(rendered.resource.data)
                let rmse = sqrt(zip(a,b).reduce(0) { $0+Double(($1.0-$1.1)*($1.0-$1.1)) } / Double(a.count))
                XCTAssertLessThan(rmse,0.025,"重新显影必须重建相同画面，不能将滤镜或RAW控制叠加两次")
                var altered = recipe; altered.filterAdjustments[.exposure] = -1; altered.filterAdjustments[.temperature] = 20
                altered.rawDevelopment?.adaptive = false
                XCTAssertNotNil(try developer.preview(altered))
                var samples:[Double] = []
                for n in 0..<12 {
                    altered.filterAdjustments[.exposure] = Double(n-6)/10
                    let t = CACurrentMediaTime(); _ = try developer.preview(altered); samples.append(CACurrentMediaTime()-t)
                }
                let modified = try developer.render(altered)
                XCTAssertNotEqual(try smallPixels(modified.resource.data),a)
                altered.quarterTurns = 1; altered.crop = PhotoCropRectangle(x:0.1,y:0.2,width:0.812345,height:0.612345)
                let cropped = try developer.render(altered)
                let cs = try XCTUnwrap(CGImageSourceCreateWithData(cropped.resource.data as CFData,nil))
                let cp = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cs,0,nil) as? [String:Any])
                let ce = try XCTUnwrap(cp[kCGImagePropertyExifDictionary as String] as? [String:Any])
                XCTAssertEqual(ce[kCGImagePropertyExifPixelXDimension as String] as? Int,cp[kCGImagePropertyPixelWidth as String] as? Int)
                XCTAssertEqual(ce[kCGImagePropertyExifPixelYDimension as String] as? Int,cp[kCGImagePropertyPixelHeight as String] as? Int)
                let again = try developer.render(recipe)
                XCTAssertFalse(again.resource.data.isEmpty)
                let staged = try PhotoLibraryStagedResources([rendered.resource,raw]); defer { staged.cleanup() }
                XCTAssertEqual(staged.entries.count,2)
                XCTAssertEqual(try Data(contentsOf:staged.entries[1].url),raw.data)
                let image = XCTAttachment(image:rendered.preview); image.name = "Adaptive-RAW-redeveloped"; image.lifetime = .keepAlways; add(image)
                print("ADAPTIVE-REDEVELOP rmse=\(rmse) previewSamples=12 seconds=\(samples) originalBytesUnchanged=true")
                // 真机编辑页消费实际底片，覆盖HDR预览、快速参数更新和取消后的迟到发布。
                let session = PhotoEditSession(source:try developer.source(recipe,preview:true),initialAdjustments:recipe,rawDevelopment:developer) { _,_ in }
                let editing = PhotoEditorViewModel(session:session,library:model.library)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let old = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
                window.rootViewController = UIHostingController(rootView:PhotoEditorView(model:editing)); window.makeKeyAndVisible()
                defer { editing.cancelPreview(); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
                editing.renderPreview(); try await wait("RAW编辑预览") { editing.preview != nil }
                editing.adjustments.rawDevelopment?.hdr = true
                try await wait("RAW编辑HDR预览") { editing.preview?.cgImage?.bitsPerComponent == 16 }
                for n in 0..<30 { editing.adjustments.filterAdjustments[.exposure] = Double(n-15)/20 }
                try await Task.sleep(for:.milliseconds(300)); XCTAssertNil(editing.message)
                let screenshot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                let e = XCTAttachment(image:screenshot); e.name = "Adaptive-RAW-editor"; e.lifetime = .keepAlways; add(e)
                editing.cancelPreview(); let last = editing.preview
                try await Task.sleep(for:.milliseconds(150)); XCTAssertTrue(editing.preview === last)
                print("ADAPTIVE-EDITOR rapidUpdates=30 hdrPreviewBits=16 cancelledPublicationStable=true")
            }
            print("ADAPTIVE-CAPTURE pass=\(pass) hdr=\(model.hdr) seconds=\(seconds.last!) rawBytes=\(raw.data.count) heifBytes=\(heif.data.count) extent=\(props[kCGImagePropertyPixelWidth as String] ?? 0)x\(props[kCGImagePropertyPixelHeight as String] ?? 0) exposure=\(exposure)")
        }
        model.flipCamera(); try await wait("前置") { camera.ready && model.currentPosition == .front }
        model.photoFormat = .heif; model.photoResolution = .standard; model.hdr = false
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait("前置能力") { camera.ready }
        XCTAssertFalse(model.adaptiveHighDynamicAvailable, "前置无 RAW，不能提供自适应高动态")
        XCTAssertFalse(model.photoOptions.adaptiveHighDynamic)
        model.flipCamera(); try await wait("回后置") { camera.ready && model.currentPosition == .back }
        model.photoFormat = .jpeg; model.setMode(.auto); model.photoResolution = .standard; model.flushCaptureSettings()
        XCTAssertFalse(model.adaptiveHighDynamic)
        print("ADAPTIVE-CAPTURE-SUMMARY samples=\(seconds.count) seconds=\(seconds) noPhotosWrite=true")
    }
    @MainActor func testFormatPanelLayoutAndRepeatedSwitching() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first), old = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView:DynamicFormatHost(model:model,angle:0)), window = UIWindow(windowScene:scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; old?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); model.toolbarPanel = .format; model.photoFormat = .heifPro
        for format in PhotoFileFormat.allCases {
            model.photoFormat = format
            for angle in [0.0,90,-90,180] {
            host.rootView = DynamicFormatHost(model:model,angle:angle)
            try await Task.sleep(for:.milliseconds(250))
            let hdr = try XCTUnwrap(model.captureButtonFramesForTesting["format.hdr"]), dynamic = try XCTUnwrap(model.captureButtonFramesForTesting["format.highDynamic"])
            let panel = try XCTUnwrap(model.captureButtonFramesForTesting["format.panel"])
            let explanation = try XCTUnwrap(model.captureButtonFramesForTesting["format.highDynamic.explanation"])
            XCTAssertLessThan(hdr.maxX,dynamic.minX); XCTAssertEqual(hdr.midY,dynamic.midY,accuracy:1)
            XCTAssertLessThanOrEqual(panel.height,380); XCTAssertTrue(panel.insetBy(dx:-1,dy:-1).contains(explanation))
            }
        }
        model.photoFormat = .heifPro
        host.rootView = DynamicFormatHost(model:model,angle:0)
        try await Task.sleep(for:.milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let a = XCTAttachment(image:image); a.name = "Adaptive-format-panel"; a.lifetime = .keepAlways; add(a)
        for _ in 0..<30 { model.setAdaptiveHighDynamic(true); model.setAdaptiveHighDynamic(false) }
        model.setAdaptiveHighDynamic(true)
        model.setCameraActive(false); model.setCameraActive(true)
        try await Task.sleep(for:.milliseconds(500)); XCTAssertNil(model.toolbarPanel)
        print("ADAPTIVE-LAYOUT formats=6 orientations=4 switches=60 noPhotosWrite=true")
    }
    #endif
}
