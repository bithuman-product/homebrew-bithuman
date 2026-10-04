// Essence2KitResourcesHostTests — where Essence2Kit fetches its runtime files (Swift package 2.20.5).
//
// ★WHY. Up to 2.20.4 the audio frontend and its short-window pair came from the package's GitHub
// release. From 2.20.5 they come from downloads.bithuman.ai, the same bytes under the same tag
// (the sha256 pins below the URL are unchanged), so an app keeps working without GitHub.

import XCTest
@testable import Essence2Kit

final class Essence2KitResourcesHostTests: XCTestCase {

    func testRuntimeFilesComeFromTheDownloadsHost() {
        XCTAssertEqual(Essence2Resources.base, "https://downloads.bithuman.ai/homebrew-bithuman/")
        XCTAssertFalse(Essence2Resources.base.lowercased().contains("github"))
    }

    func testEveryRuntimeFileURLIsTheDownloadsHostUnderThePinnedTag() throws {
        XCTAssertEqual(Essence2Resources.files.count, 3)
        for f in Essence2Resources.files {
            // The same composition as Essence2Resources.ensure().
            let url = try XCTUnwrap(URL(string: Essence2Resources.base + Essence2Resources.releaseTag + "/" + f.name))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "downloads.bithuman.ai")
            XCTAssertEqual(url.path, "/homebrew-bithuman/\(Essence2Resources.releaseTag)/\(f.name)")
            XCTAssertEqual(f.sha256.count, 64)
        }
    }
}
