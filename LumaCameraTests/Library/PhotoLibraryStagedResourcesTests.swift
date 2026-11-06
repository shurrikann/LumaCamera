import XCTest
import Photos
@testable import LumaCamera

final class PhotoLibraryStagedResourcesTests: XCTestCase {
    func testKindsFileTypesAndBytesSurviveUntilTransactionCompletes() throws {
        let resources = [PhotoResource(data: Data([1,2,3]), filename: "capture.jpg"),
                         PhotoResource(data: Data([4,5,6]), filename: "capture.mov", pairedVideo: true),
                         PhotoResource(data: Data([7,8,9]), filename: "capture.dng", alternate: true)]
        let staged = try PhotoLibraryStagedResources(resources)
        XCTAssertEqual(staged.entries.map(\.kind), [.photo, .pairedVideo, .alternatePhoto])
        XCTAssertEqual(staged.entries[0].typeIdentifier, "public.jpeg")
        XCTAssertEqual(staged.entries[1].typeIdentifier, "com.apple.quicktime-movie")
        for (entry, resource) in zip(staged.entries, resources) {
            XCTAssertEqual(try Data(contentsOf: entry.url), resource.data)
            XCTAssertEqual(entry.filename, resource.filename)
        }
        staged.cleanup(); XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }
    func testAbandonedOrFailedTransactionCleansTemporaryResources() throws {
        var staged: PhotoLibraryStagedResources? = try PhotoLibraryStagedResources([PhotoResource(data: Data([1]), filename: "photo.heic")])
        let directory = staged!.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        staged = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
