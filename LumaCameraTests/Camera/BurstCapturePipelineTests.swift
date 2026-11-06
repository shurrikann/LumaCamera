import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class BurstCapturePipelineTests: XCTestCase {
    @MainActor func testQueuedSavesRetainEveryShotAndOnlyLatestUpdatesCurrentIdentity() {
        let service = BurstPhotoService()
        let library = PhotoLibraryViewModel(service: service)
        let shots = (0..<3).map { index in
            CapturedPhoto(preview: UIImage(), resources: [PhotoResource(data: Data([UInt8(index)]), filename: "shot-\(index).dng")])
        }
        shots.forEach { library.acceptCapture($0, automaticallySave: true) }
        XCTAssertEqual(library.pendingSaveCount, 3)
        XCTAssertEqual(service.saved.count, 1)
        XCTAssertTrue(library.lastPhoto === shots[2].preview)
        service.finish(.failure(PhotoLibraryError.writeDenied))
        XCTAssertEqual(library.pendingSaveCount, 2)
        XCTAssertEqual(library.failedSaveCount, 1)
        service.finish(.success("second"))
        XCTAssertFalse(library.photoSaved)
        XCTAssertNil(library.savedPhotoID)
        service.finish(.success("latest"))
        XCTAssertEqual(library.pendingSaveCount, 0)
        XCTAssertEqual(library.savedPhotoID, "latest")
        library.retryFailedSaves()
        XCTAssertEqual(library.pendingSaveCount, 1)
        XCTAssertEqual(service.saved.last?.resources.first?.filename, "shot-0.dng")
        service.finish(.success("retried-first"))
        XCTAssertEqual(library.savedPhotoID, "latest")
        XCTAssertTrue(library.lastPhoto === shots[2].preview)
        XCTAssertEqual(library.failedSaveCount, 0)
        XCTAssertEqual(library.pendingSaveCount, 0)
        XCTAssertEqual(service.saved.prefix(3).compactMap { $0.resources.first?.filename }, ["shot-0.dng", "shot-1.dng", "shot-2.dng"])
    }

    #if targetEnvironment(simulator)
    @MainActor func testLiveShutterStaysBusyThroughProcessingAndRejectsRepeatedTaps() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: BurstPhotoService())
        let camera = model.camera
        camera.start()
        defer { camera.stop() }
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        let gate = DispatchSemaphore(value: 0)
        camera.enqueueProcessingBarrierForTesting(gate)
        defer { gate.signal() }
        let live = PhotoOptions(format: .jpeg, live: true)
        camera.capture(flashMode: .off, options: live)
        for _ in 0..<100 { if !camera.capturing { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(camera.capturing, "Still hardware can finish while Live processing remains pending")
        XCTAssertTrue(camera.shutterBusy)
        XCTAssertEqual(camera.pendingPhotoCount, 1)
        for _ in 0..<30 { camera.capture(flashMode: .off, options: live); camera.capture(flash: false) }
        XCTAssertEqual(camera.pendingPhotoCount, 1, "Live must lock both Live and ordinary shutter paths until completion")
        gate.signal()
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(camera.shutterBusy)
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        camera.capture(flash: false)
        XCTAssertEqual(camera.pendingPhotoCount, 1, "Shutter must recover after Live completion")
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(camera.shutterBusy)
    }
    @MainActor func testConsecutiveShuttersContinueWhileProcessingAndSavesArePending() async throws {
        let service = BurstPhotoService()
        let model = AppDependencies.makeCameraModel(photoService: service)
        let camera = model.camera
        camera.start()
        defer { camera.stop() }
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        let gate = DispatchSemaphore(value: 0)
        camera.enqueueProcessingBarrierForTesting(gate)
        defer { gate.signal() }
        for count in 1...4 {
            camera.capture(flash: false)
            for _ in 0..<100 { if !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(camera.shutterBusy)
            XCTAssertEqual(camera.pendingPhotoCount, count)
        }
        camera.capture(flash: false)
        XCTAssertEqual(camera.pendingPhotoCount, 4, "Full queue must apply bounded back pressure")
        XCTAssertEqual(service.saved.count, 0)
        gate.signal()
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        XCTAssertEqual(model.library.pendingSaveCount, 4)
        XCTAssertEqual(service.saved.count, 1)
        for index in 0..<4 {
            service.finish(.success("asset-\(index)"))
            XCTAssertEqual(model.library.pendingSaveCount, 3 - index)
        }
        XCTAssertEqual(Set(service.saved.compactMap { $0.resources.first?.filename }).count, 4)
        XCTAssertEqual(model.library.savedPhotoID, "asset-3")
        XCTAssertTrue(model.library.canAcceptNewCapture)
    }
    @MainActor func testHoldingBurstShutterQueuesShotsAndReleaseStopsFurtherRequests() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: BurstPhotoService())
        let camera = model.camera
        let priorCaptureCallback = camera.onCaptureCompleted
        var completionTimes: [TimeInterval] = []
        camera.onCaptureCompleted = { photo in
            if photo != nil { completionTimes.append(ProcessInfo.processInfo.systemUptime) }
            priorCaptureCallback?(photo)
        }
        camera.start()
        defer {
            model.stopBurstCapture()
            camera.onCaptureCompleted = priorCaptureCallback
            camera.stop()
        }
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        guard model.burstUnavailableReason == nil else { throw XCTSkip("Simulator route does not expose a supported 12MP JPG/HEIF configuration") }
        model.toggleBurstMode()
        XCTAssertTrue(model.burstModeEnabled)
        model.startBurstCapture()
        XCTAssertTrue(model.burstCaptureActive)

        let measurementStart = ProcessInfo.processInfo.systemUptime
        var peakPending = 0
        while ProcessInfo.processInfo.systemUptime - measurementStart < 0.9 {
            peakPending = max(peakPending, camera.pendingPhotoCount)
            try await Task.sleep(for: .milliseconds(20))
        }
        model.stopBurstCapture()
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        let countAfterRelease = completionTimes.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(completionTimes.count, countAfterRelease, "Release must stop scheduling additional frames")
        XCTAssertGreaterThanOrEqual(countAfterRelease, 2, "A held burst shutter should produce separate photos")
        XCTAssertLessThanOrEqual(peakPending, 4, "The existing capture pipeline must apply bounded back pressure")
        let beforeRestartCount = model.burstCaptureCount
        let restartBefore = completionTimes.count
        model.startBurstCapture()
        try await Task.sleep(for: .milliseconds(900))
        model.stopBurstCapture()
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(model.burstCaptureCount, beforeRestartCount, "不退出连拍直接再次按住，计数应继续累计")
        XCTAssertGreaterThan(completionTimes.count, restartBefore)
        model.toggleBurstMode()
        XCTAssertFalse(model.burstModeEnabled)
        XCTAssertEqual(model.burstCaptureCount, 0, "退出连拍应归零")
        model.toggleBurstMode()
        XCTAssertTrue(model.burstModeEnabled)
        model.toggleBurstMode()
        let intervals = zip(completionTimes, completionTimes.dropFirst()).map { $1 - $0 }
        let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        print("BURST-SIM shots=\(countAfterRelease) hold=0.9s mean-callback-interval=\(meanInterval)s peak-pending=\(peakPending); simulator processing intervals do not represent device burst FPS")
    }
    #else
    @MainActor func testHeldBurstShutterOnDeviceStopsCleanlyWithoutSavingToPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let previousCallback = camera.onCaptureCompleted
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        let previousKind = model.captureKind
        let previousMode = model.mode
        let previousFormat = model.photoFormat
        let previousResolution = model.photoResolution
        let previousHDR = model.hdr
        let previousLive = model.livePhotoEnabled
        let previousTimer = model.timerSeconds
        var completionTimes: [TimeInterval] = []
        var peakPending = 0
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCaptureCompleted = { if $0 != nil { completionTimes.append(ProcessInfo.processInfo.systemUptime) } }
        defer {
            model.stopBurstCapture()
            if model.burstModeEnabled { model.toggleBurstMode() }
            camera.onCaptureCompleted = previousCallback
            if model.captureKind != previousKind { model.setCaptureKind(previousKind) }
            if model.mode != previousMode { model.setMode(previousMode) }
            model.photoFormat = previousFormat
            model.photoResolution = previousResolution
            if model.livePhotoEnabled != previousLive { model.toggleLivePhoto() }
            model.hdr = previousHDR
            model.timerSeconds = previousTimer
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        }

        camera.start()
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        model.cancelCountdown()
        if model.captureKind != .photo { model.setCaptureKind(.photo) }
        if model.mode != .auto { model.setMode(.auto) }
        model.photoFormat = .jpeg
        model.photoResolution = .standard
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.timerSeconds = 0
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(300))
        guard model.burstUnavailableReason == nil else {
            throw XCTSkip("Device route does not expose a supported 12MP JPG configuration")
        }

        model.toggleBurstMode()
        XCTAssertTrue(model.burstModeEnabled)
        for cycle in 0..<3 {
            let countBeforeHold = completionTimes.count
            model.startBurstCapture()
            XCTAssertTrue(model.burstCaptureActive)
            let holdStart = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - holdStart < 0.9 {
                peakPending = max(peakPending, camera.pendingPhotoCount)
                try await Task.sleep(for: .milliseconds(20))
            }
            model.stopBurstCapture()
            for _ in 0..<500 {
                if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse(camera.shutterBusy)
            let countAfterRelease = completionTimes.count
            XCTAssertGreaterThan(countAfterRelease, countBeforeHold, "Each held shutter interval should capture at least one frame")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(completionTimes.count, countAfterRelease, "Releasing the shutter must stop scheduling new frames")
            XCTAssertLessThanOrEqual(peakPending, 4, "Burst must respect the existing bounded capture queue")
            XCTAssertEqual(model.burstCaptureCount, completionTimes.count, "连拍张数应与成功交付张数一致")
            print("BURST-DEVICE cycle=\(cycle + 1) shots=\(countAfterRelease - countBeforeHold) total=\(model.burstCaptureCount) hold=0.9s peak-pending=\(peakPending)")
        }
        let beforeRestartCount = model.burstCaptureCount
        let restartBefore = completionTimes.count
        model.startBurstCapture()
        try await Task.sleep(for: .milliseconds(900))
        model.stopBurstCapture()
        for _ in 0..<500 { if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(model.burstCaptureCount, beforeRestartCount, "不退出连拍直接再次按住，计数应继续累计")
        XCTAssertGreaterThan(completionTimes.count, restartBefore)
        model.toggleBurstMode()
        XCTAssertFalse(model.burstModeEnabled)
        XCTAssertEqual(model.burstCaptureCount, 0, "退出连拍应归零")
        model.toggleBurstMode()
        XCTAssertTrue(model.burstModeEnabled)
        model.toggleBurstMode()
        let intervals = zip(completionTimes, completionTimes.dropFirst()).map { $1 - $0 }
        let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        print("BURST-DEVICE cycles=3 total-shots=\(completionTimes.count) mean-callback-interval=\(meanInterval)s peak-pending=\(peakPending); callback spacing is device pipeline throughput, not a guaranteed frame rate")
    }

    @MainActor func testNativeConsecutiveCapturesKeepSeparateResourcesWithoutSavingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let previousCallback = camera.onCaptureCompleted
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var shots: [CapturedPhoto] = []
        camera.onCaptureCompleted = { if let photo = $0 { shots.append(photo) } }
        defer { camera.onCaptureCompleted = previousCallback; camera.stop(); UIApplication.shared.isIdleTimerDisabled = previousIdle }
        camera.start()
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(300))
        var peak = 0
        for _ in 0..<4 {
            for _ in 0..<400 {
                if !camera.shutterBusy && camera.hasCaptureCapacity(for: PhotoOptions()) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            camera.capture(flash: false)
            peak = max(peak, camera.pendingPhotoCount)
            for _ in 0..<400 { if !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(camera.shutterBusy)
        }
        for _ in 0..<1000 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(shots.count, 4)
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        XCTAssertFalse(camera.capturing)
        XCTAssertFalse(camera.shutterBusy)
        XCTAssertEqual(Set(shots.compactMap { $0.resources.first?.filename }).count, 4)
        XCTAssertTrue(shots.allSatisfy { !$0.resources.isEmpty && !$0.resources[0].data.isEmpty })
        print("BURST-NATIVE shots=\(shots.count) peak-pending=\(peak)")
        if camera.availablePhotoFormats.contains(.rawJPEG) {
            shots.removeAll()
            let options = PhotoOptions(format: .rawJPEG)
            for _ in 0..<2 {
                for _ in 0..<400 {
                    if !camera.shutterBusy && camera.hasCaptureCapacity(for: options) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                camera.capture(flashMode: .off, options: options)
                for _ in 0..<400 { if !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertFalse(camera.shutterBusy)
            }
            for _ in 0..<1500 { if camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(shots.count, 2)
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse(camera.capturing)
            for shot in shots {
                XCTAssertEqual(shot.resources.count, 2)
                XCTAssertTrue(shot.resources.contains { $0.filename.hasSuffix(".dng") && !$0.data.isEmpty })
                XCTAssertTrue(shot.resources.contains { $0.filename.hasSuffix(".jpg") && !$0.data.isEmpty })
            }
            XCTAssertEqual(Set(shots.flatMap { $0.resources.map(\.filename) }).count, 4)
            print("BURST-NATIVE RAW+JPG shots=\(shots.count)")
        }
    }
    #endif
}

private final class BurstPhotoService: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var saved: [CapturedPhoto] = []
    private var completion: ((Result<String, Error>) -> Void)?
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) { saved.append(photo); self.completion = completion }
    func finish(_ result: Result<String, Error>) { let callback = completion; completion = nil; callback?(result) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { PhotoImageRequest(cancel: {}) }
}
