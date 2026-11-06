import AVFoundation
import XCTest
import UIKit
@testable import LumaCamera

@MainActor final class VideoLensSpecificationAuditTests:XCTestCase {
    func testVideoAndPresetCapabilityInventoryPerNativeLens() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<1000 { if camera.ready && !camera.lenses.isEmpty { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        func label(_ value:VideoCaptureSettings)->String {
            "\(value.resolution.title)/\(value.frameRate.rawValue)/\(value.colorSpace.rawValue)"+(value.captureFrameRate.map { "/capture\($0.rawValue)" } ?? "")
        }
        var rows = [[String:Any]]()
        let start = CACurrentMediaTime()
        for lens in camera.lenses.filter({ $0.device.position == .back && abs($0.zoomFactor-1)<0.001 }) {
            let device = lens.device
            let ordinary = VideoCaptureSettings.supported(by:device)
            let slow = VideoCaptureSettings.slowMotionCaptureRates(by:device)
            let cinematic = VideoCaptureSettings.cinematicVideoSupported(by:device)
            let openGate = VideoCaptureSettings.openGateSupported(by:device)
            let row:[String:Any] = ["focal":Double(lens.displayZoom),"type":device.deviceType.rawValue,
                "ordinary":ordinary.map(label),"slowCapture":slow.map(label),"physicalCinematic":cinematic.map(label),
                "openGate":openGate.map(label),"formatCount":device.formats.count]
            rows.append(row)
            print("VIDEO-LENS-CAP "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for (name,mode) in [("timeLapse",VideoSubmode.timeLapse),("slowMotion",.slowMotion),("cinematic",.cinematic)] {
            let routes = await withCheckedContinuation { c in camera.compatibleVideoSubmodeRoutes(for:mode,position:.back,openGateEnabled:false) { c.resume(returning:$0) } }
            for route in routes {
                let lens = try XCTUnwrap(camera.lenses.first { $0.id == route.lensID })
                let row:[String:Any] = ["mode":name,"focal":Double(lens.displayZoom),"specifications":route.settings.map(label)]
                rows.append(row)
                print("VIDEO-PRESET-CAP "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
            }
        }
        if #available(iOS 26.0, *), let device = AVCaptureDevice.default(.builtInDualWideCamera,for:.video,position:.back) {
            let settings = VideoCaptureSettings.cinematicVideoSupported(by:device)
            let limits = settings.compactMap { value -> [String:Any]? in
                guard let format = VideoCaptureSettings.format(for:value,device:device,requiringCinematicVideo:true) else { return nil }
                return ["setting":label(value),"minPhysicalZoom":Double(format.videoMinZoomFactorForCinematicVideo),"maxPhysicalZoom":Double(format.videoMaxZoomFactorForCinematicVideo)]
            }
            let row:[String:Any] = ["mode":"cinematicActualRoute","type":device.deviceType.rawValue,
                "constituents":device.constituentDevices.map { $0.deviceType.rawValue },"zoomMultiplier":Double(CameraLensCatalog.displayMultiplier(device)),"limits":limits]
            rows.append(row)
            print("VIDEO-CINEMATIC-ROUTE "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
        let data = try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name = "Video-native-lenses-and-preset-capabilities.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("VIDEO-CAP-PERF rows=\(rows.count) seconds=\(CACurrentMediaTime()-start) staticInventoryOnly=true noPhotosWrites=true")
    }

    func testRealOrdinarySlowMotionAndTimeLapseFilesPerNativeLens() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        let runtime = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var result:Result<URL,Error>?, files = [URL](), records = [[String:Any]]()
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish()
            files.forEach { try? FileManager.default.removeItem(at:$0) }
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("视频就绪") { camera.ready && !camera.videoConfiguring && !camera.videoBusy }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); model.setMode(.manual)
        model.manualExposure = false; model.manualWB = false; model.manualFocus = false
        model.restoreDeviceParametersForTesting(); try await settle()
        let lenses = camera.lenses.filter { $0.device.position == .back && abs($0.zoomFactor-1)<0.001 }
        for lens in lenses {
            camera.selectLens(lens); try await settle()
            XCTAssertEqual(camera.activeCaptureDeviceID,lens.device.uniqueID)
            var scenarios:[(String,VideoCaptureSettings,Bool)] = [("ordinary4K60",.init(resolution:.uhd4K,frameRate:.fps60),false)]
            let high = VideoCaptureSettings(resolution:.uhd4K,frameRate:.fps120)
            if VideoCaptureSettings.format(for:high,device:lens.device) != nil {
                scenarios.append(("ordinary4K120",high,false)); scenarios.append(("ordinary4K120-repeat",high,false))
            }
            let slowRates = VideoCaptureSettings.slowMotionCaptureRates(by:lens.device)
            if let best = slowRates.first(where:{ $0.resolution == .hd1080 && $0.colorSpace == .sdr && $0.frameRate == .fps240 })
                ?? slowRates.first(where:{ $0.resolution == .hd1080 && $0.colorSpace == .sdr }) {
                var value = VideoCaptureSettings(resolution:.hd1080,frameRate:.fps30)
                value.captureFrameRate = best.frameRate
                scenarios.append(("slow1080-capture\(best.frameRate.rawValue)",value,false))
            }
            scenarios.append(("timeLapse4K30-1s",.init(resolution:.uhd4K,frameRate:.fps30),true))
            for (name,settings,timeLapse) in scenarios {
                result = nil
                camera.setVideoSettings(settings); try await settle()
                XCTAssertEqual(camera.videoSettings,settings)
                let state:(String,Double,Double,[String]) = await withCheckedContinuation { c in
                    camera.videoFormatStateForTesting { c.resume(returning:($0,$1,$2,$3)) }
                }
                let route = await withCheckedContinuation { c in camera.photoResolutionAuditForTesting { c.resume(returning:$0) } }
                XCTAssertEqual(route["deviceID"],lens.device.uniqueID)
                let start = CACurrentMediaTime()
                camera.startVideoRecording(aspect:.wide,timeLapseEnabled:timeLapse,timeLapseInterval:timeLapse ? 1:nil,timeLapseFrameLimit:timeLapse ? 3:nil)
                try await wait("录制开始") { camera.videoRecording || result != nil }
                XCTAssertTrue(camera.videoRecording)
                if timeLapse { try await wait("延时三帧完成") { result != nil } }
                else { try await Task.sleep(for:.milliseconds(1200)); camera.stopVideoRecording(); try await wait("文件交付") { result != nil } }
                let url = try XCTUnwrap(result).get(); files.append(url)
                let asset = AVURLAsset(url:url)
                let tracks = try await asset.loadTracks(withMediaType:.video)
                let track = try XCTUnwrap(tracks.first)
                let fps = try await track.load(.nominalFrameRate), size = try await track.load(.naturalSize)
                let duration = try await asset.load(.duration)
                let reader = try AVAssetReader(asset:asset)
                let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                var count = 0, first:Double?, last:Double?
                while let sample = output.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if first == nil { first = t }; last = t; count += 1
                }
                let decodedFPS = count>1 && (last ?? 0)>(first ?? 0) ? Double(count-1)/((last ?? 0)-(first ?? 0)):0
                XCTAssertGreaterThan(count,timeLapse ? 1:10)
                XCTAssertEqual(fps,Float(settings.frameRate.rawValue),accuracy:6)
                XCTAssertGreaterThan(decodedFPS,Double(settings.frameRate.rawValue)*0.75)
                XCTAssertEqual(max(size.width,size.height),settings.resolution.dimensions.width,accuracy:2)
                let row:[String:Any] = ["focal":Double(lens.displayZoom),"name":name,"type":lens.device.deviceType.rawValue,
                    "captureFPS":settings.captureFrameRate?.rawValue ?? settings.frameRate.rawValue,"playbackFPS":settings.frameRate.rawValue,
                    "activeMinFrameSeconds":state.1,"activeMaxFrameSeconds":state.2,"actualFileFPS":fps,
                    "size":"\(size.width)x\(size.height)","duration":duration.seconds,"decodedFrames":count,
                    "decodedFPS":decodedFPS,"seconds":CACurrentMediaTime()-start]
                records.append(row)
                print("VIDEO-LENS-FILE "+String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
                result = nil
            }
        }
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "Video-per-lens-actual-file-parameters.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("VIDEO-LENS-SUMMARY lenses=\(lenses.count) files=\(records.count) noPhotosWrites=true temporaryFilesRemoved=true codecs=HEVC color=SDR")
    }
}
