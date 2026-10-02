// Essence2KitHealTests — what `Essence2Engine.create` does when the engine refuses an avatar file
// published before the renderer it carries (2.20.0).
//
// ★WHY. 2.20.0 shipped the heal (#178) with only its pure helpers under test: which files are
// door downloads, the agent code in the engine's sentence, the error's text. The heal itself
// (re-download ONCE, open the fresh file, remove the stale copy only after that open succeeded,
// never touch the app's own file) had never run. `Essence2Engine.openHealing` is that decision
// with the open and the download as parameters, so these tests drive it with scripted opens and a
// local "door", no engine and no network; `create` calls it with the real ones.
//
// The last test opens a REAL out-of-date house bundle with the engine this package links. It
// is opt-in (it opens a metered session: an API secret, the network, active session time), see
// `testARealOutdatedHouseBundleHealsOrIsNamed`.

import XCTest
import Essence2
@testable import Essence2Kit

final class Essence2KitHealTests: XCTestCase {

    /// House avatars only: a real-bundle run never opens a customer's avatar.
    static let house: Set<String> = ["A23KSG5258", "A71PAE2892", "A52DHS2219"]

    /// The engines this package has pinned that predate the refusal (bithuman-models #1763/#1766):
    /// they open an out-of-date file on their older renderer instead of answering -4.
    static let enginesBeforeTheRefusal: Set<String> = ["essence2-v1.15.0", "essence2-v1.15.1", "essence2-v1.15.2", "essence2-v1.15.3"]

    let refusal = "LEGACY REFUSED for identity 'A23KSG5258' (b1_fp32): this bundle carries no "
        + "lip_template.v1.json"

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("essence2kit-heal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - scripted opens and a local door

    /// What the heal asked for, in order.
    final class Calls: @unchecked Sendable {
        var opened: [String] = []
        var fetched: [(code: String, dir: String)] = []
    }

    /// A file named the way the downloader names its files: 64 lowercase hex + ".imx".
    private func downloaded(_ hex: Character, _ body: String) throws -> URL {
        let u = dir.appendingPathComponent(String(repeating: hex, count: 64) + ".imx")
        try Data(body.utf8).write(to: u)
        return u
    }

    private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    private func outdated(_ u: URL, code: String = "A23KSG5258") -> Essence2KitError {
        .identityOutdated(path: u.path, agentCode: code, reason: refusal)
    }

    /// The door: writes the current file beside the stale one, as `Essence2Download.identity` does.
    private func door(_ calls: Calls, serving hex: Character = "b") -> (String, URL) async throws -> URL {
        { code, d in
            calls.fetched.append((code, d.standardizedFileURL.path))
            let f = d.appendingPathComponent(String(repeating: hex, count: 64) + ".imx")
            try Data("current".utf8).write(to: f)
            return f
        }
    }

    // MARK: - the heal

    /// A door download the engine refuses: fetched again ONCE (for the agent the sentence names,
    /// into the same directory), the fresh file opened, and only then the stale copy removed.
    func testARefusedDownloadIsFetchedOnceOpenedAndOnlyThenRemoved() async throws {
        let stale = try downloaded("a", "stale")
        let calls = Calls()
        let got = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in
            calls.opened.append(u.lastPathComponent)
            if u == stale { throw self.outdated(u) }
            XCTAssertTrue(self.exists(stale), "the stale copy is kept while the fresh file opens")
            return u.lastPathComponent
        }, fetchAgain: door(calls))
        XCTAssertEqual(got, String(repeating: "b", count: 64) + ".imx", "the fresh file is what opened")
        XCTAssertEqual(calls.opened, [stale.lastPathComponent, got], "two opens: the stale file, then the fresh one")
        XCTAssertEqual(calls.fetched.count, 1, "fetched again exactly once")
        XCTAssertEqual(calls.fetched.first?.code, "A23KSG5258")
        XCTAssertEqual(calls.fetched.first?.dir, dir.standardizedFileURL.path, "into the downloader's own directory")
        XCTAssertFalse(exists(stale), "the stale copy is removed after the fresh file opened")
        XCTAssertTrue(exists(dir.appendingPathComponent(got)))
    }

    /// The fresh file is refused too: that refusal is final — no second download, no third open,
    /// and the stale copy stays (nothing opened, so nothing replaced it).
    func testAFreshFileThatIsRefusedTooIsNotFetchedAgain() async throws {
        let stale = try downloaded("a", "stale")
        let calls = Calls()
        do {
            _ = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in
                calls.opened.append(u.lastPathComponent)
                throw self.outdated(u)
            }, fetchAgain: door(calls))
            XCTFail("an open that is refused twice must throw")
        } catch Essence2KitError.identityOutdated(let path, let code, _) {
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, String(repeating: "b", count: 64) + ".imx",
                           "the refusal names the file that was opened last")
            XCTAssertEqual(code, "A23KSG5258")
        }
        XCTAssertEqual(calls.opened.count, 2)
        XCTAssertEqual(calls.fetched.count, 1)
        XCTAssertTrue(exists(stale))
    }

    /// The door hands back the same bytes (same sha256, so the same file): nothing to heal with.
    func testTheDoorServingTheSameFileIsNotAHeal() async throws {
        let stale = try downloaded("a", "stale")
        let calls = Calls()
        do {
            _ = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in
                calls.opened.append(u.lastPathComponent); throw self.outdated(u)
            }, fetchAgain: { code, d in
                calls.fetched.append((code, d.path)); return stale
            })
            XCTFail("the same file must not be opened again")
        } catch Essence2KitError.identityOutdated(let path, _, _) {
            XCTAssertEqual(path, stale.path)
        }
        XCTAssertEqual(calls.opened.count, 1, "the refused file is never retried")
        XCTAssertEqual(calls.fetched.count, 1)
        XCTAssertTrue(exists(stale))
    }

    /// The download fails: the developer gets the refusal (agent + fix), not the network error,
    /// and the stale copy stays.
    func testAFailedDownloadKeepsTheRefusal() async throws {
        let stale = try downloaded("a", "stale")
        let calls = Calls()
        do {
            _ = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in
                calls.opened.append(u.lastPathComponent); throw self.outdated(u)
            }, fetchAgain: { code, d in
                calls.fetched.append((code, d.path))
                throw Essence2KitError.resourcesUnavailable("A23KSG5258: the download door answered HTTP 503")
            })
            XCTFail("a failed download must throw")
        } catch Essence2KitError.identityOutdated(let path, let code, let reason) {
            XCTAssertEqual(path, stale.path)
            XCTAssertEqual(code, "A23KSG5258")
            XCTAssertEqual(reason, refusal)
        }
        XCTAssertEqual(calls.opened.count, 1)
        XCTAssertTrue(exists(stale))
    }

    /// A file the app keeps (any name the downloader does not write) is never downloaded again or
    /// removed: the app gets `identityOutdated`, naming the agent and the fix.
    func testTheAppsOwnFileIsNeverFetchedAgain() async throws {
        let own = dir.appendingPathComponent("A23KSG5258.imx")
        try Data("the app's".utf8).write(to: own)
        do {
            _ = try await Essence2Engine.openHealing(identity: own, open: { u -> String in throw self.outdated(u) },
                                                     fetchAgain: { _, _ in XCTFail("the app's own file was fetched again"); return own })
            XCTFail("must throw")
        } catch Essence2KitError.identityOutdated(let path, let code, _) {
            XCTAssertEqual(path, own.path)
            XCTAssertEqual(code, "A23KSG5258")
        }
        XCTAssertTrue(exists(own))
    }

    /// A refusal whose sentence names no agent cannot be fetched again, even for a door download.
    func testARefusalNamingNoAgentIsNotFetched() async throws {
        let stale = try downloaded("a", "stale")
        do {
            _ = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in throw self.outdated(u, code: "") },
                                                     fetchAgain: { _, _ in XCTFail("fetched without an agent code"); return stale })
            XCTFail("must throw")
        } catch Essence2KitError.identityOutdated(_, let code, _) {
            XCTAssertEqual(code, "")
        }
        XCTAssertTrue(exists(stale))
    }

    /// Every other refusal passes through untouched, and fetches nothing.
    func testOtherRefusalsReachTheAppUntouched() async throws {
        let stale = try downloaded("a", "stale")
        let cases: [Essence2KitError] = [.identityUnreadable(path: stale.path),
                                         .meteringRefused(reason: "refusing to serve: no API secret was found"),
                                         .notReady(seconds: 1)]
        for e in cases {
            do {
                _ = try await Essence2Engine.openHealing(identity: stale, open: { _ -> String in throw e },
                                                         fetchAgain: { _, _ in XCTFail("fetched on \(e)"); return stale })
                XCTFail("must throw \(e)")
            } catch let got as Essence2KitError {
                XCTAssertEqual(got.description, e.description)
            }
        }
        XCTAssertTrue(exists(stale))
    }

    /// The fresh file fails to open for another reason (here: not ready in time): that error
    /// reaches the app and the stale copy stays.
    func testAFreshOpenThatFailsOtherwiseKeepsTheStaleCopy() async throws {
        let stale = try downloaded("a", "stale")
        let calls = Calls()
        do {
            _ = try await Essence2Engine.openHealing(identity: stale, open: { u -> String in
                calls.opened.append(u.lastPathComponent)
                if u == stale { throw self.outdated(u) }
                throw Essence2KitError.notReady(seconds: 300)
            }, fetchAgain: door(calls))
            XCTFail("must throw")
        } catch Essence2KitError.notReady(let s) {
            XCTAssertEqual(s, 300)
        }
        XCTAssertEqual(calls.opened.count, 2)
        XCTAssertEqual(calls.fetched.count, 1)
        XCTAssertTrue(exists(stale))
    }

    // MARK: - a real out-of-date house bundle, the engine this package links

    /// ★OPT-IN, because it opens a real, METERED session (`be_essence2_create` arms metering before
    /// it reads the file: no API secret is -3, and the session bills active time to the secret's
    /// account). Run it on a Mac (M3 or newer, macOS 26) with:
    ///
    ///     ESSENCE2KIT_OUTDATED_IDENTITY=<a house avatar file published before the 2026-10-01 fix>
    ///     ESSENCE2KIT_AGENT=<its code: A23KSG5258 | A71PAE2892 | A52DHS2219>
    ///     ESSENCE2KIT_CURRENT_IDENTITY=<the same avatar's current file, served by a local "door">
    ///     BITHUMAN_API_SECRET=<a house secret>
    ///     [ESSENCE2KIT_RESOURCES=<the engine's runtime files; else fetched from the pinned release>]
    ///     swift test --filter Essence2KitHealTests/testARealOutdatedHouseBundleHealsOrIsNamed
    ///
    /// The outdated file is opened as the downloader keeps it (named by its sha256; a link, so the
    /// fixture survives the heal's removal), through `create` with a local door. Passing outcomes:
    ///   - HEALED: refused (-4), fetched once, the current file opened, the stale link removed;
    ///   - NAMED: `identityOutdated` for the house agent with the engine's sentence;
    ///   - OPENED AS-IS: only for an engine in `enginesBeforeTheRefusal`, which opens the file on
    ///     its older renderer and never answers -4 (an engine pinned after the refusal must heal
    ///     or name).
    /// Each opened session must render SPEECH frames for audio fed to it: an idle-only session
    /// fails. Any other error (identityUnreadable, notReady) or a crash fails.
    func testARealOutdatedHouseBundleHealsOrIsNamed() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stalePath = env["ESSENCE2KIT_OUTDATED_IDENTITY"], !stalePath.isEmpty else {
            throw XCTSkip("opt-in: set ESSENCE2KIT_OUTDATED_IDENTITY, ESSENCE2KIT_AGENT, "
                          + "ESSENCE2KIT_CURRENT_IDENTITY and BITHUMAN_API_SECRET (a metered session)")
        }
        guard let code = env["ESSENCE2KIT_AGENT"], Self.house.contains(code) else {
            return XCTFail("ESSENCE2KIT_AGENT must be a house avatar (\(Self.house.sorted())): never a customer's")
        }
        guard env["BITHUMAN_API_SECRET"].map({ !$0.isEmpty }) == true else {
            throw XCTSkip("BITHUMAN_API_SECRET is required: the engine meters the session before it reads the file")
        }
        let current = env["ESSENCE2KIT_CURRENT_IDENTITY"].map { URL(fileURLWithPath: $0) }
        let resources = env["ESSENCE2KIT_RESOURCES"].map { URL(fileURLWithPath: $0, isDirectory: true) }

        let src = URL(fileURLWithPath: stalePath)
        let stale = dir.appendingPathComponent(try Essence2Resources.sha256(of: src) + ".imx")
        try FileManager.default.createSymbolicLink(at: stale, withDestinationURL: src)
        XCTAssertTrue(Essence2Download.isDownloaded(stale))

        let calls = Calls()
        let outcome: String
        do {
            let engine = try await Essence2Engine.create(
                identity: stale, resourcesDirectory: resources, readyTimeout: 180,
                fetchAgain: { agent, d in
                    calls.fetched.append((agent, d.path))
                    guard let current else {
                        throw Essence2KitError.resourcesUnavailable("no ESSENCE2KIT_CURRENT_IDENTITY to serve")
                    }
                    let f = d.appendingPathComponent(try Essence2Resources.sha256(of: current) + ".imx")
                    try FileManager.default.createSymbolicLink(at: f, withDestinationURL: current)
                    return f
                })
            defer { engine.shutdown() }
            XCTAssertTrue(engine.isReady)
            XCTAssertGreaterThan(engine.width * engine.height, 0)

            // Not an idle-only session: audio in, speech frames out.
            engine.pacing = .unpaced
            engine.feed((0..<16_000).map { i in
                let t = Float(i) / 16_000
                return 0.3 * sinf(2 * .pi * 180 * t) * (0.5 + 0.5 * sinf(2 * .pi * 4 * t))
            })
            engine.flushTail()
            var speech = 0, idle = 0
            let t0 = Date()
            while speech == 0, Date().timeIntervalSince(t0) < 20 {
                if let f = engine.pull() { if f.speech { speech += 1 } else { idle += 1 } }
                else { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            XCTAssertGreaterThan(speech, 0, "1 s of audio produced no speech frame in 20 s (\(idle) idle frames): an idle-only session")

            if calls.fetched.isEmpty {
                XCTAssertTrue(Self.enginesBeforeTheRefusal.contains(Essence2Resources.releaseTag),
                              "\(Essence2Resources.releaseTag) carries the refusal, yet opened an out-of-date file as-is")
                XCTAssertTrue(exists(stale), "nothing healed, nothing removed")
                outcome = "OPENED AS-IS by \(Essence2Resources.releaseTag) (no -4: this engine predates the refusal); "
                    + "nothing fetched; \(speech) speech frame(s) after \(idle) idle"
            } else {
                XCTAssertEqual(calls.fetched.map { $0.code }, [code], "fetched once, for the house agent")
                XCTAssertFalse(exists(stale), "the stale copy is removed after the current file opened")
                outcome = "HEALED: refused, fetched \(code) once, the current file opened; \(speech) speech frame(s)"
            }
        } catch Essence2KitError.identityOutdated(let path, let agent, let reason) {
            XCTAssertEqual(agent, code, "the refusal names the house agent")
            XCTAssertTrue(reason.contains("LEGACY") && reason.contains("REFUSED"), reason)
            XCTAssertLessThanOrEqual(calls.fetched.count, 1, "fetched at most once")
            outcome = "NAMED: identityOutdated(\(agent)) for \(URL(fileURLWithPath: path).lastPathComponent): \(reason)"
        }
        print("[essence2kit-heal] \(code) \(Essence2Resources.releaseTag): \(outcome)")
    }
}
