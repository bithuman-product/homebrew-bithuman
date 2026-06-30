// bithuman_engine_protocol — the Dart half of Layer 0.
//
// `EngineDescriptor` + `kEngineRegistry`: the typed, machine-readable contract
// the app uses to route the gallery and `BithumanAvatar.load(engine:)` by
// descriptor instead of by string literals (design §1.2). The
// `BithumanAvatar.load(path, {engine, motionDir, chunk})` WIRE contract is
// UNCHANGED — the registry only types the call sites and the gallery tabs.
//
// The canonical slugs + aliases here are the FROZEN dual-accept engine slugs
// (`expression2`/`embody`, `essence2`/`elevate`). The registry mirrors the
// Swift `EngineId`/`EngineCapabilities` so a 3rd engine slots in by adding one
// `EngineDescriptor` entry.
//
// CLOUD-API NAMES (added without disturbing the frozen on-device slugs): the
// public REST/cloud taxonomy uses HYPHENATED names — `expression-2`,
// `essence-2-light`, `essence-2-mobile`, `essence-2-quality`. The first three
// map onto an on-device engine and are carried here as ADDITIONAL frozen aliases
// (dual-accept widens to multi-accept; the canonical + the legacy `embody` /
// `elevate` slugs keep matching byte-for-byte). `essence-2-quality` is GPU-ONLY
// — it has NO on-device engine — so it is intentionally NOT an alias of the
// on-device essence2 (light / a2x) engine; it is listed in
// `kCloudOnlyEngineSlugs` so the app RECOGNISES it as a known cloud tier rather
// than a typo, while `engineDescriptorFor` still returns null (there is no
// on-device engine to load for it). See README "EngineId — routing identity".
//
// Apache-2.0; (c) bitHuman.

/// Typed description of an avatar engine — the Dart mirror of the Swift
/// `EngineId` + the load-path-shape bits the app needs to route a card.
class EngineDescriptor {
  /// Canonical slug: 'expression2' | 'essence2' | …
  final String canonical;

  /// Frozen dual-accept aliases: ['embody'] | ['elevate'] | …
  final List<String> aliases;

  /// Human label for the gallery tab: 'Expression 2' | 'Essence 2'.
  final String label;

  /// essence2 = true (loads from a local `.elevatedir`); expression2 = false
  /// (resolves a code → downloads the `.avatar`).
  final bool loadsFromLocalDir;

  /// The avatar manifest ABI this engine requires (matched at install).
  final int engineAbi;

  const EngineDescriptor({
    required this.canonical,
    this.aliases = const <String>[],
    required this.label,
    required this.loadsFromLocalDir,
    required this.engineAbi,
  });

  /// Dual-accept match: the canonical slug OR any frozen alias.
  bool matches(String s) => s == canonical || aliases.contains(s);
}

/// Expression 2 (embody) — pure-Swift/CoreML on-device engine.
/// Aliases: `embody` (legacy on-device slug, FROZEN) + `expression-2` (the
/// cloud/REST-API name for the same engine family).
const EngineDescriptor kExpression2 = EngineDescriptor(
  canonical: 'expression2',
  aliases: <String>['embody', 'expression-2'],
  label: 'Expression 2',
  loadsFromLocalDir: false,
  engineAbi: 1,
);

/// Essence 2 (elevate) — the on-device director-avatar (a2x) engine. This is the
/// on-device leg of the cloud **light** tier, so the cloud names `essence-2-light`
/// and `essence-2-mobile` (the App-Store-facing on-device name) both resolve here.
/// Aliases: `elevate` (legacy on-device slug, FROZEN) + the two cloud light names.
/// NOTE: the cloud `essence-2-quality` tier is GPU-only and has NO on-device
/// engine — it is deliberately absent here (see [kCloudOnlyEngineSlugs]).
const EngineDescriptor kEssence2 = EngineDescriptor(
  canonical: 'essence2',
  aliases: <String>['elevate', 'essence-2-light', 'essence-2-mobile'],
  label: 'Essence 2',
  loadsFromLocalDir: true,
  engineAbi: 2,
);

/// The registered engines, in gallery order. A 3rd engine appends one entry.
const List<EngineDescriptor> kEngineRegistry = <EngineDescriptor>[
  kExpression2,
  kEssence2,
];

/// Cloud-API tier names that the app RECOGNISES but that have NO on-device
/// engine (so [engineDescriptorFor] returns null for them by design). Today
/// this is just the GPU-only `essence-2-quality` tier. Keeping it here lets the
/// app distinguish "known cloud-only tier" from "unknown slug / typo" without
/// pretending the on-device essence2 (light/a2x) engine can serve it.
const Set<String> kCloudOnlyEngineSlugs = <String>{'essence-2-quality'};

/// True for a slug the cloud API serves but the device cannot (no on-device
/// engine). Such a slug must NOT be loaded locally — surface it as cloud-only.
bool isCloudOnlyEngineSlug(String slug) => kCloudOnlyEngineSlugs.contains(slug);

/// Resolve a (possibly aliased) slug to its descriptor; null if unknown OR if
/// the slug names a cloud-only tier (see [kCloudOnlyEngineSlugs]).
EngineDescriptor? engineDescriptorFor(String slug) {
  for (final d in kEngineRegistry) {
    if (d.matches(slug)) return d;
  }
  return null;
}
