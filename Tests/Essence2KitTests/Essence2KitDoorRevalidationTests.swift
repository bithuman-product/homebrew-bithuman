// Essence2KitDoorRevalidationTests — a cache hit no longer waits for the door (2.20.1).
//
// ★WHY. Up to 2.20.0 `Essence2Download.identity` asked the door before it looked in the cache:
// every open of an avatar already on the device waited on a round trip, and a door error failed
// the open with a good copy on disk. Now the last file served is returned at once and the door is
// asked in the background; a change is staged (downloaded, checked, journalled) and the NEXT call
// swaps it in from disk. These tests drive the store with a scripted door (no network): the
// download's two requests are a parameter (`DoorIO`), as the heal's are in Essence2KitHealTests.

import XCTest
import CryptoKit
@testable import Essence2Kit

final class Essence2KitDoorRevalidationTests: XCTestCase {

    static let code = "A23KSG5258"   // a house avatar's code; nothing here touches the network

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("essence2kit-door-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await Essence2Download.settle()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - a scripted door

    enum Answer { case serve(Data), status(Int), timeout, slow(Data, seconds: Double) }

    final class Door: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Answer
        private(set) var grants = 0
        private(set) var files = 0
        init(_ a: Answer) { answer = a }
        func set(_ a: Answer) { lock.lock(); answer = a; lock.unlock() }
        var counts: (grants: Int, files: Int) { lock.lock(); defer { lock.unlock() }; return (grants, files) }

        private var served: [String: Data] = [:]
        private func current() -> Answer { lock.lock(); defer { lock.unlock() }; return answer }
        private func countGrant() { lock.lock(); grants += 1; lock.unlock() }
        private func remember(_ sha: String, _ b: Data) { lock.lock(); served[sha] = b; lock.unlock() }
        private func countFile(_ sha: String) -> Data? { lock.lock(); defer { lock.unlock() }; files += 1; return served[sha] }

        var io: Essence2Download.DoorIO {
            Essence2Download.DoorIO(
                grant: { [self] req in
                    countGrant()
                    XCTAssertTrue(req.url!.path.hasSuffix("/v1/agent/\(Essence2KitDoorRevalidationTests.code)/model/download"))
                    var bytes: Data
                    switch current() {
                    case .status(let s): return (s, Data("{\"error\":\"door down\"}".utf8))
                    case .timeout: throw URLError(.timedOut)
                    case .serve(let b): bytes = b
                    case .slow(let b, let s):
                        try await Task.sleep(nanoseconds: UInt64(s * 1e9)); bytes = b
                    }
                    let sha = Essence2KitDoorRevalidationTests.sha(bytes)
                    remember(sha, bytes)
                    let body = "{\"data\":{\"url\":\"https://door.invalid/file/\(sha)\",\"sha256\":\"\(sha)\",\"slice\":\"apple\"}}"
                    return (200, Data(body.utf8))
                },
                file: { [self] url in
                    let b = countFile(url.lastPathComponent)
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("door-\(UUID().uuidString)")
                    try (b ?? Data()).write(to: tmp)
                    return (b == nil ? 404 : 200, tmp)
                })
        }
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    let v1 = Data(repeating: 0x11, count: 50_000)
    let v2 = Data(repeating: 0x22, count: 38_000)

    private func open(_ door: Door, _ mode: Essence2Download.Mode = .background) async throws -> URL {
        try await Essence2Download.identity(agentCode: Self.code, directory: dir, io: door.io, mode: mode)
    }

    private func file(_ d: Data) -> URL { dir.appendingPathComponent(Self.sha(d) + ".imx") }
    private var meta: URL { dir.appendingPathComponent(".door", isDirectory: true) }
    private var key: String { "\(Self.code).essence-2.apple.abi1" }
    private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    // MARK: - no copy: exactly as before

    func testWithNoCopyACallAsksTheDoorDownloadsAndChecksAsBefore() async throws {
        let door = Door(.serve(v1))
        let got = try await open(door)
        XCTAssertEqual(got.standardizedFileURL, file(v1).standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: got), v1)
        XCTAssertEqual(door.counts.grants, 1)
        XCTAssertEqual(door.counts.files, 1)
        XCTAssertEqual(try String(contentsOf: meta.appendingPathComponent(key + ".current"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines), Self.sha(v1), "what was served is recorded")
    }

    func testWithNoCopyADoorErrorStillFailsTheCallAsBefore() async throws {
        let door = Door(.status(503))
        do { _ = try await open(door); XCTFail("no copy and no door: nothing to open") } catch let e as Essence2KitError {
            XCTAssertTrue(e.description.contains("the download door answered HTTP 503"), e.description)
        }
        door.set(.timeout)
        do { _ = try await open(door); XCTFail("no copy and no door: nothing to open") } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        }
    }

    func testABadDownloadIsRefusedNeverOpened() async throws {
        // a door whose file is not the bytes its sha256 names
        let door = Door(.serve(v1))
        let bad = Essence2Download.DoorIO(grant: door.io.grant, file: { _ in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("door-\(UUID().uuidString)")
            try Data("tampered".utf8).write(to: tmp)
            return (200, tmp)
        })
        do { _ = try await Essence2Download.identity(agentCode: Self.code, directory: dir, io: bad, mode: .background)
            XCTFail("refused") } catch let e as Essence2KitError {
            XCTAssertTrue(e.description.contains("not the door's"), e.description)
        }
        XCTAssertFalse(exists(file(v1)))
    }

    // MARK: - a good copy: the door never fails the call

    func testADoor5xxWithAGoodCopyOpensFromTheCopy() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.status(503))
        for mode in [Essence2Download.Mode.background, .blocking] {
            let got = try await open(door, mode)
            XCTAssertEqual(got.standardizedFileURL, file(v1).standardizedFileURL, "\(mode)")
            await Essence2Download.settle()
        }
        XCTAssertEqual(door.counts.files, 1, "nothing was downloaded again")
        XCTAssertEqual(Essence2Download.inFlight.lastOutcome(DoorStoreID.of(dir, key)), .keptUnreachable)
    }

    func testADoorTimeoutWithAGoodCopyOpensFromTheCopy() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.timeout)
        for mode in [Essence2Download.Mode.background, .blocking] {
            let got = try await open(door, mode)
            XCTAssertEqual(got.standardizedFileURL, file(v1).standardizedFileURL, "\(mode)")
            await Essence2Download.settle()
        }
    }

    func testACacheHitDoesNotWaitForASlowDoor() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.slow(v1, seconds: 2))
        let t0 = Date()
        let got = try await open(door)
        let waited = Date().timeIntervalSince(t0)
        XCTAssertEqual(got.standardizedFileURL, file(v1).standardizedFileURL)
        XCTAssertLessThan(waited, 1.0, "the copy came back without waiting on the door (\(waited) s)")
        await Essence2Download.settle()
        XCTAssertEqual(Essence2Download.inFlight.lastOutcome(DoorStoreID.of(dir, key)), .unchanged)
    }

    func testOneBackgroundRevalidationPerAvatarInFlight() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.slow(v1, seconds: 0.5))
        for _ in 0..<5 { _ = try await open(door) }
        await Essence2Download.settle()
        XCTAssertEqual(door.counts.grants, 2, "the install + ONE revalidation for five opens")
    }

    // MARK: - a changed file: staged, swapped on the next call from disk

    func testAChangedDoorShaIsStagedAndSwappedInOnTheNextOpen() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.serve(v2))

        // this open: the copy at once; the change is staged in the background
        let first = try await open(door)
        XCTAssertEqual(first.standardizedFileURL, file(v1).standardizedFileURL)
        await Essence2Download.settle()
        XCTAssertEqual(Essence2Download.inFlight.lastOutcome(DoorStoreID.of(dir, key)), .staged)
        XCTAssertEqual(try Data(contentsOf: file(v1)), v1, "the file the session opened never moved")
        XCTAssertFalse(exists(file(v2)), "the new file waits in staging, not beside the live one")
        XCTAssertTrue(exists(meta.appendingPathComponent("staging/\(Self.sha(v2)).imx")))
        XCTAssertTrue(exists(meta.appendingPathComponent(key + ".pending")), "the swap is journalled")
        XCTAssertEqual(door.counts.files, 2)

        // the next open: the door is DOWN, so the swap can only have come from disk
        door.set(.status(503))
        let next = try await open(door)
        XCTAssertEqual(next.standardizedFileURL, file(v2).standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: next), v2)
        XCTAssertFalse(exists(meta.appendingPathComponent(key + ".pending")))
        XCTAssertEqual(door.counts.files, 2, "the swap downloaded nothing")
        await Essence2Download.settle()
    }

    func testAJournalWhoseFileIsGoneIsDroppedAndTheCopyServed() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.serve(v2))
        _ = try await open(door)
        await Essence2Download.settle()
        try FileManager.default.removeItem(at: meta.appendingPathComponent("staging/\(Self.sha(v2)).imx"))
        door.set(.status(503))
        let got = try await open(door)
        XCTAssertEqual(got.standardizedFileURL, file(v1).standardizedFileURL)
        XCTAssertFalse(exists(meta.appendingPathComponent(key + ".pending")))
    }

    // MARK: - the switch, the heal, an old cache, a damaged copy

    func testTheSwitchRestoresTheBlockingCheck() async throws {
        XCTAssertTrue(Essence2Download.revalidateInBackground, "on by default")
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.serve(v2))
        let got = try await open(door, .blocking)
        XCTAssertEqual(got.standardizedFileURL, file(v2).standardizedFileURL, "a change lands on this call")
        door.set(.timeout)
        let kept = try await open(door, .blocking)
        XCTAssertEqual(kept.standardizedFileURL, file(v2).standardizedFileURL, "and a door error keeps the copy")
    }

    func testTheHealsReFetchAsksTheDoorEvenWithACopy() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        door.set(.serve(v2))
        let fresh = try await open(door, .doorFirst)
        XCTAssertEqual(fresh.standardizedFileURL, file(v2).standardizedFileURL)
        door.set(.status(503))
        let now = try await open(door)
        XCTAssertEqual(now.standardizedFileURL, file(v2).standardizedFileURL, "and it is current now")
        await Essence2Download.settle()
        do { _ = try await open(door, .doorFirst); XCTFail("the heal's re-fetch needs the door") } catch {}
    }

    func testA2200CacheAsksTheDoorOnceThenNeverWaits() async throws {
        // a file 2.20.0 downloaded: on disk, named by its sha256, with no record beside it
        try v1.write(to: file(v1))
        let door = Door(.serve(v1))
        let first = try await open(door)
        XCTAssertEqual(first.standardizedFileURL, file(v1).standardizedFileURL)
        XCTAssertEqual(door.counts.files, 0, "the copy was used, nothing downloaded")
        door.set(.status(503))
        let next = try await open(door)
        XCTAssertEqual(next.standardizedFileURL, file(v1).standardizedFileURL)
    }

    func testADamagedCopyIsNeverServed() async throws {
        let door = Door(.serve(v1))
        _ = try await open(door)
        try Data("damaged".utf8).write(to: file(v1))
        door.set(.status(503))
        do { _ = try await open(door); XCTFail("a damaged copy is not a copy") } catch {}
        door.set(.serve(v1))
        let got = try await open(door)
        XCTAssertEqual(try Data(contentsOf: got), v1, "downloaded again")
    }

    // MARK: - backups (2.20.2)

    private func excluded(_ u: URL) throws -> Bool {
        var u = u
        u.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        return try u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    /// What the downloader writes stays out of the user's backups; the directory the app passed
    /// in is not flagged as a whole.
    func testDownloadsAreExcludedFromBackupButNotTheCallersDirectory() async throws {
        let door = Door(.serve(v1))
        let got = try await open(door)
        XCTAssertTrue(try excluded(got), "the downloaded .imx")
        XCTAssertTrue(try excluded(meta), "the .door bookkeeping")
        XCTAssertFalse(try excluded(dir), "the caller's own directory is left as it was")

        // a change staged in the background, then swapped in: the new file is flagged too
        door.set(.serve(v2))
        _ = try await open(door)
        await Essence2Download.settle()
        XCTAssertTrue(try excluded(meta.appendingPathComponent("staging/\(Self.sha(v2)).imx")))
        door.set(.status(503))
        let next = try await open(door)
        XCTAssertEqual(next.standardizedFileURL, file(v2).standardizedFileURL)
        XCTAssertTrue(try excluded(next), "the swapped-in file keeps the flag")
    }

    /// A copy a 2.20.1 cache already holds (written before the flag existed) is flagged on its next open.
    func testAnOlderCopyIsFlaggedOnItsNextOpen() async throws {
        // the 2.20.1 layout, written by hand: the file under its sha256 and the `.door` pointer
        try v1.write(to: file(v1))
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data((Self.sha(v1) + "\n").utf8).write(to: meta.appendingPathComponent(key + ".current"))
        XCTAssertFalse(try excluded(file(v1)), "a copy from before 2.20.2 carries no flag")
        // ★2.20.2 (security): a copy from before 2.20.2 carries no entitlement mark, so its first
        // open asks the door (Essence2KitCrossAccountTests); the door serves the same file, nothing
        // is downloaded, and the copy is served.
        let door = Door(.serve(v1))
        let again = try await open(door)
        XCTAssertEqual(door.counts.files, 0, "the copy was used, nothing downloaded")
        XCTAssertEqual(again.standardizedFileURL, file(v1).standardizedFileURL)
        XCTAssertTrue(try excluded(again), "flagged on its next open")
    }
}

/// The in-flight key the store uses for an avatar in a directory.
enum DoorStoreID {
    static func of(_ dir: URL, _ key: String) -> String { Essence2Download.DoorStore(dir: dir, key: key).id }
}
