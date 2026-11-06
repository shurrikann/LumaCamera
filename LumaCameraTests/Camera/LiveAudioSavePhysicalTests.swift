import XCTest
import Photos
import AVFoundation
import UIKit
@testable import LumaCamera

final class LiveAudioSavePhysicalTests: XCTestCase {
    private var createdPhotoAssetIDs: [String] = []

    override func tearDown() async throws {
        if !createdPhotoAssetIDs.isEmpty {
            try await Self.deleteAssets(withIdentifiers: createdPhotoAssetIDs)
        }
        try await super.tearDown()
    }

    private static func deleteAssets(withIdentifiers identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                continuation.resume(returning: (success, error?.localizedDescription))
            }
        }
        guard result.0 else {
            throw NSError(domain: "LiveAudioSavePhysicalTests.PhotoCleanup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.1 ?? "Could not remove test-created Photos assets"])
        }
    }

    #if !targetEnvironment(simulator)
    @MainActor func testOrdinaryJPEGAndAudibleLiveActuallySaveAsCorrectAssetTypes() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let callback = camera.onCaptureCompleted, oldLook = model.effectiveCaptureLook, oldMode = model.mode
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var photos: [CapturedPhoto] = []
        camera.onCaptureCompleted = { if let p = $0 { photos.append(p) } }
        defer {
            camera.onCaptureCompleted = callback; if model.capturesLivePhoto { model.toggleLivePhoto() }; camera.setLiveAudioEnabled(false)
            camera.updateLook(oldLook); model.setMode(oldMode); camera.stop()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setMode(.auto); camera.updateLook(CaptureLook()); camera.start()
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        for live in [false, true] {
            if live {
                // A real microphone prompt requires the user's choice; rejection still leaves silent Live usable.
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .audio), .authorized, "Allow microphone access for the requested audio verification")
                model.photoFormat = .jpeg; model.photoResolution = .standard
                model.setCameraActive(true)
                if !model.capturesLivePhoto { model.toggleLivePhoto() }
                camera.setLiveAudioEnabled(true)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                XCTAssertTrue(camera.liveAudioConnected)
                try await Task.sleep(for: .seconds(3))
                XCTAssertTrue(camera.liveAudioConnected, "Microphone must remain connected until the shutter")
            }
            let expected = photos.count + 1
            camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg, live: live))
            for _ in 0..<900 { if photos.count == expected { break }; try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(photos.count, expected, camera.message ?? "Capture did not finish")
            guard photos.count == expected else { return }
            let photo = photos.last!
            if live {
                let movie = try XCTUnwrap(photo.resources.first(where: \.pairedVideo))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try movie.data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
                let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
                XCTAssertFalse(tracks.isEmpty, "Audio must survive Live video filtering and export")
                let audioTrack = try XCTUnwrap(tracks.first)
                let range = try await audioTrack.load(.timeRange)
                XCTAssertGreaterThan(range.duration.seconds, 0.25)
                print("LIVE-AUDIO duration=\(range.duration.seconds) tracks=\(tracks.count)")
            }
            // This intentionally exercises Photos, not just PHLivePhoto's in-memory decoder.
            let result: Result<String, Error> = await withCheckedContinuation { c in
                SystemPhotoLibraryService().saveCapture(photo) { c.resume(returning: $0) }
            }
            let id: String
            switch result {
            case .success(let saved): id = saved
            case .failure(let error): XCTFail("ACTUAL-PHOTOS-SAVE live=\(live) error=\(error as NSError)"); return
            }
            createdPhotoAssetIDs.append(id)
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
            XCTAssertEqual(asset.mediaSubtypes.contains(.photoLive), live)
            let resources = PHAssetResource.assetResources(for: asset)
            XCTAssertEqual(resources.contains(where: { $0.type == .pairedVideo }), live)
            print("ACTUAL-PHOTOS-SAVE live=\(live) subtype=\(asset.mediaSubtypes.rawValue) resources=\(resources.map { $0.type.rawValue }) id=\(id)")
        }
        camera.setLiveAudioEnabled(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertFalse(camera.liveAudioConnected)
        // Rapid toggles must settle with no mic input and a working preview.
        for _ in 0..<40 { camera.setLiveAudioEnabled(true); camera.setLiveAudioEnabled(false) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertFalse(camera.liveAudioConnected); XCTAssertTrue(camera.ready)
    }
    @MainActor func testAudioSurvivesFrontRearAndAMSwitchesWithoutBlockingPreview() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.capturesLivePhoto { model.toggleLivePhoto() }
            model.setMode(.auto); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        if !model.capturesLivePhoto { model.toggleLivePhoto() }
        for index in 0..<6 {
            model.setMode(index % 2 == 0 ? .manual : .auto)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 {
                if camera.ready && camera.preview != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready, "Camera must settle after the A/M mode change before testing lens switching")
            let before = camera.preview
            let lensID = camera.selectedLens
            XCTAssertNotNil(model.oppositeLens, "The opposite camera must be available for the current route")
            print("LIVE-ROUTE before index=\(index) ready=\(camera.ready) busy=\(camera.videoBusy) selected=\(lensID) opposite=\(model.oppositeLens?.id ?? "nil")")
            model.flipCamera()
            for _ in 0..<200 {
                if camera.selectedLens != lensID, camera.preview != nil, camera.preview !== before { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            print("LIVE-ROUTE after index=\(index) ready=\(camera.ready) selected=\(camera.selectedLens)")
            XCTAssertNotEqual(camera.selectedLens, lensID)
            XCTAssertTrue(camera.ready)
            XCTAssertTrue(model.capturesLivePhoto)
            XCTAssertTrue(camera.liveAudioConnected)
            XCTAssertNotNil(camera.preview)
        }
    }
    #endif
}
