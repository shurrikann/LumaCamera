import XCTest
import AVFoundation
import ImageIO
import Photos
@testable import LumaCamera

final class FrontWideSelectionTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 动态画幅设置只接受已经运行的前置输入；在后置上提前调用会被正常忽略。
    /// 先确认前置就绪，再关闭横幅并等到对应预览，防止沿用上一用例的横幅状态。
    @MainActor private func preparePortraitPhotoAspect(_ camera: CameraEngine) async throws {
        guard camera.frontPhotoAspectRatioSwitchAvailable else { return }
        let began = CACurrentMediaTime()
        camera.setFrontPhotoLandscapeEnabled(false)
        var applied = true
        for _ in 0..<250 {
            applied = await withCheckedContinuation { c in
                camera.frontPhotoLandscapeAppliedForTesting { c.resume(returning: $0) }
            }
            if !applied && !camera.frontPhotoLandscapeEnabled,
               let preview = camera.preview, preview.size.height > preview.size.width { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(applied, "拍摄前必须确认实际动态画幅已恢复竖幅")
        XCTAssertFalse(camera.frontPhotoLandscapeEnabled)
        let size = try XCTUnwrap(camera.preview?.size)
        XCTAssertGreaterThan(size.height, size.width)
        print("FRONT-PORTRAIT-PREP seconds=\(CACurrentMediaTime() - began) actualApplied=\(applied) preview=\(size)")
    }
    #endif
    func testOrientationChoosesWideFramingOnlyInLandscape() {
        XCTAssertEqual(FrontCameraFramingPolicy.target(isLandscape: true), .wide)
        XCTAssertEqual(FrontCameraFramingPolicy.target(isLandscape: false), .standard)
    }

    func testFrontWideArrowSymbolsExist() {
        XCTAssertNotNil(UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        XCTAssertNotNil(UIImage(systemName: "arrow.down.right.and.arrow.up.left"))
        XCTAssertNotNil(UIImage(systemName: "rectangle.portrait"))
        XCTAssertNotNil(UIImage(systemName: "rectangle"))
    }

    @MainActor func testCurrentOrientationFramingAndRecordingGuard() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Front camera framing needs a physical camera")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        let orientation = UIDevice.current.orientation
        guard orientation.isPortrait || orientation.isLandscape else {
            throw XCTSkip("Hold the device upright in portrait or landscape for this physical orientation check")
        }
        model.setCameraActive(true)
        for _ in 0..<250 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // 前一个测试可能留下同方向下的手动取景覆盖；真实前后往返重置方向入口，
        // 避免把“同方向不覆盖用户选择”的既有规则误报成方向切换失败。
        if model.currentPosition == .front {
            model.flipCamera()
            for _ in 0..<300 {
                if camera.ready && model.currentPosition == .back { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        if model.currentPosition != .front { model.flipCamera() }
        for _ in 0..<300 {
            if camera.ready && model.currentPosition == .front && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let front = camera.lenses.filter { $0.device.position == .front }
        guard let standard = front.first(where: { $0.frontFraming == .standard }),
              let wide = front.first(where: { $0.frontFraming == .wide }) else {
            throw XCTSkip("This device does not expose separate front framing choices")
        }
        // 会话启动/翻转期间姿态可能变化；按前置就绪后的实际姿态测试，不能沿用启动前快照。
        let readyOrientation = UIDevice.current.orientation
        guard readyOrientation.isPortrait || readyOrientation.isLandscape else {
            throw XCTSkip("前置就绪时设备非竖直姿态，不将平放状态算作方向失败")
        }
        let isLandscape = readyOrientation.isLandscape
        print("FRONT-ORIENTATION initial=\(orientation.rawValue) ready=\(readyOrientation.rawValue)")
        model.updateFrontFramingForOrientation(isLandscape: isLandscape)
        let expected = isLandscape ? wide : standard
        for _ in 0..<150 {
            if camera.ready && camera.selectedLens == expected.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(camera.selectedLens, expected.id, "Front framing should match the device's current orientation")

        // A manual front-framing choice stays put until the physical orientation changes.
        let manualOverride = isLandscape ? standard : wide
        model.selectFocalLength(manualOverride)
        for _ in 0..<150 {
            if camera.ready && camera.selectedLens == manualOverride.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(camera.selectedLens, manualOverride.id, "A ready callback must not undo a manual framing choice")

        camera.setVideoRecordingForTesting(true)
        model.updateFrontFramingForOrientation(isLandscape: !isLandscape)
        XCTAssertEqual(camera.selectedLens, manualOverride.id, "Orientation changes must not reframe while recording")
        camera.setVideoRecordingForTesting(false)
        model.updateFrontFramingForOrientation(isLandscape: isLandscape)
        XCTAssertEqual(camera.selectedLens, manualOverride.id, "Stopping recording must retain framing when orientation did not change")

        for _ in 0..<5 {
            model.updateFrontFramingForOrientation(isLandscape: isLandscape)
            for _ in 0..<150 {
                if camera.ready && camera.selectedLens == manualOverride.id { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(camera.selectedLens, manualOverride.id, "Repeated ready callbacks must not override a manual framing choice")
        }
        #endif
    }

    @MainActor func testFrontPhotoAspectToggleAndWideRegression() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Center Stage needs a physical front camera")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<200 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if model.currentPosition != .front { model.flipCamera() }
        for _ in 0..<250 {
            if camera.ready && model.currentPosition == .front && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let front = camera.lenses.filter { $0.device.position == .front }
        guard camera.frontPhotoAspectRatioSwitchAvailable else { throw XCTSkip("The active front photo format does not support portrait and landscape dynamic aspect ratios") }
        for index in 0..<8 {
            let expected = !camera.frontPhotoLandscapeEnabled
            let started = CACurrentMediaTime()
            model.toggleFrontPhotoAspectRatio()
            for _ in 0..<200 {
                if camera.frontPhotoLandscapeEnabled == expected, camera.preview != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(camera.frontPhotoLandscapeEnabled, expected)
            XCTAssertTrue(camera.ready)
            XCTAssertNotNil(camera.preview)
            XCTAssertNil(model.focalTransitionImage, "Aspect changes do not represent a physical lens switch")
            print("FRONT-PHOTO-ASPECT toggle=\(index) landscape=\(expected) completion-seconds=\(CACurrentMediaTime() - started)")
        }
        if let wide = front.first(where: { $0.frontFraming == .wide }),
           let standard = front.first(where: { $0.frontFraming == .standard }) {
            model.selectFocalLength(wide)
            for _ in 0..<150 { if camera.ready && camera.selectedLens == wide.id { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(camera.selectedLens, wide.id)
            XCTAssertTrue(camera.frontPhotoAspectRatioSwitchAvailable, "The aspect toggle must remain independent from front wide framing")
            model.selectFocalLength(standard)
            for _ in 0..<150 { if camera.ready && camera.selectedLens == standard.id { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(camera.selectedLens, standard.id)
        }
        #endif
    }

    @MainActor
    func testFrontWideSwitchDoesNotCrashAndTogglesBack() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Front ultra-wide selection is verified on a physical device")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 {
            if model.camera.ready, !model.camera.lenses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let front = model.camera.lenses.filter { $0.device.position == .front }
        guard let wide = front.first(where: { $0.frontFraming == .standard }),
              let ultra = front.first(where: { $0.frontFraming == .wide }) else {
            throw XCTSkip("This device has no front ultra-wide camera")
        }
        model.selectFocalLength(wide)
        for _ in 0..<60 {
            if model.camera.ready, model.camera.selectedLens == wide.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        model.selectFocalLength(ultra)
        for _ in 0..<80 {
            if model.camera.ready, model.camera.selectedLens == ultra.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.camera.selectedLens, ultra.id)
        XCTAssertEqual(model.camera.currentZoom, ultra.displayZoom, accuracy: 0.01)

        model.selectFocalLength(wide)
        for _ in 0..<80 {
            if model.camera.ready, model.camera.selectedLens == wide.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.camera.selectedLens, wide.id)
        XCTAssertEqual(model.camera.currentZoom, 1, accuracy: 0.01)
        #endif
    }
    @MainActor func testFrontBackFreshFrameLatencyAndRepeatedTaps() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical front and back cameras")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, format = model.photoFormat, hdr = model.hdr, live = model.livePhotoEnabled
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.photoFormat = format; model.hdr = hdr; if live && model.livePhotoAvailable && !model.livePhotoEnabled { model.toggleLivePhoto() }; model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setCameraActive(true); model.setMode(.auto)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        let initial = camera.lenses.first { $0.id == camera.selectedLens }
        let rearFormats = initial?.device.position == .back ? camera.availablePhotoFormats : nil
        let rearResolutions = initial?.device.position == .back ? camera.availableResolutions : nil
        let rearProRAW = camera.supportsProRAW
        for index in 0..<8 {
            let current = try XCTUnwrap(camera.lenses.first { $0.id == camera.selectedLens })
            let destination: AVCaptureDevice.Position = current.device.position == .front ? .back : .front
            let before = camera.preview, start = CACurrentMediaTime()
            model.flipCamera()
            // Busy presses must not enqueue replacements that undo the requested side.
            for _ in 0..<10 { model.flipCamera() }
            var fresh: Double?
            for _ in 0..<700 {
                let actual = camera.lenses.first { $0.id == camera.selectedLens }?.device.position
                if fresh == nil, actual == destination, camera.ready, camera.preview != nil, camera.preview !== before { fresh = CACurrentMediaTime()-start }
                if fresh != nil && model.focalTransitionImage == nil { break }
                try await Task.sleep(for:.milliseconds(5))
            }
            XCTAssertEqual(camera.lenses.first { $0.id == camera.selectedLens }?.device.position,destination)
            XCTAssertNotNil(fresh); XCTAssertNil(model.focalTransitionImage)
            if destination == .back, let rearFormats, let rearResolutions {
                XCTAssertEqual(camera.availablePhotoFormats,rearFormats,"Returning to the rear route must restore RAW/HEIF capabilities")
                XCTAssertEqual(camera.availableResolutions,rearResolutions)
                XCTAssertEqual(camera.supportsProRAW,rearProRAW)
            }
            XCTAssertLessThan(fresh ?? 5,1.5,"Reject the original multi-commit delay")
            print("FLIP-SPEED index=\(index) to=\(destination.rawValue) fresh=\(fresh ?? -1) visible=\(CACurrentMediaTime()-start)")
            try await Task.sleep(for:.milliseconds(120))
        }
        #endif
    }

    @MainActor func testFrontBackManualExposureAndCancellation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical camera routing")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, format = model.photoFormat, hdr = model.hdr
        let iso = model.iso, shutter = model.shutter, manual = model.manualExposure
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.photoFormat = format; model.hdr = hdr; model.iso = iso; model.shutter = shutter
            model.manualExposure = manual; model.setMode(mode); model.applyExposure()
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setCameraActive(true); model.setMode(.manual)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/125); model.applyExposure()
        for index in 0..<6 {
            model.flipCamera()
            for _ in 0..<300 { if camera.ready && camera.preview != nil && model.focalTransitionImage == nil { break }; try await Task.sleep(for:.milliseconds(10)) }
            let lens = try XCTUnwrap(camera.lenses.first { $0.id == camera.selectedLens })
            var actual: CameraEngine.ExposureColorState?
            for _ in 0..<150 {
                actual = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                if let actual, abs(actual.iso-400)<5 && abs(actual.seconds-1.0/125)<0.0005 { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertTrue(model.manualExposure)
            XCTAssertEqual(actual?.deviceID,lens.device.uniqueID)
            XCTAssertEqual(actual?.iso ?? 0,400,accuracy:5)
            XCTAssertEqual(actual?.seconds ?? 0,1.0/125,accuracy:0.0005)
            print("FLIP-MANUAL index=\(index) side=\(lens.device.position.rawValue) ISO=\(actual?.iso ?? -1)")
        }
        model.flipCamera(); model.setCameraActive(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true); await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertNotNil(camera.preview)
        #endif
    }

    @MainActor func testRepeatedFrontSwitchFreshPreviewLatency() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires front camera hardware")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true); model.setMode(.auto)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<200 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        let front = camera.lenses.filter { $0.device.position == .front }
        guard let wide = front.first(where: { $0.frontFraming == .standard }),
              let ultra = front.first(where: { $0.frontFraming == .wide }) else { throw XCTSkip("No front ultra-wide") }
        for (index, lens) in [wide, ultra, wide, ultra, wide, ultra, wide].enumerated() {
            let start = CACurrentMediaTime(), previous = camera.preview
            model.selectFocalLength(lens)
            var firstFrame: Double?
            for _ in 0..<500 {
                if firstFrame == nil, camera.ready, camera.selectedLens == lens.id, camera.preview != nil, camera.preview !== previous { firstFrame = CACurrentMediaTime()-start }
                if firstFrame != nil && model.focalTransitionImage == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(camera.selectedLens, lens.id); XCTAssertTrue(camera.ready); XCTAssertNotNil(camera.preview)
            XCTAssertNotNil(firstFrame); XCTAssertNil(model.focalTransitionImage)
            if index > 0 { XCTAssertLessThan(firstFrame ?? 5,1.5,"Warm front switches must not retain the old multi-commit delay") }
            print("FRONT-SPEED index=\(index) target=\(lens.device.deviceType.rawValue) fresh=\(firstFrame ?? -1) visible=\(CACurrentMediaTime()-start)")
            try await Task.sleep(for: .milliseconds(100))
        }
        #endif
    }

    @MainActor func testFrontSwitchManualExposureMirrorCaptureAndCancellation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real front photo output")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let mode = model.mode, iso = model.iso, shutter = model.shutter, manual = model.manualExposure
        let preferences = model.preferences, callback = camera.onCaptureCompleted, ratio = model.ratio, style = model.style
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = callback; model.preferences = preferences; model.ratio = ratio; model.style = style
            model.iso = iso; model.shutter = shutter; model.manualExposure = manual
            model.setMode(mode); model.applyExposure(); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true); model.setMode(.manual); model.ratio = .standard; model.style = .original
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        let front = camera.lenses.filter { $0.device.position == .front }
        guard let wide = front.first(where: { $0.frontFraming == .standard }),
              let ultra = front.first(where: { $0.frontFraming == .wide }) else { throw XCTSkip("No front ultra-wide") }
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/125); model.applyExposure()
        for (index,lens) in [wide,ultra,wide,ultra].enumerated() {
            model.selectFocalLength(lens)
            // Repeated taps while busy must not queue stale route replacements.
            for _ in 0..<10 { model.selectFocalLength(lens) }
            for _ in 0..<300 {
                if camera.ready && camera.selectedLens == lens.id && camera.preview != nil && model.focalTransitionImage == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await preparePortraitPhotoAspect(camera)
            var actual: CameraEngine.ExposureColorState?
            for _ in 0..<150 {
                actual = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                if let actual, abs(actual.iso-400) < 5 && abs(actual.seconds-1.0/125)<0.0005 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(actual?.deviceID,lens.device.uniqueID)
            XCTAssertEqual(actual?.physicalZoomFactor ?? 0,lens.zoomFactor,accuracy:0.001)
            XCTAssertEqual(actual?.iso ?? 0,400,accuracy:5)
            XCTAssertEqual(actual?.seconds ?? 0,1.0/125,accuracy:0.0005)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let mirrored = await withCheckedContinuation { c in camera.photoMirroringForTesting { c.resume(returning:$0) } }
            XCTAssertEqual(mirrored, true, "Front photos are always mirrored")
            if index >= 2 {
                let done = expectation(description:"Temporary front photo")
                var output:CapturedPhoto?
                camera.onCaptureCompleted = { output=$0; done.fulfill() }
                camera.capture(flashMode:.off,options:PhotoOptions(format:.jpeg))
                await fulfillment(of:[done],timeout:30)
                let photo=try XCTUnwrap(output,camera.message ?? "Front capture failed")
                let resource=try XCTUnwrap(photo.resources.first)
                let source=try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
                let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
                print("FRONT-CAPTURE index=\(index) target=\(lens.device.deviceType.rawValue) file=\(image.width)x\(image.height) preview=\(photo.preview.size)")
                XCTAssertGreaterThan(image.width*image.height,11_000_000,"Portrait source must not be sideways-cropped down to the old 6.75MP output")
                let angle = await withCheckedContinuation { c in camera.frontPhotoCaptureRotationForTesting { c.resume(returning: $0) } }
                let landscape = CaptureOrientation.frontPhotoLandscape(sensorLandscape: false, captureAngle: angle)
                XCTAssertEqual(photo.preview.size.width > photo.preview.size.height, landscape)
                print("FRONT-CAPTURE-ROTATION angle=\(angle) finalLandscape=\(landscape)")
                camera.onCaptureCompleted=nil
            }
        }
        // Stop cancels the lifecycle while the input is being replaced, then recover.
        model.selectFocalLength(wide); model.setCameraActive(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertNotNil(camera.preview)
        #endif
    }

    @MainActor func testFrontPhotoFilesKeepUprightPixelsAndSystemFocalLengths() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real front photo metadata")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback=camera.onCaptureCompleted, originalCallback=camera.onOriginalProcessedPhotoForTesting
        let mode=model.mode, ratio=model.ratio, preferences=model.preferences
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { camera.onCaptureCompleted=callback;camera.onOriginalProcessedPhotoForTesting=originalCallback;model.preferences=preferences;model.ratio=ratio;model.setMode(mode);model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle }
        model.setCameraActive(true);model.setMode(.auto);model.ratio = .standard
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<200 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(30)) }
        let front=camera.lenses.filter { $0.frontFraming != nil }
        XCTAssertEqual(front.count,2)
        XCTAssertEqual(Set(front.map { $0.device.uniqueID }).count,1,"Both framings must use one system input")
        for format in [PhotoFileFormat.jpeg,.heif] {
            for lens in front {
                model.selectFocalLength(lens)
                for _ in 0..<300 { if camera.ready && camera.selectedLens == lens.id && camera.preview != nil && model.focalTransitionImage == nil { break };try await Task.sleep(for:.milliseconds(10)) }
                if format == .jpeg, lens.id == front.first?.id, camera.frontPhotoAspectRatioSwitchAvailable {
                    // 主动留下横幅，复现前一用例的状态；必须真正恢复竖幅后再验原片方向。
                    camera.setFrontPhotoLandscapeEnabled(true)
                    for _ in 0..<250 {
                        if camera.frontPhotoLandscapeEnabled { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertTrue(camera.frontPhotoLandscapeEnabled)
                }
                try await preparePortraitPhotoAspect(camera)
                let expected = lens.frontFraming == .standard ? (30...31) : (20...20)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                var sensorData:Data?
                camera.onOriginalProcessedPhotoForTesting={ sensorData=$0 }
                let done=expectation(description:"Front file metadata");var result:CapturedPhoto?
                camera.onCaptureCompleted={ result=$0;done.fulfill() }
                let preview=try XCTUnwrap(camera.preview)
                camera.capture(flashMode:.off,options:PhotoOptions(format:format))
                await fulfillment(of:[done],timeout:30)
                let nativeData=try XCTUnwrap(sensorData)
                let decoded=try XCTUnwrap(CIImage(data:nativeData,options:[.applyOrientationProperty:true]))
                let angle = await withCheckedContinuation { c in camera.frontPhotoCaptureRotationForTesting { c.resume(returning: $0) } }
                let landscape = CaptureOrientation.frontPhotoLandscape(sensorLandscape: false, captureAngle: angle)
                // 系统已按重力方向写 EXIF；横拿时应是摆正的横图，不能强制断言所有原片都是竖图。
                XCTAssertEqual(decoded.extent.width > decoded.extent.height, landscape)
                let nativeSource=try XCTUnwrap(CGImageSourceCreateWithData(nativeData as CFData,nil))
                let native=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(nativeSource,0,nil) as? [CFString:Any])
                let nativeEXIF=try XCTUnwrap(native[kCGImagePropertyExifDictionary] as? [CFString:Any])
                let nativeFocal = try XCTUnwrap((nativeEXIF[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue)
                XCTAssertTrue(expected.contains(nativeFocal), "系统实际等效焦距应符合宽窄取景；保留其 30/31mm 取整")
                let photo=try XCTUnwrap(result,camera.message ?? "No front photo")
                let resource=try XCTUnwrap(photo.resources.first)
                let file=try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
                let metadata=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file,0,nil) as? [CFString:Any])
                let exif=try XCTUnwrap(metadata[kCGImagePropertyExifDictionary] as? [CFString:Any])
                XCTAssertEqual((exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue,nativeFocal,"最终文件必须保留原始 EXIF 焦距")
                XCTAssertEqual((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,1)
                if let tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let direction = tiff[kCGImagePropertyTIFFOrientation] as? NSNumber {
                    XCTAssertEqual(direction.intValue, 1, "TIFF 不得要求对已摆正的像素再次旋转")
                }
                let displayed=try XCTUnwrap(CIImage(data:resource.data,options:[.applyOrientationProperty:true]))
                XCTAssertEqual(displayed.extent.width > displayed.extent.height, landscape)
                XCTAssertGreaterThan(displayed.extent.width*displayed.extent.height,11_000_000)
                print("FRONT-FILE format=\(format) framing=\(String(describing:lens.frontFraming)) rotation=\(angle) original=\(decoded.extent) saved=\(displayed.extent) nativeEXIF=\(nativeFocal) fileEXIF=\((exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue ?? -1)")
                for (name,image) in [("preview",preview),("file",try XCTUnwrap(UIImage(data:resource.data)))] {
                    let a=XCTAttachment(image:image);a.name="\(format)-\(expected)mm-\(name)";a.lifetime = .keepAlways;add(a)
                }
            }
        }
        #endif
    }
    @MainActor func testFrontLiveFramingsRetainPairingAndFileMetadata() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires native Live camera output")
        #else
        let model=try XCTUnwrap(AppDependencies.runningAppCameraModel),camera=model.camera
        let callback=camera.onCaptureCompleted, originalCallback=camera.onOriginalProcessedPhotoForTesting
        let mode=model.mode, oldLive=model.livePhotoEnabled
        let format=model.photoFormat, hdr=model.hdr, resolution=model.photoResolution
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer {
            camera.onCaptureCompleted=callback;camera.onOriginalProcessedPhotoForTesting=originalCallback
            if model.livePhotoEnabled != oldLive { model.toggleLivePhoto() }
            model.photoFormat=format;model.hdr=hdr;model.photoResolution=resolution;model.setMode(mode)
            model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle
        }
        model.photoFormat = .jpeg;model.hdr=false;model.photoResolution = .standard
        model.setCameraActive(true);model.setMode(.auto)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<200 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(30)) }
        if model.currentPosition != .front { model.flipCamera() }
        for _ in 0..<200 {
            if camera.ready && camera.preview != nil && model.currentPosition == .front { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        let front=camera.lenses.filter { $0.frontFraming != nil };XCTAssertEqual(front.count,2)
        for lens in front {
            for _ in 0..<200 {
                if camera.ready && !camera.capturing && !camera.videoBusy && camera.preview != nil && model.currentPosition == .front { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            model.selectFocalLength(lens)
            var zoomBeforeLive: CGFloat = -1
            for _ in 0..<200 {
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                zoomBeforeLive = state?.physicalZoomFactor ?? -1
                if camera.ready && camera.selectedLens == lens.id && camera.preview != nil && abs(zoomBeforeLive - lens.zoomFactor) < 0.02 { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            print("FRONT-LIVE-BEFORE framing=\(String(describing:lens.frontFraming)) deviceZoom=\(zoomBeforeLive) selected=\(camera.selectedLens == lens.id)")
            XCTAssertEqual(zoomBeforeLive,lens.zoomFactor,accuracy:0.02,"The requested front framing must reach the camera before enabling Live")
            if !model.livePhotoEnabled { model.toggleLivePhoto() }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for:.seconds(3))
            XCTAssertTrue(camera.supportsLivePhoto)
            let exposureState = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            print("FRONT-LIVE-DEVICE framing=\(String(describing:lens.frontFraming)) device=\(exposureState?.deviceID ?? "none") zoom=\(exposureState?.physicalZoomFactor ?? 0) selected=\(camera.selectedLens == lens.id)")
            XCTAssertEqual(exposureState?.deviceID,lens.device.uniqueID)
            XCTAssertEqual(exposureState?.physicalZoomFactor ?? 0,zoomBeforeLive,accuracy:0.02,"Live setup must preserve the front framing that was active before the toggle")
            let done=expectation(description:"Front native Live");var result:CapturedPhoto?
            var sensorData:Data?
            camera.onOriginalProcessedPhotoForTesting={ sensorData=$0 }
            camera.onCaptureCompleted={ result=$0;done.fulfill() }
            camera.capture(flashMode:.off,options:PhotoOptions(format:.jpeg,live:true))
            await fulfillment(of:[done],timeout:35)
            let photo=try XCTUnwrap(result,camera.message ?? "No front Live")
            XCTAssertEqual(photo.resources.filter(\.pairedVideo).count,1)
            let still=try XCTUnwrap(photo.resources.first { !$0.pairedVideo })
            let source=try XCTUnwrap(CGImageSourceCreateWithData(still.data as CFData,nil))
            let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            let exif=try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString:Any])
            let savedFocal=(exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
            let originalSource=try XCTUnwrap(CGImageSourceCreateWithData(XCTUnwrap(sensorData) as CFData,nil))
            let originalProperties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource,0,nil) as? [CFString:Any])
            let originalEXIF=try XCTUnwrap(originalProperties[kCGImagePropertyExifDictionary] as? [CFString:Any])
            let nativeFocal=(originalEXIF[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
            let nativeImage=try XCTUnwrap(CIImage(data:XCTUnwrap(sensorData),options:[.applyOrientationProperty:true]))
            let savedImage=try XCTUnwrap(CIImage(data:still.data,options:[.applyOrientationProperty:true]))
            print("FRONT-LIVE-FOCAL framing=\(String(describing:lens.frontFraming)) native=\(String(describing:nativeFocal)) saved=\(String(describing:savedFocal)) zoom=\(lens.zoomFactor) nativePixels=\(nativeImage.extent) savedPixels=\(savedImage.extent)")
            XCTAssertEqual(savedFocal,nativeFocal,"The final Live still must preserve the system-reported focal length")
            if lens.frontFraming == .standard {
                XCTAssertTrue((30...31).contains(savedFocal ?? -1),"Live photo stream may round the narrow framing to 30 or 31 mm")
            } else {
                XCTAssertEqual(savedFocal,20)
            }
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let urls=try photo.resources.map { resource -> URL in
                let url=directory.appendingPathComponent(resource.filename);try resource.data.write(to:url);return url
            }
            let accepted=expectation(description:"System recognizes front Live")
            var decoded:PHLivePhoto?
            let request=PHLivePhoto.request(withResourceFileURLs:urls,placeholderImage:nil,targetSize:CGSize(width:300,height:400),contentMode:.aspectFit) { live,info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                decoded=live;accepted.fulfill()
            }
            await fulfillment(of:[accepted],timeout:20);PHLivePhoto.cancelRequest(withRequestID:request)
            XCTAssertNotNil(decoded)
            print("FRONT-LIVE framing=\(String(describing:lens.frontFraming)) paired=\(decoded != nil)")
            model.setCameraActive(false)
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.setCameraActive(true)
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 { if camera.ready && camera.preview != nil && model.currentPosition == .front { break }; try await Task.sleep(for:.milliseconds(30)) }
            let running=await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
            print("FRONT-LIVE-RESUME ready=\(camera.ready) running=\(running) recoveryFailed=\(camera.recoveryFailed) message=\(camera.message ?? "none")")
            XCTAssertTrue(camera.ready);XCTAssertTrue(running)
        }
        #endif
    }

}
