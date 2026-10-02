// Essence2KitOutdatedIdentityTests — an identity file published before the renderer this SDK
// carries (2026-10-02).
//
// ★WHY. The essence2 engines that carry the out-of-date-file refusal refuse an avatar file published
// before the mouth-corner fix (2026-10-01): `be_essence2_create` answers -4 with a sentence naming
// the agent (bithuman-models #1763/#1766). essence2-v1.15.2, and essence2-v1.15.3 (the hotfix this
// package pins since 2.20.0, cut from the 1.15.2 source WITHOUT #1763), predate that:
// it still OPENS such a file on its older renderer (measured 2026-10-02 on an M4 with house avatar
// A23KSG5258: two such files, one with a lip template and one without, both open and render
// speech; neither answers -2 or -4). Once the pin moves, Essence2Kit fetches
// a file the download door put in its cache again, once, and throws `identityOutdated` (agent +
// fix) for any other file. These tests hold the pure pieces of that: which files are door
// downloads, the agent code read from the engine's sentence, and the sentence a developer reads.
// The heal itself is Essence2KitHealTests (scripted opens + a local door, and an opt-in run of a
// real out-of-date house bundle on the linked engine).

import XCTest
import Essence2
@testable import Essence2Kit

final class Essence2KitOutdatedIdentityTests: XCTestCase {

    let refusal = "LeCoreSession: le_core refused the bundle — le_utt_create: Renderer: LEGACY "
        + "REFUSED for identity 'A23KSG5258' (b1_fp32): this bundle carries no lip_template.v1.json"

    func testTheAgentCodeIsReadFromTheEnginesSentence() {
        XCTAssertEqual(Essence2Download.agentCode(inRefusal: refusal), "A23KSG5258")
        // control: a sentence that names no agent (a bare directory) yields none
        XCTAssertEqual(Essence2Download.agentCode(inRefusal: "REFUSED for identity '/tmp/x y'"), "")
        XCTAssertEqual(Essence2Download.agentCode(inRefusal: "could not open"), "")
    }

    func testOnlyAFileTheDownloaderWroteIsFetchedAgain() {
        let sha = String(repeating: "ab", count: 32)
        XCTAssertTrue(Essence2Download.isDownloaded(URL(fileURLWithPath: "/c/\(sha).imx")))
        // controls: a file the app keeps (any other name) is the app's — refused, never replaced
        XCTAssertFalse(Essence2Download.isDownloaded(URL(fileURLWithPath: "/c/A23KSG5258.imx")))
        XCTAssertFalse(Essence2Download.isDownloaded(URL(fileURLWithPath: "/c/\(sha.uppercased()).imx")))
        XCTAssertFalse(Essence2Download.isDownloaded(URL(fileURLWithPath: "/c/\(sha).imx.partial")))
    }

    func testTheRefusalNamesTheAgentAndTheFix() {
        let e = Essence2KitError.identityOutdated(path: "/app/sofia.imx", agentCode: "A23KSG5258", reason: refusal)
        XCTAssertTrue(e.description.contains("out of date"))
        XCTAssertTrue(e.description.contains("Essence2Download.identity(agentCode: \"A23KSG5258\")"))
        XCTAssertTrue(e.description.contains("Download model"))
        let anon = Essence2KitError.identityOutdated(path: "/app/x.imx", agentCode: "", reason: refusal)
        XCTAssertTrue(anon.description.contains("<agent code>"))
    }
}
