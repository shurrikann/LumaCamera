import XCTest
@testable import LumaCamera

#if !targetEnvironment(simulator)
@MainActor
final class CinematicLabPhysicalTests: XCTestCase {
    func testIsolatedOfficialCinematicSessionFrameDelivery() async throws {
        let lab = CinematicLabModel()
        lab.start()
        for _ in 0..<300 {
            if lab.running || lab.error != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(lab.error)
        XCTAssertTrue(lab.running)
        try await Task.sleep(for: .seconds(3))
        print("CIN-LAB frames=\(lab.frames) fps=\(lab.framesPerSecond) scene=\(lab.scene) duration=\(lab.duration) input=\(lab.inputCinematic) log=\(lab.log)")
        XCTAssertGreaterThan(lab.frames, 0)
        lab.stop()
        try await Task.sleep(for: .milliseconds(300))
    }
}
#endif
