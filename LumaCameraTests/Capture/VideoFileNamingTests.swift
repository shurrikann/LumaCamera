import XCTest
@testable import LumaCamera

final class VideoFileNamingTests: XCTestCase {
    func testReadableVideoFilenameIncludesSettingsAndTimestamp() {
        var settings = VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps60, colorSpace: .appleLog2)
        settings.codec = .hevc
        let date = Date(timeIntervalSince1970: 1_781_000_000)
        let name = VideoFileNaming.filename(for: settings, timeLapse: true, date: date)
        XCTAssertTrue(name.hasPrefix("LumaVideo_2026"))
        XCTAssertTrue(name.contains("4K60"))
        XCTAssertTrue(name.contains("HEVC"))
        XCTAssertTrue(name.contains("AppleLog2"))
        XCTAssertTrue(name.hasSuffix("_Timelapse.mov"))
        XCTAssertFalse(name.contains(" "))
        XCTAssertFalse(name.contains("/"))
    }

    func testCollisionGetsStableSuffixWithoutRenamingBase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaNamingTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30)
        let date = Date(timeIntervalSince1970: 1_781_000_000)
        let first = VideoFileNaming.temporaryURL(for: settings, date: date, directory: directory)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = VideoFileNaming.temporaryURL(for: settings, date: date, directory: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("_2.mov"))
    }
}
