import XCTest
@testable import LumaCamera

final class BatchPhotoShareTests: XCTestCase {
    @MainActor func testSequentialExportsKeepSameFilenamesSeparateAndCleanAfterDismissal() async throws {
        let service = ShareExportStub(), model = BatchPhotoShareModel()
        model.prepare(photos: ["first", "second"].map { LibraryPhoto(id: $0, date: nil) }, service: service)
        XCTAssertEqual(service.ids, ["first"])
        service.complete(.success(Data([1])))
        for _ in 0..<20 { if service.ids.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(service.ids, ["first", "second"])
        XCTAssertEqual(model.completedCount, 1)
        service.complete(.success(Data([2])))
        for _ in 0..<20 { if model.prepared != nil { break }; await Task.yield() }
        let urls = try XCTUnwrap(model.prepared?.urls), directory = try XCTUnwrap(model.prepared?.directory)
        XCTAssertEqual(urls.count, 2); XCTAssertNotEqual(urls[0], urls[1])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["IMG_0001.dng", "IMG_0001.dng"])
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data([1])); XCTAssertEqual(try Data(contentsOf: urls[1]), Data([2]))
        XCTAssertFalse(model.preparing)
        model.prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    @MainActor func testCancelAndLateCompletionCannotOpenShareOrReplaceNewRequest() async throws {
        let service = ShareExportStub(), model = BatchPhotoShareModel()
        model.prepare(photos: [LibraryPhoto(id: "old", date: nil)], service: service)
        let old = service.completion, oldFolder = try XCTUnwrap(service.folder)
        model.cancelPreparation()
        XCTAssertTrue(service.cancelled); XCTAssertFalse(model.preparing)
        model.prepare(photos: [LibraryPhoto(id: "new", date: nil)], service: service)
        old?(.success(oldFolder.appendingPathComponent("old.jpg")))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(model.preparing); XCTAssertNil(model.prepared)
        service.complete(.success(Data([3])))
        for _ in 0..<20 { if model.prepared != nil { break }; await Task.yield() }
        XCTAssertEqual(model.prepared?.urls.count, 1)
        model.prepared = nil
    }
    @MainActor func testFailedSecondImageCleansFirstFileAndDoesNotOfferPartialShare() async throws {
        let service = ShareExportStub(), model = BatchPhotoShareModel()
        model.prepare(photos: ["one", "two"].map { LibraryPhoto(id: $0, date: nil) }, service: service)
        let folder = try XCTUnwrap(service.folder).deletingLastPathComponent()
        service.complete(.success(Data([1])))
        for _ in 0..<20 { if service.ids.count == 2 { break }; await Task.yield() }
        service.complete(.failure(PhotoDetailError.unavailable))
        for _ in 0..<20 { if !model.preparing { break }; await Task.yield() }
        XCTAssertNil(model.prepared); XCTAssertFalse(model.preparing)
        XCTAssertTrue(model.message?.contains("第 2 张") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testStreamedFileBytesAndCancellationRemovePartialResource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try PhotoExportFileWriter(url: folder.appendingPathComponent("image.heic"))
        writer.append(Data([1,2])); writer.append(Data([3,4]))
        XCTAssertEqual(try Data(contentsOf: writer.finish(error: nil).get()), Data([1,2,3,4]))
        let cancelled = try PhotoExportFileWriter(url: folder.appendingPathComponent("cancelled.dng"))
        cancelled.append(Data([8])); cancelled.cancel(); cancelled.append(Data([9]))
        XCTAssertThrowsError(try cancelled.finish(error: nil).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.url.path))
    }
}
private final class ShareExportStub: PhotoFileExportService {
    var ids: [String] = []
    var folder: URL?
    var completion: ((Result<URL, Error>) -> Void)?
    var cancelled = false
    func exportPhoto(id: String, directory: URL, completion: @escaping (Result<URL, Error>) -> Void) -> PhotoImageRequest {
        ids.append(id); folder = directory; self.completion = completion; cancelled = false
        return PhotoImageRequest { [weak self] in self?.cancelled = true }
    }
    func complete(_ result: Result<Data, Error>) {
        guard let folder, let completion else { return }; self.completion = nil
        do {
            let data = try result.get()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("IMG_0001.dng"); try data.write(to: url)
            completion(.success(url))
        } catch { completion(.failure(error)) }
    }
}
