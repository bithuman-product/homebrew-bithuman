// transport_protocol.dart — the voice half of Layer 0.
//
// ★WHY. Render has a registry, a descriptor, a capability record and a written
// recipe (`src/engine_protocol.dart` + ARCHITECTURE.md "Recipe: add a 3rd
// engine", which ends "No edits to the other engines, the brain, or the audio
// IO."). Voice had a factory with an `if`: `pickTransport` compared a string to
// the literal `'webrtc'`, and every capability a caller might ask about — can
// this transport mute? does it need the on-device brain? does it run on this
// platform? — lived as a hand-written getter on each class or as a condition
// inside that `if`. Adding a fourth transport meant editing the factory and
// remembering the getters.
//
// This is the same shape, transcribed rather than invented: a typed descriptor
// per transport, a registry in priority order, and one resolver. It carries NO
// factory function — `EngineDescriptor` doesn't either; the making stays in
// `pickTransport` (Dart) exactly as it stays in `EngineRegistry.make` (Swift),
// one branch per id.
//
// ★THE RECORD IS LOAD-BEARING, NOT DECORATIVE. `canMute` IS each transport's
// `canMute` getter, `requiresLocalBrain` and `platforms` ARE the factory's two
// conditions, and `label` is what `pickTransport` writes into the native log so
// a device trace names the transport that was actually chosen. Flip a field and
// the behaviour changes — which is what makes the arms in
// `test/e2e/transport_registry_test.dart` real arms.
//
// Apache-2.0; (c) bitHuman.

/// Typed description of one realtime voice transport — what it is called, what
/// it can do, and where it can run.
class TransportDescriptor {
  /// Canonical id, and the value `BITHUMAN_TRANSPORT` / `transportOverride`
  /// matches on: 'websocket' | 'webrtc' | 'local'.
  final String id;

  /// Additional accepted spellings of [id]. EMPTY on every row today and that
  /// is deliberate: the define has only ever accepted the canonical spelling
  /// (anything else falls through to the default), so inventing synonyms here
  /// would widen a shipped contract to decorate a field. The carrier stays
  /// because a renamed transport needs its old name to keep resolving — the
  /// same reason `kCloudOnlyEngineSlugs` stays empty next door.
  final List<String> aliases;

  /// Human-readable name, written to the native log when this transport is
  /// picked so one device trace says which audio stack owned the session.
  final String label;

  /// Can the UI's mute control actually gate this transport's microphone? A
  /// transport that answers false must have its mute button disabled rather
  /// than lie. Read by the transport's own `canMute`.
  final bool canMute;

  /// Needs a local LLM on disk (a `.gguf` path) — such a transport is never
  /// reachable by name, only by an explicit local-mode request that carries
  /// one. Read by `pickTransport`.
  final bool requiresLocalBrain;

  /// `Platform.operatingSystem` values this transport runs on. EMPTY means
  /// every platform. Read by `pickTransport`.
  final List<String> platforms;

  const TransportDescriptor({
    required this.id,
    this.aliases = const <String>[],
    required this.label,
    required this.canMute,
    this.requiresLocalBrain = false,
    this.platforms = const <String>[],
  });

  /// Match the canonical id or any frozen alias.
  bool matches(String s) => s == id || aliases.contains(s);

  /// True when this transport can run on [operatingSystem]
  /// (`Platform.operatingSystem`).
  bool runsOn(String operatingSystem) =>
      platforms.isEmpty || platforms.contains(operatingSystem);
}

/// WebSocket + the host's own audio unit. THE DEFAULT ON EVERY PLATFORM,
/// Android included: the plugin's native speaker and echo-cancelled mic exist
/// on macOS, iOS and Android alike, and this is the path whose bot PCM the
/// avatar lipsyncs from sample-accurately.
const TransportDescriptor kWebSocketTransport = TransportDescriptor(
  id: 'websocket',
  label: 'WebSocket + native VP-IO audio',
  canMute: true,
);

/// libwebrtc owns mic, speaker and APM; the mouth is fed from the remote track.
/// An explicit A/B opt-in (`BITHUMAN_TRANSPORT=webrtc`) on every platform.
const TransportDescriptor kWebRtcTransport = TransportDescriptor(
  id: 'webrtc',
  label: 'WebRTC (libwebrtc audio)',
  canMute: true,
);

/// The on-device converse brain — no cloud, no OpenAI key. Apple only: the brain
/// binds Apple SpeechAnalyzer for ASR, so off macOS/iOS the factory correctly
/// falls through to a cloud transport.
const TransportDescriptor kLocalConverseTransport = TransportDescriptor(
  id: 'local',
  label: 'on-device converse brain',
  canMute: true,
  requiresLocalBrain: true,
  platforms: <String>['macos', 'ios'],
);

/// The registered transports. A 4th appends one entry here, one `case` in
/// `pickTransport` and one class — see ARCHITECTURE.md "Recipe: add a 3rd
/// transport".
const List<TransportDescriptor> kTransportRegistry = <TransportDescriptor>[
  kLocalConverseTransport,
  kWebRtcTransport,
  kWebSocketTransport,
];

/// What a session gets when nothing else is asked for or reachable.
const TransportDescriptor kDefaultTransport = kWebSocketTransport;

/// Resolve a (possibly aliased) transport name; null when no registered
/// transport answers to it — an unknown name is NOT an error, it takes
/// [kDefaultTransport], because a stale `--dart-define` must not brick a
/// session.
TransportDescriptor? transportDescriptorFor(String name) {
  for (final d in kTransportRegistry) {
    if (d.matches(name)) return d;
  }
  return null;
}
