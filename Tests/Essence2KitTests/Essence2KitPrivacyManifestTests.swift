// Essence2KitPrivacyManifestTests — the package's App Store privacy manifest (Swift package 2.20.2).
//
// ★WHY. Apps that ship this package need its required-reason API declarations in their bundle:
// SwiftPM copies a target's PrivacyInfo.xcprivacy into the app as that target's resource bundle,
// and Xcode's privacy report and App Store Connect read it from there. The categories below were
// found by scanning the shipped binaries (nm -u / strings on Expression2, libessence2,
// onnxruntime and EngineCore) and the package's Swift sources; see the comment in the manifest.

import XCTest
@testable import Essence2Kit

final class Essence2KitPrivacyManifestTests: XCTestCase {

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "Essence2Kit's resource bundle carries PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testTheManifestShipsAndDeclaresNoTracking() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
    }

    func testEveryRequiredReasonCategoryTheBinariesUseIsDeclared() throws {
        let types = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var got: [String: [String]] = [:]
        for t in types {
            got[try XCTUnwrap(t["NSPrivacyAccessedAPIType"] as? String)] =
                try XCTUnwrap(t["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        // stat/fstat/lstat (libessence2, onnxruntime, EngineCore), NSFileModificationDate and
        // URLResourceKey.contentModificationDateKey (Expression2): the SDK's own files.
        XCTAssertEqual(got["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
        // ProcessInfo.systemUptime (Expression2, libessence2): elapsed time inside the app.
        XCTAssertEqual(got["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        // Not used by any shipped binary (no statfs/statvfs/volumeAvailableCapacity, no
        // NSUserDefaults, no activeInputModes): declaring them would be a false statement.
        XCTAssertNil(got["NSPrivacyAccessedAPICategoryDiskSpace"])
        XCTAssertNil(got["NSPrivacyAccessedAPICategoryUserDefaults"])
        XCTAssertNil(got["NSPrivacyAccessedAPICategoryActiveKeyboards"])
    }

    func testTheSessionMetersDataIsDeclaredAsAppFunctionalityNotTracking() throws {
        let kinds = try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        var names: [String] = []
        for k in kinds {
            names.append(try XCTUnwrap(k["NSPrivacyCollectedDataType"] as? String))
            XCTAssertEqual(k["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(k["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(k["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
        XCTAssertEqual(names.sorted(), ["NSPrivacyCollectedDataTypeDeviceID",
                                        "NSPrivacyCollectedDataTypeOtherUsageData"])
    }
}
