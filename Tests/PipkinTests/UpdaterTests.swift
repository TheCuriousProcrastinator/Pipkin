import XCTest
@testable import pipkin

final class UpdaterTests: XCTestCase {
    func testNoPublishedReleaseRecognizesUpdater404() {
        let error = Updater.makeError("No published release", code: 404)
        XCTAssertTrue(Updater.isNoPublishedRelease(error))
    }

    func testNoPublishedReleaseDoesNotMaskOtherErrors() {
        let error = Updater.makeError("Server error", code: 500)
        XCTAssertFalse(Updater.isNoPublishedRelease(error))
    }
}
