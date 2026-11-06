import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import LumaCamera

/// 实物路由与落盘格式数据审计；直接接管引擎交付，绝不调用照片图库保存。
final class Lens48MPAuditTests:XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func test35mmCropHighResolutionAcrossManualRoute() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, original = camera.onOriginalProcessedPhotoForTesting
        let requestCallback = camera.onPhotoRequestDimensionsForTesting
        let idle = UIApplication.shared.isIdleTimerDisabled, runtime = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var delivered:CapturedPhoto?, sourceSize = "", requested = ""
        camera.onCaptureCompleted = { delivered = $0 }
        func properties(_ data:Data)->[String:Any] {
            guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return [:] }
            return CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] ?? [:]
        }
        func size(_ props:[String:Any])->String {
            "\(props[kCGImagePropertyPixelWidth as String] ?? 0)x\(props[kCGImagePropertyPixelHeight as String] ?? 0)"
        }
        camera.onOriginalProcessedPhotoForTesting = { sourceSize = size(properties($0)) }
        camera.onPhotoRequestDimensionsForTesting = { requested = "\($0.width)x\($0.height)" }
        defer {
            camera.onCaptureCompleted = callback; camera.onOriginalProcessedPhotoForTesting = original
            camera.onPhotoRequestDimensionsForTesting = requestCallback
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish()
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("配置完成") { camera.ready && !camera.highResolutionPhotoConfiguring }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready && camera.preview != nil }
        model.photoFormat = .jpeg; model.ratio = .standard; model.hdr = false; model.smoothPreview = false
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.001 })
        var rows = [[String:String]]()
        model.setMode(.auto); try await settle()
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 必须禁用")
        for mode in [CameraShootingMode.manual] {
            model.photoResolution = .standard; model.setMode(mode); try await settle()
            camera.selectLens(main); try await settle()
            model.photoResolution = .high; try await settle()
            // 产品48MP已禁止连续变焦；能力审计改回普通UI状态后仅对照片请求高像素。
            model.photoResolution = .standard; try await settle()
            camera.setContinuousZoom(35.0/24.0)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            try await settle(); try await Task.sleep(for:.milliseconds(350))
            XCTAssertEqual(camera.currentZoom,35.0/24.0,accuracy:0.01)
            let audit = await withCheckedContinuation { c in camera.photoResolutionAuditForTesting { c.resume(returning:$0) } }
            if mode == .manual { XCTAssertEqual(audit["virtual"],"false") }
            for format in [PhotoFileFormat.jpeg,.heif,.raw] {
                guard camera.availablePhotoFormats.contains(format) else { continue }
                for sample in 0..<2 {
                    delivered = nil; sourceSize = ""; requested = ""
                    var options = model.photoOptions; options.format = format; options.resolution = .high
                    options.hdr = false; options.live = false; options.nightMode = false; options.portraitMode = false
                    let started = CACurrentMediaTime()
                    camera.capture(flashMode:.off,options:options)
                    try await wait("35mm成片") { delivered != nil && camera.pendingPhotoCount == 0 }
                    let photo = try XCTUnwrap(delivered), resource = try XCTUnwrap(photo.resources.first)
                    let props = properties(resource.data)
                    let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
                    var row = audit
                    row["mode"] = mode.rawValue; row["format"] = format.rawValue; row["sample"] = String(sample)
                    row["request"] = requested; row["systemProcessed"] = sourceSize
                    row["actual"] = size(props); row["filename"] = resource.filename
                    row["focal35"] = String(describing:exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] ?? "missing")
                    row["focalLength"] = String(describing:exif[kCGImagePropertyExifFocalLength as String] ?? "missing")
                    row["orientation"] = String(describing:props[kCGImagePropertyOrientation as String] ?? "missing")
                    row["seconds"] = String(CACurrentMediaTime()-started)
                    XCTAssertGreaterThan(props[kCGImagePropertyPixelWidth as String] as? Int ?? 0,1000)
                    XCTAssertEqual((exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue,35)
                    if sample > 0, let previous = rows.last, previous["mode"] == mode.rawValue, previous["format"] == format.rawValue {
                        XCTAssertEqual(row["actual"],previous["actual"],"同路由首张和后续尺寸应一致")
                    }
                    rows.append(row)
                    print("LENS35-FILE "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
                    delivered = nil
                }
            }
            camera.setContinuousZoom(1)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            model.photoResolution = .standard; try await settle()
        }
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "35mm-high-resolution-actual-files.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("LENS35-SUMMARY files=\(rows.count) modes=M requestedZoom=\(35.0/24.0) noPhotosWrites=true productZoomPolicyBypassedForCapabilityAudit=true")
    }

    @MainActor func testEveryPhysicalLensAndCropRouteHighResolutionFiles() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, requestCallback = camera.onPhotoRequestDimensionsForTesting
        let idle = UIApplication.shared.isIdleTimerDisabled, runtime = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var delivered:CapturedPhoto?, request = CMVideoDimensions(width:0,height:0)
        camera.onCaptureCompleted = { delivered = $0 }
        camera.onPhotoRequestDimensionsForTesting = { request = $0 }
        defer {
            camera.onCaptureCompleted = callback; camera.onPhotoRequestDimensionsForTesting = requestCallback
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish()
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready && camera.preview != nil }
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait("物理路由") { camera.ready && model.mode == .manual }
        model.photoResolution = .standard; model.photoFormat = .jpeg; model.ratio = .standard
        model.hdr = false; model.smoothPreview = false
        model.manualExposure = false; model.manualWB = false; model.manualFocus = false
        model.restoreDeviceParametersForTesting()
        let lenses = camera.lenses
        XCTAssertFalse(lenses.isEmpty)
        var rows = [[String:String]](), switches = [Double]()
        for lens in lenses {
            let began = CACurrentMediaTime()
            camera.selectLens(lens)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("选镜 "+lens.title) { camera.ready && camera.selectedLens == lens.id && camera.activeCaptureDeviceID == lens.device.uniqueID }
            try await Task.sleep(for:.milliseconds(350))
            switches.append(CACurrentMediaTime()-began)
            let audit = await withCheckedContinuation { c in camera.photoResolutionAuditForTesting { c.resume(returning:$0) } }
            XCTAssertEqual(audit["virtual"],"false","原生能力验证不能实际拍虚拟多摄")
            print("LENS48-INVENTORY "+String(data:try JSONSerialization.data(withJSONObject:audit,options:[.sortedKeys]),encoding:.utf8)!)
            let formats:[PhotoFileFormat] = [.jpeg,.heif] + (camera.availablePhotoFormats.contains(.raw) ? [.raw]:[])
            for format in formats {
                guard camera.availablePhotoFormats.contains(format) else { continue }
                for sample in 0..<(format == .raw ? 1:2) {
                    delivered = nil; request = .init(width:0,height:0)
                    var options = model.photoOptions
                    options.format = format; options.resolution = .high; options.hdr = false
                    options.live = false; options.nightMode = false; options.portraitMode = false
                    let start = CACurrentMediaTime()
                    camera.capture(flashMode:.off,options:options)
                    try await wait("成片 "+lens.title+" "+format.rawValue) { delivered != nil && camera.pendingPhotoCount == 0 }
                    let photo = try XCTUnwrap(delivered), resource = try XCTUnwrap(photo.resources.first)
                    let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
                    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                    let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                    let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                    XCTAssertGreaterThan(width*height,1_000_000)
                    let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
                    var row = audit
                    row["route"] = lens.title; row["lensID"] = lens.id
                    row["displayZoom"] = String(Double(lens.displayZoom)); row["catalogNative"] = String(lens.isNative)
                    row["format"] = format.rawValue; row["sample"] = String(sample)
                    row["request"] = "\(request.width)x\(request.height)"
                    row["file"] = resource.filename; row["actual"] = "\(width)x\(height)"
                    row["pixels"] = String(width*height); row["actual48"] = String(width*height>=40_000_000)
                    row["orientation"] = String(describing:props[kCGImagePropertyOrientation as String] ?? "missing")
                    row["focalLength"] = String(describing:exif[kCGImagePropertyExifFocalLength as String] ?? "missing")
                    row["focal35"] = String(describing:exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] ?? "missing")
                    row["seconds"] = String(CACurrentMediaTime()-start)
                    rows.append(row)
                    print("LENS48-FILE "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
                    delivered = nil
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name = "Lens48MP-actual-files-and-format-inventory.json"; attachment.lifetime = .keepAlways; add(attachment)
        // 配置中重复请求可被既有ready门限拒绝；确认快速提交后相机仍能恢复。
        let rear = lenses.filter { $0.device.position == .back }
        if let first = rear.first, let last = rear.last {
            for _ in 0..<3 {
                camera.selectLens(first); camera.selectLens(last)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await wait("快速切换恢复") { camera.ready && !camera.capturing }
            }
        }
        print("LENS48-SUMMARY routes=\(lenses.count) files=\(rows.count) physicalDevices=\(Set(lenses.map { $0.device.uniqueID }).count) switchReadySeconds=\(switches) rapidSwitchCycles=3 noPhotosWrites=true fixedScene=true notSharpnessValidation=true")
    }
    #endif
}
