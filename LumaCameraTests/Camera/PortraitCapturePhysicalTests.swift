import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import LumaCamera

final class PortraitCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor
    func testPortraitModeKeepsAutomaticVirtualCameraAvailableForMacro() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let oldReady = camera.ready
        let oldKind = model.captureKind
        let oldMode = model.mode
        let oldFormat = model.photoFormat
        let oldHDR = model.hdr
        let oldPortrait = model.portraitModeEnabled
        let oldLensID = camera.selectedLens
        let oldZoom = camera.currentZoom
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.portraitModeEnabled != oldPortrait { model.togglePortraitMode() }
            model.hdr = oldHDR
            model.photoFormat = oldFormat
            model.setMode(oldMode)
            if model.captureKind != oldKind { model.setCaptureKind(oldKind) }
            if let lens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(lens)
                camera.setContinuousZoom(oldZoom)
            }
            model.setCameraActive(false)
            Task { @MainActor in model.setCameraActive(oldReady) }
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }

        model.setCaptureKind(.photo)
        model.setMode(.auto)
        model.hdr = false
        model.photoFormat = .heif
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera did not become ready")
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        if camera.selectedLens != main.id || abs(camera.currentZoom - 1) > 0.02 { model.selectFocalLength(main) }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<250 where !camera.ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.supportsPortraitCapture)

        var transitionDurations: [Double] = []
        for cycle in 0..<6 {
            let start = CACurrentMediaTime()
            let previousPreview = try XCTUnwrap(camera.preview)
            model.togglePortraitMode()
            XCTAssertTrue(model.focalTransitionImage === previousPreview,
                          "Portrait toggle must place the current preview frame above the camera during reconfiguration.")
            await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
            let state = await withCheckedContinuation { continuation in
                camera.checkAutomaticLensStabilityForTesting { continuation.resume(returning: ($0, $1, $2, $3)) }
            }
            XCTAssertTrue(state.0, "Portrait output change must keep the virtual camera route active.")
            XCTAssertEqual(state.1, AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue,
                           "A mode must retain system-controlled constituent selection after portrait output changes.")
            XCTAssertEqual(state.2, 0)
            XCTAssertNotNil(state.3)
            let fallbacks = await withCheckedContinuation { continuation in
                camera.automaticFallbackTypesForTesting { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(fallbacks.contains(.builtInUltraWideCamera),
                          "The ultra-wide fallback used for automatic macro must remain available.")
            for _ in 0..<120 {
                if model.focalTransitionImage == nil && camera.preview !== previousPreview { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(model.focalTransitionImage, "The old-frame overlay must fade away after a new preview frame.")
            XCTAssertFalse(camera.preview === previousPreview, "The preview must advance beyond the frozen transition frame.")
            transitionDurations.append(CACurrentMediaTime() - start)
            XCTAssertTrue(camera.ready)
            XCTAssertNotNil(camera.preview)
            if cycle < 5 { try await Task.sleep(for: .milliseconds(120)) }
        }
        let sorted = transitionDurations.sorted()
        print("PORTRAIT-MACRO device=iPhone17Pro cycles=\(sorted.count) transition-to-uncovered-seconds median=\(sorted[sorted.count / 2]) max=\(sorted.last ?? 0) virtual-auto=true ultraWideFallback=true; lens activation still depends on live scene focus/exposure")
    }

    /// 必须实际进入系统超广角微距后再按快门，防止仅凭“近处场景”误判覆盖范围。
    @MainActor
    func testAutomaticMacroSuspendsPortraitCaptureAndRecovers() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldReady = camera.ready
        let oldKind = model.captureKind
        let oldMode = model.mode
        let oldFormat = model.photoFormat
        let oldResolution = model.photoResolution
        let oldHDR = model.hdr
        let oldStyle = model.style
        let oldPortrait = model.portraitModeEnabled
        let oldCallback = camera.onCaptureCompleted
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        let oldLensID = camera.selectedLens
        let oldZoom = camera.currentZoom
        let originalPendingSaveCount = model.library.pendingSaveCount
        UIApplication.shared.isIdleTimerDisabled = true

        defer {
            camera.onCaptureCompleted = oldCallback
            if model.portraitModeEnabled != oldPortrait { model.togglePortraitMode() }
            model.hdr = false
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.style = oldStyle
            model.setMode(oldMode)
            if model.captureKind != oldKind { model.setCaptureKind(oldKind) }
            model.hdr = oldHDR
            camera.setPortraitCaptureEnabled(oldPortrait)
            if let lens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(lens)
                camera.setContinuousZoom(oldZoom)
            }
            model.setCameraActive(false)
            Task { @MainActor in model.setCameraActive(oldReady) }
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }

        model.setCaptureKind(.photo)
        model.setMode(.auto)
        model.hdr = false

        model.photoFormat = .heif
        model.photoResolution = .standard
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera did not become ready")
        guard let mainLens = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }) else {
            throw XCTSkip("No rear 1× camera route is available")
        }
        if camera.selectedLens != mainLens.id || abs(camera.currentZoom - 1) > 0.02 { camera.selectLens(mainLens) }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<200 {
            if camera.ready && camera.selectedLens == mainLens.id { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(camera.supportsPortraitCapture, "Current 1× route must support application portrait capture")
        print("PORTRAIT-CAPTURE capabilities route=rear-1x mode=A supports48MP=\(camera.availableResolutions.contains(.high)) supportsHEIFHDR=\(camera.supportsHEIFHDR) supportsProRAW=\(camera.supportsProRAW)")

        camera.photoPhaseTracingForTesting = true
        defer { camera.photoPhaseTracingForTesting = false }
        // 通过真实入口开启，不能只改引擎后再断言视图模型的人像开关仍开启。
        if !model.portraitModeEnabled { model.togglePortraitMode() }
        XCTAssertTrue(model.portraitModeEnabled)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }

        func capture(_ options: PhotoOptions, name: String) async throws -> (CapturedPhoto, TimeInterval) {
            let originalCallback = camera.onOriginalProcessedPhotoForTesting
            camera.onOriginalProcessedPhotoForTesting = { data in
                print("PORTRAIT-NATIVE name=\(name) bytes=\(data.count)")
            }
            defer { camera.onOriginalProcessedPhotoForTesting = originalCallback }
            var requestedDimensions: CMVideoDimensions?
            let dimensionsCallback = camera.onPhotoRequestDimensionsForTesting
            camera.onPhotoRequestDimensionsForTesting = { requestedDimensions = $0 }
            defer { camera.onPhotoRequestDimensionsForTesting = dimensionsCallback }
            let completed = expectation(description: "Portrait capture: \(name)")
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; completed.fulfill() }
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 {
                if camera.ready && !camera.shutterBusy && camera.canCapture() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertFalse(camera.shutterBusy)
            XCTAssertTrue(camera.canCapture())
            let actualRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
            print("PORTRAIT-ROUTE name=\(name) macro=\(camera.macroActive) \(actualRoute)")
            let start = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: options)
            print("PORTRAIT-ACCEPTED name=\(name) pending=\(camera.pendingPhotoCount) busy=\(camera.shutterBusy)")
            await fulfillment(of: [completed], timeout: 55)
            let elapsed = CACurrentMediaTime() - start
            let photo = try XCTUnwrap(result, camera.message ?? "Portrait capture failed: \(name)")
            XCTAssertFalse(photo.resources.isEmpty)
            if options.resolution == .high {
                let requested = try XCTUnwrap(requestedDimensions)
                XCTAssertGreaterThanOrEqual(Int64(requested.width) * Int64(requested.height), 40_000_000,
                    "高像素必须实际请求当前格式的 48MP 上限，而不只是修改 UI")
                print("PORTRAIT-REQUEST name=\(name) max=\(requested.width)x\(requested.height) native=\(photo.diagnostics?.rows.filter { $0.title.contains("输出") } ?? [])")
            }
            XCTAssertEqual(model.library.pendingSaveCount, originalPendingSaveCount, "Diagnostic captures must not be saved to Photos")
            for _ in 0..<250 {
                if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse(camera.shutterBusy)
            return (photo, elapsed)
        }

        if !model.portraitModeEnabled { model.togglePortraitMode() }
        var samples: [Double] = []
        for index in 0..<3 {
            var observedMacroRoute = false
            for _ in 0..<160 {
                let route = await withCheckedContinuation { c in
                    camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) }
                }
                if route.contains("primary=AVCaptureDeviceTypeBuiltInUltraWideCamera") {
                    observedMacroRoute = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(observedMacroRoute, "近距回归必须观察到系统主动选择超广角；请保持近处有纹理主体")
            guard observedMacroRoute else { return }
            var options = PhotoOptions()
            options.format = index == 2 ? .jpeg : .heif
            options.portraitMode = true
            options.shootingType = "人像"
            let (photo, elapsed) = try await capture(options, name: "A macro portrait priority #\(index + 1)")
            XCTAssertNil(photo.diagnostics?.rows.first { $0.title == "人像背景效果" },
                "微距本张应暂停人像处理，而不是生成模糊的微距照片")
            XCTAssertTrue(model.portraitModeEnabled, "暂停本张效果不得关闭用户的人像开关")
            samples.append(elapsed)
        }
        // 快速开关与取消/返回只切换预览状态，不重新配置原生深度输出管线。
        for _ in 0..<6 { model.togglePortraitMode() }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertTrue(model.portraitModeEnabled)
        model.setCameraActive(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready)
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        XCTAssertFalse(camera.shutterBusy)
        print("PORTRAIT-MACRO-CAPTURE samples=\(samples.count) p50=\(samples.sorted()[samples.count / 2]) max=\(samples.max() ?? 0) noPhotosWrites=true")
    }

    @MainActor
    func testPortraitProcessedAndProRAWCapturesWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldReady = camera.ready
        let oldKind = model.captureKind
        let oldMode = model.mode
        let oldFormat = model.photoFormat
        let oldResolution = model.photoResolution
        let oldHDR = model.hdr
        let oldStyle = model.style
        let oldPortrait = model.portraitModeEnabled
        let oldCallback = camera.onCaptureCompleted
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        let oldLensID = camera.selectedLens
        let oldZoom = camera.currentZoom
        let originalPendingSaveCount = model.library.pendingSaveCount
        UIApplication.shared.isIdleTimerDisabled = true

        defer {
            camera.onCaptureCompleted = oldCallback
            if model.portraitModeEnabled != oldPortrait { model.togglePortraitMode() }
            model.hdr = false
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.style = oldStyle
            model.setMode(oldMode)
            if model.captureKind != oldKind { model.setCaptureKind(oldKind) }
            model.hdr = oldHDR
            camera.setPortraitCaptureEnabled(oldPortrait)
            if let lens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(lens)
                camera.setContinuousZoom(oldZoom)
            }
            model.setCameraActive(false)
            Task { @MainActor in model.setCameraActive(oldReady) }
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }

        model.setCaptureKind(.photo)
        model.setMode(.auto)
        model.hdr = false
        model.photoFormat = .heif
        model.photoResolution = .standard
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera did not become ready")
        guard let mainLens = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }) else {
            throw XCTSkip("No rear 1× camera route is available")
        }
        if camera.selectedLens != mainLens.id || abs(camera.currentZoom - 1) > 0.02 { camera.selectLens(mainLens) }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<200 {
            if camera.ready && camera.selectedLens == mainLens.id { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(camera.supportsPortraitCapture, "Current 1× route must support application portrait capture")
        print("PORTRAIT-CAPTURE capabilities route=rear-1x mode=A supports48MP=\(camera.availableResolutions.contains(.high)) supportsHEIFHDR=\(camera.supportsHEIFHDR) supportsProRAW=\(camera.supportsProRAW)")

        camera.photoPhaseTracingForTesting = true
        defer { camera.photoPhaseTracingForTesting = false }
        camera.setPortraitCaptureEnabled(true)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }

        func capture(_ options: PhotoOptions, name: String) async throws -> (CapturedPhoto, TimeInterval) {
            let originalCallback = camera.onOriginalProcessedPhotoForTesting
            camera.onOriginalProcessedPhotoForTesting = { data in
                print("PORTRAIT-NATIVE name=\(name) bytes=\(data.count)")
            }
            defer { camera.onOriginalProcessedPhotoForTesting = originalCallback }
            var requestedDimensions: CMVideoDimensions?
            let dimensionsCallback = camera.onPhotoRequestDimensionsForTesting
            camera.onPhotoRequestDimensionsForTesting = { requestedDimensions = $0 }
            defer { camera.onPhotoRequestDimensionsForTesting = dimensionsCallback }
            let completed = expectation(description: "Portrait capture: \(name)")
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; completed.fulfill() }
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 {
                if camera.ready && !camera.shutterBusy && camera.canCapture() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertFalse(camera.shutterBusy)
            XCTAssertTrue(camera.canCapture())
            let actualRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
            print("PORTRAIT-ROUTE name=\(name) macro=\(camera.macroActive) \(actualRoute)")
            let start = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: options)
            print("PORTRAIT-ACCEPTED name=\(name) pending=\(camera.pendingPhotoCount) busy=\(camera.shutterBusy)")
            await fulfillment(of: [completed], timeout: 55)
            let elapsed = CACurrentMediaTime() - start
            let photo = try XCTUnwrap(result, camera.message ?? "Portrait capture failed: \(name)")
            XCTAssertFalse(photo.resources.isEmpty)
            if options.resolution == .high {
                let requested = try XCTUnwrap(requestedDimensions)
                XCTAssertGreaterThanOrEqual(Int64(requested.width) * Int64(requested.height), 40_000_000,
                    "高像素必须实际请求当前格式的 48MP 上限，而不只是修改 UI")
                print("PORTRAIT-REQUEST name=\(name) max=\(requested.width)x\(requested.height) native=\(photo.diagnostics?.rows.filter { $0.title.contains("输出") } ?? [])")
            }
            XCTAssertEqual(model.library.pendingSaveCount, originalPendingSaveCount, "Diagnostic captures must not be saved to Photos")
            for _ in 0..<250 {
                if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse(camera.shutterBusy)
            return (photo, elapsed)
        }

        model.photoFormat = .heif
        model.photoResolution = .standard
        model.hdr = false
        var highOptions = PhotoOptions()
        highOptions.format = .heif
        highOptions.resolution = .standard
        highOptions.portraitMode = true
        let (highPhoto, highTime) = try await capture(highOptions, name: "HEIF 12MP portrait matte")
        let highData = try XCTUnwrap(highPhoto.resources.first?.data)
        let highSource = try XCTUnwrap(CGImageSourceCreateWithData(highData as CFData, nil))
        let highProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(highSource, 0, nil) as? [CFString: Any])
        let highWidth = try XCTUnwrap(highProperties[kCGImagePropertyPixelWidth] as? Int)
        let highHeight = try XCTUnwrap(highProperties[kCGImagePropertyPixelHeight] as? Int)
        let savedExif = try XCTUnwrap(highProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertNotNil(savedExif[kCGImagePropertyExifExposureTime])
        XCTAssertNotNil(savedExif[kCGImagePropertyExifISOSpeedRatings])
        XCTAssertNotNil(savedExif[kCGImagePropertyExifFocalLength])
        XCTAssertGreaterThanOrEqual(highWidth * highHeight, 10_000_000,
                                    "Standard resolution must produce a full-resolution file")

        let highMatteStatus = highPhoto.diagnostics?.rows.first { $0.title == "人像背景效果" }?.value ?? "missing"
        print("PORTRAIT-CAPTURE case=HEIF-12MP dimensions=\(highWidth)x\(highHeight) matte=\(highMatteStatus) callback-seconds=\(highTime)")

        model.photoFormat = .heif
        model.setMode(.manual)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<200 {
            if camera.ready && camera.selectedLens == mainLens.id { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let supports48MP = camera.availableResolutions.contains(.high)
        let testResolution: PhotoResolution = supports48MP ? .high : .standard
        model.photoResolution = testResolution
        print("PORTRAIT-CAPTURE capabilities route=rear-1x mode=M supports48MP=\(supports48MP) supportsProRAW=\(camera.supportsProRAW)")

        if supports48MP {
            camera.setPortraitCaptureEnabled(false)
            await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
            var controlOptions = PhotoOptions()
            controlOptions.format = .heif
            controlOptions.resolution = .high
            let (controlPhoto, controlTime) = try await capture(controlOptions, name: "HEIF 48MP control without portrait")
            let controlData = try XCTUnwrap(controlPhoto.resources.first?.data)
            let controlSource = try XCTUnwrap(CGImageSourceCreateWithData(controlData as CFData, nil))
            let controlProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(controlSource, 0, nil) as? [CFString: Any])
            let controlWidth = try XCTUnwrap(controlProperties[kCGImagePropertyPixelWidth] as? Int)
            let controlHeight = try XCTUnwrap(controlProperties[kCGImagePropertyPixelHeight] as? Int)
            let controlPixels = controlWidth * controlHeight
            XCTAssertGreaterThanOrEqual(controlPixels, 10_000_000) // maxPhotoDimensions 是上限，系统允许交付更小尺寸。
            print("PORTRAIT-CAPTURE case=HEIF-48MP-control dimensions=\(controlWidth)x\(controlHeight) pixels=\(controlPixels) callback-seconds=\(controlTime)")

            camera.setPortraitCaptureEnabled(true)
            await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
            var heifTimes: [TimeInterval] = []
            for index in 1...3 {
                var portrait48Options = PhotoOptions()
                portrait48Options.format = .heif
                portrait48Options.resolution = .high
                portrait48Options.portraitMode = true
                let (portrait48Photo, portrait48Time) = try await capture(portrait48Options, name: "HEIF 48MP portrait matte #\(index)")
                let portrait48Data = try XCTUnwrap(portrait48Photo.resources.first?.data)
                let portrait48Source = try XCTUnwrap(CGImageSourceCreateWithData(portrait48Data as CFData, nil))
                let portrait48Properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(portrait48Source, 0, nil) as? [CFString: Any])
                let portrait48Width = try XCTUnwrap(portrait48Properties[kCGImagePropertyPixelWidth] as? Int)
                let portrait48Height = try XCTUnwrap(portrait48Properties[kCGImagePropertyPixelHeight] as? Int)
                let native = try XCTUnwrap(portrait48Photo.diagnostics?.rows.first { $0.title == "系统照片输出" }?.value)
                let dimensions = native.split(separator: "×").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                XCTAssertEqual(dimensions.count, 2)
                if dimensions.count == 2 {
                    let expectedPixels = min(48_000_000, dimensions[0] * dimensions[1])
                    XCTAssertEqual(Double(portrait48Width * portrait48Height), Double(expectedPixels), accuracy: Double(expectedPixels) * 0.01,
                        "App 编码必须保留系统实际交付的分辨率")
                }
                let matte = portrait48Photo.diagnostics?.rows.first { $0.title == "人像背景效果" }?.value ?? "missing"
                if index == 1 {
                    print("PORTRAIT-CAPTURE case=HEIF-48MP dimensions=\(portrait48Width)x\(portrait48Height) matte=\(matte)")
                }
                heifTimes.append(portrait48Time)
            }
            let sortedHEIFTimes = heifTimes.sorted()
            print("PORTRAIT-STABILITY case=HEIF-48MP samples=\(heifTimes.count) callback-p50=\(sortedHEIFTimes[sortedHEIFTimes.count / 2])s max=\(sortedHEIFTimes.last ?? 0)s")
        }

        if camera.supportsProRAW && camera.availablePhotoFormats.contains(.raw) {
            model.hdr = false
            model.photoFormat = .raw
            model.photoResolution = testResolution
            var rawOptions = PhotoOptions()
            rawOptions.format = .raw
            rawOptions.resolution = testResolution
            rawOptions.portraitMode = true
            var rawTimes: [TimeInterval] = []
            for index in 1...3 {
                let (rawPhoto, rawTime) = try await capture(rawOptions, name: "ProRAW portrait matte #\(index)")
                let rawData = try XCTUnwrap(rawPhoto.resources.first?.data)
                XCTAssertTrue(rawPhoto.resources.first?.filename.hasSuffix(".dng") == true)
                let rawSource = try XCTUnwrap(CGImageSourceCreateWithData(rawData as CFData, nil))
                let rawProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(rawSource, 0, nil) as? [CFString: Any])
                let rawWidth = rawProperties[kCGImagePropertyPixelWidth] as? Int ?? 0
                let rawHeight = rawProperties[kCGImagePropertyPixelHeight] as? Int ?? 0
                XCTAssertGreaterThanOrEqual(rawWidth * rawHeight, 10_000_000)
                XCTAssertLessThanOrEqual(rawWidth * rawHeight, 50_000_000) // 原始 DNG 不重采样，保留系统真实输出。
                let embeddedMatte = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                    rawSource, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte
                ) != nil
                let decodedMatte = PortraitPhotoRenderer.matteImage(fromProRAW: rawData) != nil
                let rawMatteStatus = rawPhoto.diagnostics?.rows.first { $0.title == "人像背景效果" }?.value ?? "missing"
                if index == 1 {
                    print("PORTRAIT-CAPTURE case=ProRAW-\(testResolution.rawValue)MP dimensions=\(rawWidth)x\(rawHeight) embeddedMatte=\(embeddedMatte) decodedMatte=\(decodedMatte) reported=\(rawMatteStatus)")
                }
                rawTimes.append(rawTime)
            }
            let sortedRAWTImes = rawTimes.sorted()
            print("PORTRAIT-STABILITY case=ProRAW-\(testResolution.rawValue)MP samples=\(rawTimes.count) callback-p50=\(sortedRAWTImes[sortedRAWTImes.count / 2])s max=\(sortedRAWTImes.last ?? 0)s")
        } else {
            print("PORTRAIT-CAPTURE case=ProRAW-48MP skipped supportsProRAW=\(camera.supportsProRAW)")
        }
    }
    #endif
}
