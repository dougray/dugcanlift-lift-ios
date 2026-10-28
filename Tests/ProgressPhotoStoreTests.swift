import XCTest
import UIKit
@testable import Lift

final class ProgressPhotoStoreTests: XCTestCase {
    private func store() -> ProgressPhotoStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProgressPhotoStore(directory: directory)
    }

    private func jpeg(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    func testPhotosAreKeptOldestFirstAndDeleted() throws {
        let store = store()
        XCTAssertEqual(store.photos(), [])
        let later = try store.save(jpeg(width: 30, height: 40), on: Date(timeIntervalSince1970: 1_800_000_000))
        let earlier = try store.save(jpeg(width: 30, height: 40), on: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(store.photos().map(\.id), [earlier.id, later.id])
        store.delete(earlier)
        XCTAssertEqual(store.photos().map(\.id), [later.id])
    }

    /// A camera original is cut down to 2048 px on its long side.
    func testABigPhotoIsScaledDown() throws {
        let store = store()
        let photo = try store.save(jpeg(width: 4032, height: 3024))
        let image = try XCTUnwrap(UIImage(contentsOfFile: photo.url.path))
        XCTAssertEqual(max(image.size.width, image.size.height), 2048)
    }

    func testSomethingThatIsNotAPictureIsRefused() {
        XCTAssertThrowsError(try store().save(Data("not a picture".utf8)))
    }

    /// Anything else in the folder is not a progress photo and is left alone.
    func testOtherFilesAreIgnored() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data().write(to: store.directory.appendingPathComponent("notes.txt"))
        try Data().write(to: store.directory.appendingPathComponent("nonsense.jpg"))
        XCTAssertEqual(store.photos(), [])
    }
}
