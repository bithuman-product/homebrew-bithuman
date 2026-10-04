// Essence2KitCrossAccountTests — a cached private avatar is not another account's (2.20.2, security).
//
// ★WHY. The download directory belongs to the app, not to an account. In 2.20.1 a copy already on
// the device was returned at once to ANY credential and the door asked only in the background, its
// refusal ignored: account B, signed in where account A had opened its PRIVATE avatar, got A's file.
// The door is the only gate — owner-scoped — and the session meter checks the key, not the avatar.
// MEASURED against production on 2026-10-03 with the internal house key (B) for the showcase house
// account's PRIVATE Essence 2 avatar A99LTC2401: GET /v1/agent/A99LTC2401/model/download
// ?model=essence-2&slice=apple&abi_max=1&redirect=false answered 404 with `prod404` below, byte for
// byte; POST /v1/auth/validate {"product":"essence-2","agent_code":"A99LTC2401"} answered 200.
//
// These tests drive the shipped download with a scripted door that answers the owner's credential
// 200 and any other credential exactly as production did. On 2.20.1 the first two FAIL.

import XCTest
import CryptoKit
@testable import Essence2Kit

final class Essence2KitCrossAccountTests: XCTestCase {

    static let code = "A99LTC2401"                 // a house PRIVATE avatar's code; no network here
    static let owner = "owner-credential-A"        // never a real key
    static let other = "other-credential-B"
    static let prod404 = "{\"error\": {\"code\": \"NOT_FOUND\", \"message\": \"Agent not found for code: "
        + "A99LTC2401\", \"httpStatus\": 404}, \"status\": \"error\", \"status_code\": 404}"

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("essence2kit-xaccount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await Essence2Download.settle()
        Essence2Credential.set(nil)
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// The door, owner-scoped like production. `down` answers 503; `ownerKey` may change hands.
    final class Door: @unchecked Sendable {
        private let lock = NSLock()
        private var ownerKey: String
        private var isDown = false
        private var ownerBody404: String?
        private(set) var asks: [String] = []
        let bytes: Data
        init(owner: String, bytes: Data) { ownerKey = owner; self.bytes = bytes }
        func setOwner(_ o: String) { lock.lock(); ownerKey = o; lock.unlock() }
        func setDown(_ d: Bool) { lock.lock(); isDown = d; lock.unlock() }
        /// Answer the owner 404 with this body (the door's MODEL_ARTIFACT_NOT_READY during a re-bake).
        func setOwner404(_ b: String?) { lock.lock(); ownerBody404 = b; lock.unlock() }
        var askLog: [String] { lock.lock(); defer { lock.unlock() }; return asks }
        func clear() { lock.lock(); asks = []; lock.unlock() }
        private func decide(_ key: String?) -> (down: Bool, owner: Bool, owner404: String?) {
            lock.lock(); defer { lock.unlock() }
            let isOwner = key == ownerKey
            asks.append(isOwner ? "owner" : (key == nil ? "anonymous" : "other"))
            return (isDown, isOwner, ownerBody404)
        }

        var io: Essence2Download.DoorIO {
            Essence2Download.DoorIO(
                grant: { [self] req in
                    let d = decide(req.value(forHTTPHeaderField: "api-secret"))
                    if d.down { return (503, Data()) }
                    if !d.owner { return (404, Data(Essence2KitCrossAccountTests.prod404.utf8)) }
                    if let b = d.owner404 { return (404, Data(b.utf8)) }
                    let sha = Essence2KitCrossAccountTests.sha(bytes)
                    return (200, Data("{\"data\":{\"url\":\"https://door.invalid/file/\(sha)\",\"sha256\":\"\(sha)\",\"slice\":\"apple\"}}".utf8))
                },
                file: { [self] _ in
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("door-\(UUID().uuidString)")
                    try bytes.write(to: tmp)
                    return (200, tmp)
                })
        }
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    let avatar = Data(repeating: 0x5A, count: 40_000)

    private func open(_ door: Door, as credential: String?, _ mode: Essence2Download.Mode = .background) async throws -> URL {
        Essence2Credential.set(credential)
        return try await Essence2Download.identity(agentCode: Self.code, directory: dir, io: door.io, mode: mode)
    }

    private var file: URL { dir.appendingPathComponent(Self.sha(avatar) + ".imx") }

    // MARK: - another account

    func testAnotherAccountIsNotHandedTheCachedPrivateAvatar() async throws {
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        door.clear()
        do {
            let got = try await open(door, as: Self.other)
            XCTFail("B was handed A's private avatar: \(got.lastPathComponent)")
        } catch {
            XCTAssertTrue("\(error)".contains("HTTP 404"), "\(error)")
        }
        XCTAssertEqual(door.askLog, ["other"], "B's open asked the door first, once")
        XCTAssertEqual(try Data(contentsOf: file), avatar, "A's file is untouched")
        await Essence2Download.settle()
        door.clear()
        door.setDown(true)
        let again = try await open(door, as: Self.owner)
        XCTAssertEqual(again.standardizedFileURL, file.standardizedFileURL, "A still opens at once, door down")
    }

    func testAnotherAccountIsRefusedOnTheBlockingCheckToo() async throws {
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        do {
            let got = try await open(door, as: Self.other, .blocking)
            XCTFail("B was handed A's private avatar: \(got.lastPathComponent)")
        } catch {}
    }

    func testTheOwnerStillOpensWithTheDoorDown() async throws {
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        door.setDown(true)
        let a = try await open(door, as: Self.owner)
        XCTAssertEqual(a.standardizedFileURL, file.standardizedFileURL)
        await Essence2Download.settle()
        let b = try await open(door, as: Self.owner, .blocking)
        XCTAssertEqual(b.standardizedFileURL, file.standardizedFileURL)
    }

    // MARK: - the marks (2.20.2)

    func testARefusalOfTheOwnersCredentialLandsOnTheNextOpen() async throws {
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        door.setOwner("someone-else")          // a revoked key, or the avatar changed hands
        let now = try await open(door, as: Self.owner)
        XCTAssertEqual(now.standardizedFileURL, file.standardizedFileURL, "this open was already returned")
        await Essence2Download.settle()
        let key = "\(Self.code).essence-2.apple.abi1"
        XCTAssertEqual(Essence2Download.inFlight.lastOutcome(DoorStoreID.of(dir, key)), .keptDenied)
        do { _ = try await open(door, as: Self.owner); XCTFail("the next open is refused") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the file is kept")
    }

    func testA2201CacheAsksTheDoorOnceThenNeverWaits() async throws {
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        let marks = dir.appendingPathComponent(".door/\(Self.code).essence-2.apple.abi1.auth", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marks.path))
        try FileManager.default.removeItem(at: marks)        // what 2.20.1 left: a pointer, no marks
        door.clear()
        let first = try await open(door, as: Self.owner)
        XCTAssertEqual(first.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(door.askLog, ["owner"], "one door ask; the copy was used, nothing downloaded")
        door.setDown(true)
        let next = try await open(door, as: Self.owner)
        XCTAssertEqual(next.standardizedFileURL, file.standardizedFileURL, "marked now: door down, still opens")
    }

    func testACopyFromBeforeTheMarksIsNotServedWithTheDoorDown() async throws {
        // Fail closed: nothing says which account left a 2.20.1 copy, so with the door down its
        // first open fails (the meter needs bitHuman reachable to start a session anyway).
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".door/\(Self.code).essence-2.apple.abi1.auth"))
        door.setDown(true)
        do { _ = try await open(door, as: Self.owner); XCTFail("an unmarked copy is not a cache hit") } catch {}
        door.setDown(false)
        _ = try await open(door, as: Self.owner)
        door.setDown(true)
        _ = try await open(door, as: Self.owner)   // marked once the door answered: door-down opens work
    }

    func testANotReadyAnswerKeepsTheOwnersMark() async throws {
        // review finding 1: the door answers the OWNER 404 MODEL_ARTIFACT_NOT_READY during a re-bake.
        let door = Door(owner: Self.owner, bytes: avatar)
        _ = try await open(door, as: Self.owner)
        await Essence2Download.settle()
        door.setOwner404("{\"error\": {\"code\": \"MODEL_ARTIFACT_NOT_READY\", \"message\": \"not ready yet\", \"httpStatus\": 404}}")
        let now = try await open(door, as: Self.owner)
        XCTAssertEqual(now.standardizedFileURL, file.standardizedFileURL)
        await Essence2Download.settle()
        let blocking = try await open(door, as: Self.owner, .blocking)
        XCTAssertEqual(blocking.standardizedFileURL, file.standardizedFileURL, "blocking: the copy, no throw")
        door.setOwner404(nil)
        door.setDown(true)
        let down = try await open(door, as: Self.owner)
        XCTAssertEqual(down.standardizedFileURL, file.standardizedFileURL, "the mark survived: door-down opens")
    }

    func testOnlyNotFoundIsADenial() {
        XCTAssertEqual(Essence2Download.doorErrorCode(Self.prod404), "NOT_FOUND")
        XCTAssertEqual(Essence2Download.doorErrorCode("{\"error\": {\"code\": \"MODEL_ARTIFACT_NOT_READY\"}}"), "MODEL_ARTIFACT_NOT_READY")
        XCTAssertNil(Essence2Download.doorErrorCode("{\"error\":\"door down\"}"))
    }

    func testTheMarkIsATagNeverTheCredential() {
        let t = Essence2Download.credentialTag(Self.owner)
        XCTAssertEqual(t.count, 32)
        XCTAssertFalse(t.contains(Self.owner))
        XCTAssertNotEqual(t, Essence2Download.credentialTag(Self.other))
        XCTAssertNotEqual(t, Essence2Download.credentialTag(nil))
    }
}
