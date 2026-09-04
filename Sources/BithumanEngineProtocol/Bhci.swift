// Bhci.swift — the COMMON INTERFACE on the macOS/iOS surface (Layer 0).
//
// ★ADDITIVE, AND IT ADDS NO PRODUCT. This file joins the EXISTING
// `BithumanEngineProtocol` target. Package.swift's `products` list is
// deliberately three and no others ("Naming any other is a bug"), and this
// change does not touch it: `swift build` vends exactly `bitHumanKit`,
// `BithumanEngineProtocol` and `Expression2`, as before.
//
// ★AND IT RENAMES NOTHING. `BithumanEngine`, `EngineId`, `EngineCapabilities`,
// `AvatarRef`, `cloudOnlyEngineSlugs`, `isCloudOnlyEngineSlug`, the frozen
// dual-accept slugs `embody` / `elevate`, and the SwiftPM product names are
// FROZEN CARRIERS resolved by exact spelling in a consumer's Package.resolved.
// `Bhci` WRAPS them.
//
// ★WHY A SECOND "COMMON INTERFACE" WHEN THIS FILE ALREADY DECLARES ONE.
// `BithumanEngine` is the common interface for ONE runtime family on ONE
// platform: it is Swift, it is Apple-only, and it answers `EngineId` (which
// model) and `isCloudOnlyEngineSlug` (local or cloud) and NOTHING about the
// target or the borrow. `bhci` is the same five questions asked identically on
// Android, macOS/iOS, Python, web and the CLI, and it is built ON this
// protocol rather than beside it — `Bhci.describe(engine:)` reads `EngineId`
// straight off a live conformer, so the two cannot drift about which model an
// engine is.
//
// ★THE TYPED ABSENCE. expression-2 has NO borrow and NO pasteback. `Borrow` is
// an `enum` with two cases and NO boolean on either, so `state.borrow.verdict`
// does not compile and a `switch` is not exhaustive until the reader has
// written the absence branch. A reader CANNOT express "did it borrow?" as a bit
// that reads `false` for expression-2 — which is the exact conflation this
// estate has made before, and it matters because essence-2 teeth are BORROWED
// from the audio-driven gold teacher and NEVER synthesized.
//
// ★THE PORT, SAID OUT LOUD. `borrowEvaluate` is a PORT of
// `models/essence-2/tools/assert_fleet_borrow_capability.py::evaluate`, the only
// executable definition of the four-condition rule — a shipped xcframework
// cannot import a repo tool. A port is a second transcription, so it is driven
// cell-for-cell against the authority by `tools/bhci_conformance.py`.
//
// ★WHAT THIS FILE DOES NOT CLAIM. The PUBLISHED Apple SDK ships NO engine:
// across all nine slices `libessence` 0, `tessera` 0, `onnxruntime` 0, with
// presence controls hitting in the same run. The iOS borrow works through the
// NATIVE ABI, not through this package. So `Bhci.describe()` reports
// `enginePresent: false` here rather than implying a runtime that is not in
// the box.
//
// Apache-2.0; (c) bitHuman.

import Foundation

public enum Bhci {

    public static let version = "1"
    public static let surface = "macOS-iOS"

    /// The five ruled target names — docs/NAMING.md §6b, owner ruling
    /// 2026-09-03. Spelled exactly, slash and capitals included.
    /// ★`apple` (our moraga serving plane) and `macOS/iOS` (the xcframework a
    /// customer links) are DIFFERENT targets and §6b forbids treating them as
    /// one. This package is `macOS/iOS`.
    public static let targets = ["gpu", "apple", "web", "android", "macOS/iOS"]

    public static let models = [
        "essence-1", "essence-2", "essence-2-max",
        "expression-1", "expression-2", "dream-1",
    ]

    /// Kept in step with `cloudOnlyEngineSlugs` above — same fact, model names
    /// rather than engine slugs.
    public static let cloudOnlyModels = ["essence-2-max", "expression-1"]

    public enum Scope: String { case inScope = "in-scope", notApplicable = "n/a", unruled }
    public enum Locality: String { case local, cloud }

    /// model x target, reduced from `tools/model_scope.py`: a target is
    /// in-scope only when EVERY lane under it is (`macOS/iOS` covers both
    /// apple-macos and apple-ios).
    static let scopeTable: [String: [String: Scope]] = [
        "essence-1":     ["gpu": .inScope, "apple": .inScope, "web": .inScope, "android": .inScope, "macOS/iOS": .inScope],
        "essence-2":     ["gpu": .inScope, "apple": .inScope, "web": .inScope, "android": .inScope, "macOS/iOS": .inScope],
        "essence-2-max": ["gpu": .inScope, "apple": .notApplicable, "web": .notApplicable, "android": .notApplicable, "macOS/iOS": .notApplicable],
        "expression-1":  ["gpu": .inScope, "apple": .notApplicable, "web": .notApplicable, "android": .notApplicable, "macOS/iOS": .notApplicable],
        "expression-2":  ["gpu": .inScope, "apple": .inScope, "web": .inScope, "android": .inScope, "macOS/iOS": .inScope],
        "dream-1":       ["gpu": .unruled, "apple": .unruled, "web": .unruled, "android": .unruled, "macOS/iOS": .unruled],
    ]

    /// Declared engine slug -> model. Every key is a frozen carrier; the
    /// `elevate` / `embody` rows are the SAME dual-accept aliases `EngineId`
    /// carries above, so a slug routes to one model on every surface.
    public static let engineToModel: [String: String] = [
        "essence1": "essence-1",
        "essence2-light": "essence-2", "essence2-golden": "essence-2",
        "essence2": "essence-2", "elevate": "essence-2",
        "essence2-quality": "essence-2-max", "essence2-max": "essence-2-max",
        "expression1": "expression-1",
        "expression2": "expression-2", "embody": "expression-2",
        "dream1": "dream-1",
    ]

    public static let notApplicableWhy =
        "expression-2 has no borrow concept and no pasteback: there is no " +
        "TESSERA bank, no teeth donor and no V6F arm. This is a TYPED ABSENCE, " +
        "not a verdict of false."

    // ------------------------------------------------------------ errors --
    public enum Code: String, CaseIterable {
        case artifactNotFound      = "ARTIFACT_NOT_FOUND"
        case artifactUnreadable    = "ARTIFACT_UNREADABLE"
        case manifestKeyMissing    = "MANIFEST_KEY_MISSING"
        case runtimeAssetMissing   = "RUNTIME_ASSET_MISSING"
        case planeUnavailable      = "PLANE_UNAVAILABLE"
        case modelNotOnTarget      = "MODEL_NOT_ON_TARGET"
        case modelUnruledOnTarget  = "MODEL_UNRULED_ON_TARGET"
        case tesseraMembersMissing = "TESSERA_MEMBERS_MISSING"
        case tesseraMembersInvalid = "TESSERA_MEMBERS_INVALID"
        case borrowUnavailable     = "BORROW_UNAVAILABLE"
        case borrowNotApplicable   = "BORROW_NOT_APPLICABLE"
        case notSignedIn           = "NOT_SIGNED_IN"
        case internalError         = "INTERNAL"

        /// One of the CLI's seven published exit codes {0,1,2,66,69,70,77}.
        /// ★64 is not among them and is never produced.
        public var exit: Int {
            switch self {
            case .artifactNotFound, .artifactUnreadable, .manifestKeyMissing: return 66
            case .runtimeAssetMissing, .planeUnavailable, .modelNotOnTarget,
                 .modelUnruledOnTarget, .tesseraMembersMissing,
                 .tesseraMembersInvalid, .borrowUnavailable: return 69
            case .borrowNotApplicable: return 2
            case .notSignedIn: return 77
            case .internalError: return 70
            }
        }

        /// The code this refusal used to be raised as, kept so nothing that
        /// matches on it breaks. ★Two of these are CORRECTIONS: a missing
        /// manifest key was `TESSERA_MEMBERS_INVALID` (which names the member
        /// set) and a missing runtime asset was `BE_ERR_FILE_CORRUPT` (which
        /// says the customer's file is damaged when it is fine).
        public var legacyCode: String? {
            switch self {
            case .artifactNotFound: return "BE_ERR_FILE_NOT_FOUND"
            case .artifactUnreadable: return "BE_ERR_FILE_CORRUPT"
            case .manifestKeyMissing: return "TESSERA_MEMBERS_INVALID"
            case .runtimeAssetMissing, .planeUnavailable: return "BE_ERR_FILE_CORRUPT"
            case .modelNotOnTarget: return "UNSUPPORTED_MODEL_FAMILY"
            case .modelUnruledOnTarget, .borrowNotApplicable: return nil
            case .tesseraMembersMissing: return "TESSERA_MEMBERS_MISSING"
            case .tesseraMembersInvalid: return "TESSERA_MEMBERS_INVALID"
            case .borrowUnavailable: return "TESSERA_ATTACH_REFUSED"
            case .notSignedIn: return "NOT_SIGNED_IN"
            case .internalError: return "INTERNAL"
            }
        }

        /// The SHAPE of the thing that is wrong. A refusal that could not name
        /// its subject would be the defect this vocabulary exists to end.
        public var subjectKind: String {
            switch self {
            case .artifactNotFound: return "path-or-code"
            case .artifactUnreadable: return "path"
            case .manifestKeyMissing: return "manifest-key"
            case .runtimeAssetMissing: return "asset-name"
            case .planeUnavailable: return "engine-and-target"
            case .modelNotOnTarget, .modelUnruledOnTarget: return "model-and-target"
            case .tesseraMembersMissing: return "member-filenames"
            case .tesseraMembersInvalid: return "member-filename"
            case .borrowUnavailable: return "borrow-condition"
            case .borrowNotApplicable: return "model"
            case .notSignedIn: return "credential"
            case .internalError: return "none"
            }
        }
    }

    public struct BhciError: Error, CustomStringConvertible {
        public let code: Code
        public let subject: String
        public let message: String
        public var exit: Int { code.exit }
        public var legacyCode: String? { code.legacyCode }
        public init(_ code: Code, subject: String, message: String) {
            self.code = code; self.subject = subject; self.message = message
        }
        public var description: String {
            "\(code.rawValue): \(message) (subject: \(subject))"
        }
    }

    // ------------------------------------------------- the borrow SUM TYPE --
    public struct Conditions: Equatable {
        public let membersPresent: Int?
        public let unifiedComposeW0Tap: String?
        public let bankHeadPassthroughStamp: String?
        public let piDeriverInputs: String?
    }

    /// ★Two cases. No boolean on either. `switch` is exhaustive only when the
    /// absence is handled.
    public enum Borrow: Equatable {
        case notApplicable(model: String, why: String)
        case verdict(verdict: String, decidedBy: String, conditions: Conditions)

        public var kind: String {
            switch self {
            case .notApplicable: return "not-applicable"
            case .verdict: return "verdict"
            }
        }
    }

    static func conditionOf(_ v: String) -> String {
        switch v {
        case "CAN-BORROW": return "none \u{2014} all four hold"
        case "PARTIAL-MEMBERS": return "1 members"
        case "TAP-NO-BANK": return "1 members"
        case "PRE-UNIFIED": return "1 members + 2 w0-tap"
        case "ARMS-AND-SYNTHESIZES": return "2 w0-tap"
        case "STAMPED-PASSTHROUGH": return "3 stamp"
        case "PI-UNARMED": return "4 pi-deriver"
        case "NO-DIRECTOR-GRAPH": return "0 director-graph (precondition, not an arming condition)"
        default: return ""
        }
    }

    /// PORT of `assert_fleet_borrow_capability.evaluate`. The order is the
    /// DEPLOYED precedence — unmeasurable outranks everything, the tap outranks
    /// the stamp, the stamp outranks the pi deriver. Do not re-sort.
    public static func borrowEvaluate(
        nMembers: Int, tap: String, stamp: String, pi: String
    ) -> (String, String) {
        if tap == "unmeasurable" || stamp == "unmeasurable" || pi == "unmeasurable" {
            var blind: [String] = []
            if tap == "unmeasurable" { blind.append("2 w0-tap") }
            if stamp == "unmeasurable" { blind.append("3 stamp") }
            if pi == "unmeasurable" { blind.append("4 pi-deriver") }
            return ("UNMEASURABLE", blind.joined(separator: " + ") + " (could not be read)")
        }
        let v: String
        if nMembers > 0 && nMembers < 4 { v = "PARTIAL-MEMBERS" }
        else if tap == "no-graph" { v = "NO-DIRECTOR-GRAPH" }
        else if tap == "tap" {
            if nMembers != 4 { v = "TAP-NO-BANK" }
            else if stamp == "off" { v = "STAMPED-PASSTHROUGH" }
            else if pi != "armed" { v = "PI-UNARMED" }
            else { v = "CAN-BORROW" }
        } else { v = (nMembers == 4) ? "ARMS-AND-SYNTHESIZES" : "PRE-UNIFIED" }
        return (v, conditionOf(v))
    }

    public static func borrowApplicable(_ model: String) -> Bool { model == "essence-2" }

    public static func borrowFor(
        model: String, evidence: (Int, String, String, String)? = nil
    ) -> Borrow {
        guard borrowApplicable(model) else {
            return .notApplicable(model: model, why: notApplicableWhy)
        }
        guard let e = evidence else {
            // ★"I could not look" is NOT "there is nothing to look at".
            let (v, d) = borrowEvaluate(nMembers: 0, tap: "unmeasurable",
                                        stamp: "unmeasurable", pi: "unmeasurable")
            return .verdict(verdict: v, decidedBy: d,
                            conditions: Conditions(membersPresent: nil,
                                                   unifiedComposeW0Tap: nil,
                                                   bankHeadPassthroughStamp: nil,
                                                   piDeriverInputs: nil))
        }
        let (v, d) = borrowEvaluate(nMembers: e.0, tap: e.1, stamp: e.2, pi: e.3)
        return .verdict(verdict: v, decidedBy: d,
                        conditions: Conditions(membersPresent: e.0,
                                               unifiedComposeW0Tap: e.1,
                                               bankHeadPassthroughStamp: e.2,
                                               piDeriverInputs: e.3))
    }

    // -------------------------------------------------------- value types --
    public struct Capability {
        public let model: String
        public let target: String
        public let scope: Scope
        public let locality: Locality
        public let borrowApplicable: Bool
    }

    public struct Artifact {
        public let source: String
        public let model: String
        public let locality: Locality
        public let declaredEngine: String
        public var audioSamples: Int = 0
        public var framesPulled: Int = 0
    }

    public struct State {
        public let model: String
        public let target: String?
        public let locality: Locality
        public let borrow: Borrow
        public let framesPulled: Int
    }

    // --------------------------------------------------------- the verbs --
    /// ★`enginePresent` is FALSE and that is a MEASUREMENT, not a placeholder:
    /// across all nine slices of the published SwiftPM binaries, `libessence`
    /// 0, `tessera` 0, `onnxruntime` 0, with 976 symbols and 141
    /// `ImxContainer` hits as the presence controls in the same run. The
    /// on-device borrow runs through the NATIVE ABI, not through this package.
    public static func describe() -> [String: Any] {
        [
            "bhci": version,
            "surface": surface,
            "target": "macOS/iOS",
            "enginePresent": false,
            "enginePresentNote":
                "the published SwiftPM binaries carry no engine: libessence 0, "
                + "tessera 0, onnxruntime 0 across all nine slices, with "
                + "presence controls hitting in the same run. The iOS borrow "
                + "runs through the native ABI, not this package.",
            "wraps": ["BithumanEngine", "EngineId", "EngineCapabilities",
                      "AvatarRef", "isCloudOnlyEngineSlug"],
        ]
    }

    /// ★Reads `EngineId` off a LIVE conformer rather than re-deriving the
    /// model, so `bhci` and the Layer-0 protocol cannot disagree about which
    /// model an engine is.
    public static func model(of engine: any BithumanEngine) -> String? {
        let id = type(of: engine).id
        for (slug, model) in engineToModel where id.matches(slug) { return model }
        return nil
    }

    public static func capability(model: String, target: String) throws -> Capability {
        guard let row = scopeTable[model] else {
            throw BhciError(.modelNotOnTarget, subject: model,
                            message: "\(model) is not one of the six models")
        }
        guard let sc = row[target] else {
            throw BhciError(.planeUnavailable, subject: target,
                            message: "\(target) is not one of the five targets")
        }
        return Capability(model: model, target: target, scope: sc,
                          locality: cloudOnlyModels.contains(model) ? .cloud : .local,
                          borrowApplicable: borrowApplicable(model))
    }

    /// Create/load. A 10-char upper-alnum agent code is CLOUD; anything else is
    /// a local artifact whose declared engine is READ, never assumed.
    public static func open(source: String, declaredEngine: String?) throws -> Artifact {
        let isCode = source.count == 10
            && source.allSatisfy { $0.isUppercase || $0.isNumber }
            && (source.first?.isLetter ?? false)
        if isCode {
            return Artifact(source: source, model: "", locality: .cloud, declaredEngine: "")
        }
        guard let slug = declaredEngine else {
            throw BhciError(.manifestKeyMissing, subject: "manifest.engine",
                message: "the manifest declares neither `engine` nor the legacy `model_type`")
        }
        guard let m = engineToModel[slug] else {
            throw BhciError(.artifactUnreadable, subject: slug,
                message: "the manifest declares engine '\(slug)', which no bitHuman runtime serves")
        }
        return Artifact(source: source, model: m,
                        locality: cloudOnlyModels.contains(m) ? .cloud : .local,
                        declaredEngine: slug)
    }

    @discardableResult
    public static func attachAudio(_ h: inout Artifact, samples: Int) -> Int {
        h.audioSamples += samples
        return samples
    }

    public static func pull(_ h: inout Artifact) -> [UInt8]? {
        if h.audioSamples == 0 { return nil }
        h.framesPulled += 1
        return nil
    }

    public static func state(
        _ h: Artifact, evidence: (Int, String, String, String)? = nil
    ) -> State {
        State(model: h.model, target: "macOS/iOS", locality: h.locality,
              borrow: borrowFor(model: h.model, evidence: evidence),
              framesPulled: h.framesPulled)
    }
}
