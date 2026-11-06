import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class FilterEditorPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testEditedFilterKeepsLiveFramesAndCaptureRecipeWithoutSavingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let oldStyle = model.style, oldStrength = model.intensity, oldRecipe = model.filterAdjustments
        model.style = .leicaM9
        let m9 = SavedFilterSettings(intensity: model.intensity, adjustments: model.filterAdjustments)
        model.style = oldStyle
        let oldFormat = model.photoFormat, oldRatio = model.ratio, oldMode = model.mode
        let originalCallback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var shots: [CapturedPhoto] = []
        camera.onCaptureCompleted = { if let photo = $0 { shots.append(photo) } }
        defer {
            camera.onCaptureCompleted = originalCallback
            model.style = .leicaM9
            model.intensity = m9.intensity; model.filterAdjustments = m9.adjustments
            model.style = oldStyle; model.intensity = oldStrength; model.filterAdjustments = oldRecipe
            model.photoFormat = oldFormat; model.ratio = oldRatio; model.setMode(oldMode)
            model.flushFilterSettings(); camera.stop(); UIApplication.shared.isIdleTimerDisabled = idle
        }
        camera.start()
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.style = .leicaM9; model.intensity = 0.8; model.ratio = .standard; model.photoFormat = .jpeg
        var recipe = FilterAdjustments()
        for parameter in FilterParameter.allCases where parameter != .strength { recipe[parameter] = parameter == .exposure ? 0.2 : 12 }
        model.filterAdjustments = recipe
        var times: [Double] = []
        let token = camera.$preview.dropFirst().compactMap { $0 }.sink { _ in times.append(CACurrentMediaTime()) }
        defer { token.cancel() }
        for _ in 0..<60 { if times.count >= 20 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(times.count, 5, "Spatial effects must continue publishing live frames")
        if let first = times.first, let last = times.last { print("FILTER-EDITOR frames=\(times.count) span=\(last-first) fps=\(Double(times.count-1)/max(last-first,0.001))") }
        for parameter in [FilterParameter.halation, .softness, .detail, .aberration, .grainSize, .vignette] {
            var single = FilterAdjustments(); single[parameter] = parameter == .detail ? -100 : 100
            model.filterAdjustments = single
            try await Task.sleep(for: .milliseconds(200))
            times.removeAll()
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertGreaterThan(times.count, 3, "Effect stalled: \(parameter)")
            if let first = times.first, let last = times.last { print("FILTER-EFFECT \(parameter.rawValue) fps=\(Double(times.count-1)/max(last-first,0.001))") }
        }
        model.filterAdjustments = recipe
        try await Task.sleep(for: .milliseconds(200))
        times.removeAll()
        model.setFilterParameterEditing(true)
        for i in 0..<120 {
            model.filterParameterBinding(.temperature).wrappedValue = Double(i) - 60
            try await Task.sleep(for: .milliseconds(8))
        }
        model.setFilterParameterEditing(false)
        XCTAssertGreaterThan(times.count, 8, "Preview must progress during continuous slider input")
        if let first = times.first, let last = times.last { print("FILTER-DRAG frames=\(times.count) span=\(last-first)") }
        recipe = model.filterAdjustments
        camera.capture(flashMode: .off, options: model.photoOptions)
        for _ in 0..<600 { if camera.pendingPhotoCount == 0 && !shots.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        XCTAssertEqual(shots.first?.diagnostics?.parameters?.filterAdjustments, recipe)
        XCTAssertEqual(shots.first?.diagnostics?.parameters?.filterID, FilmStyle.leicaM9.rawValue)
        XCTAssertFalse(shots.first?.resources.isEmpty ?? true)
        print("FILTER-EDITOR captured=\(shots.count) pending=\(camera.pendingPhotoCount)")
    }
    @MainActor func testRepeatedFilterEditingResetsAndFormatChangesStayBoundedAndRecover() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let selected = model.style, mode = model.mode, format = model.photoFormat, ratio = model.ratio
        let tab = model.filterEditorTab, showHistogram = model.showHistogram, oldPeaking = model.focusPeaking
        var saved: [FilmStyle: SavedFilterSettings] = [:]
        for style in FilmStyle.availableStyles { model.style = style; saved[style] = SavedFilterSettings(intensity: model.intensity, adjustments: model.filterAdjustments) }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setFilterParameterEditing(false); model.dismissFilterReset()
            for (style, settings) in saved { model.style = style; model.intensity = settings.intensity; model.filterAdjustments = settings.adjustments }
            model.style = selected; model.photoFormat = format; model.ratio = ratio; model.filterEditorTab = tab; model.showHistogram = showHistogram; model.focusPeaking = oldPeaking
            model.setMode(mode); model.closePopups(); model.flushFilterSettings(); camera.stop()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.style = .leicaM9; model.photoFormat = .jpeg; model.showHistogram = true
        camera.start()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .seconds(2))
        var frames = 0
        let token = camera.$preview.dropFirst().sink { if $0 != nil { frames += 1 } }; defer { token.cancel() }
        let baseline = footprint(); var peak = baseline
        var samples: [UInt64] = []
        let start = CACurrentMediaTime()
        for cycle in 0..<120 {
            model.filterEditorTab = FilterEditorTab.allCases[cycle % 3]
            if cycle % 8 == 0 {
                model.focusPeaking.toggle()
                model.closePopups(); model.panel = .film; model.filters.showStrength = true
                model.style = cycle % 16 == 0 ? .original : .leicaM9
                model.ratio = FrameRatio.allCases[(cycle / 8) % FrameRatio.allCases.count]
                model.photoFormat = cycle % 24 == 0 ? .raw : .jpeg
            }
            model.setFilterParameterEditing(true)
            for (index, parameter) in FilterParameter.allCases.enumerated() {
                let fraction = Double((cycle * 13 + index * 7) % 101) / 100
                model.filterParameterBinding(parameter).wrappedValue = parameter.range.lowerBound + fraction * (parameter.range.upperBound - parameter.range.lowerBound)
                try await Task.sleep(for: .milliseconds(8))
            }
            model.setFilterParameterEditing(false)
            if cycle % 6 == 0 {
                model.presentFilterReset()
                if cycle % 12 == 0 { model.confirmFilterReset() } else { model.dismissFilterReset() }
            }
            let bytes = footprint(); peak = max(peak, bytes); samples.append(bytes)
        }
        let during = frames
        model.photoFormat = .jpeg; model.style = .original; model.resetCurrentFilter()
        model.closePopups()
        try await Task.sleep(for: .seconds(2))
        let settled = footprint()
        XCTAssertGreaterThan(during, 60, "Preview must keep progressing under repeated editing")
        XCTAssertGreaterThan(frames, during + 5, "Preview must recover after the final reset")
        XCTAssertTrue(camera.ready); XCTAssertEqual(camera.pendingPhotoCount, 0)
        XCTAssertLessThan(peak, baseline + 256 * 1024 * 1024, "Unbounded memory growth during edits")
        XCTAssertLessThan(settled, baseline + 128 * 1024 * 1024, "Memory retained after closing the editor")
        print("FILTER-STRESS updates=2040 seconds=\(CACurrentMediaTime()-start) frames=\(during) baselineMB=\(baseline/1048576) peakMB=\(peak/1048576) settledMB=\(settled/1048576) checkpointsMB=\(samples.enumerated().filter { $0.offset % 20 == 0 }.map { $0.element/1048576 })")
    }
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return info.phys_footprint
    }
    #endif
}
