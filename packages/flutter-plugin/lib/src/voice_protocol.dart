// bithuman_voice_protocol — the Dart half of the VOICE layer's Layer 0.
//
// This file exists to turn ONE import edge around. Until it landed, the voice
// layer imported the render layer: `bithuman_realtime.dart` and
// `realtime_transport.dart` both did `import 'package:bithuman/bithuman.dart'`
// for one reason only — four constructors took `required BithumanAvatar avatar`.
// That made "test the conversation" mean "first build an avatar", which is the
// opposite of what the layering is for, and it is why the transport-routing
// contract in the product app's own `transport_pick_test.dart` is written
// `skip: !Platform.isMacOS` and has never graded a thing on CI.
//
// Nothing in the voice layer ever wanted a TEXTURE. Read the 14 call sites and
// what they ask of `avatar` is an audio port: start/stop the echo-cancelled
// audio unit, hand it the agent's PCM, take the mic back, cut the agent off,
// and — in LOCAL mode — run the on-device brain and listen to its events. So
// the port is what the voice layer declares, and the render layer implements
// it: `BithumanAvatar implements VoiceAudioPort`. The edge now points
// render → voice, and `flutter test` can drive a whole conversation with no
// engine, no texture and no device.
//
// ★TRANSCRIBED, NOT INVENTED. The shape is `src/engine_protocol.dart`'s, which
// the render layer has had all along: a typed descriptor, a const registry in
// priority order, and one resolver function — so "add a 3rd engine" is a data
// edit with a written recipe (ARCHITECTURE.md "Recipe: add a 3rd engine",
// ending "No edits to the other engines, the brain, or the audio IO"). Voice
// had a factory with an if. `TransportDescriptor` + `kTransportRegistry` +
// [pickTransportDescriptor] below are that same shape for transports, and the
// recipe for a 3rd transport is in ARCHITECTURE.md beside the engine one.
//
// Apache-2.0; (c) bitHuman.

import 'dart:typed_data' show Uint8List;

/// The audio surface a realtime transport drives.
///
/// This is the whole of what the voice layer needs from the thing it used to
/// call `avatar`. Every member is already implemented by `BithumanAvatar`
/// (one native method-channel call each) — the type simply names the subset,
/// so a transport can be handed a stand-in that is not an avatar at all.
///
/// Three groups, and a transport uses one or two of them, never all three:
///   - **session** — [audioStart] / [audioStop] / [micStream] /
///     [playSpeakerPCM] / [notifyTurnEnd]: our own audio unit owns mic AND
///     speaker, so the platform AEC references our own playout and the
///     speaker and the lipsync drain from one buffer on one clock.
///   - **local brain** — [localAudioStart] / [localAudioStop] /
///     [localPushText] / [localSetMuted] / [converseEvents]: the on-device
///     path, where the native side owns the turn and reports it as events.
///   - **always** — [interrupt] (barge-in) and [nativeLog] (one log stream,
///     one clock, which is the only place a release build's transport events
///     are readable at all).
///
/// [attachWebrtcRemoteAudio] / [detachWebrtcRemoteAudio] serve the WebRTC A/B
/// path, where libwebrtc owns the audio and the port is asked only to lipsync
/// from the remote track.
///
/// A port implementation may make any member a no-op; a transport must not
/// assume a member did anything, because on some platforms it does not.
abstract class VoiceAudioPort {
  /// Bring up the echo-cancelled audio unit that owns mic + speaker.
  /// Must have completed before [playSpeakerPCM] or [micStream] carry data.
  Future<void> audioStart({
    int vadThreshold = 0,
    bool enableMic = true,
    bool vpioAgc = true,
  });

  /// Tear the audio unit down. Pending speaker buffers are discarded.
  Future<void> audioStop();

  /// Echo-cancelled mic capture, 24 kHz mono PCM16. Yields only between
  /// [audioStart] and [audioStop].
  Stream<Uint8List> get micStream;

  /// Play 24 kHz mono PCM16 agent audio and drive the mouth from the same
  /// bytes, on one clock.
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le);

  /// The agent's turn is over — flush the final partial lipsync chunk so the
  /// last word is not clipped. Only after every byte of the turn has been
  /// handed to [playSpeakerPCM], and never after a barge.
  Future<void> notifyTurnEnd();

  /// Cut the agent off mid-sentence: drop the scheduled speaker buffers and
  /// wipe the lipsync queue. Called the instant the user opens their mouth.
  Future<void> interrupt({String reason = 'app'});

  /// Write one line into the NATIVE log stream, beside the presenter's own.
  Future<void> nativeLog(String line);

  /// Lipsync from a remote WebRTC audio track instead of from
  /// [playSpeakerPCM] (the WebRTC A/B path only).
  Future<void> attachWebrtcRemoteAudio(String trackId);

  /// Reverse of [attachWebrtcRemoteAudio]; also flushes in-flight lipsync.
  Future<void> detachWebrtcRemoteAudio();

  /// LOCAL mode: run the on-device brain instead of a cloud session.
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold = 0,
    String systemPrompt = '',
  });

  /// LOCAL mode: tear the on-device brain + audio unit down.
  Future<void> localAudioStop();

  /// LOCAL mode: feed a typed user message in as if it had been spoken. Barges
  /// an in-flight reply.
  Future<void> localPushText(String text);

  /// LOCAL mode: gate the mic → brain forward. Speaker and mouth untouched.
  Future<void> localSetMuted(bool muted);

  /// LOCAL mode: the brain's own events — `{"kind":"state","state":int}`,
  /// `{"kind":"bot"|"user","text":String}`, `mic_level`, `bot_level`,
  /// `loading`, `ready`, `error`.
  Stream<Map<dynamic, dynamic>> get converseEvents;
}

/// Everything the transport choice depends on, as one value.
///
/// ★THE PLATFORM READ MOVED TO THE EDGE. The decision used to read
/// `Platform.isMacOS` from inside the factory, which is why the only test of
/// it anywhere is skipped off a Mac — a routing contract that names four
/// outcomes could be graded on exactly one of them. Here the platform arrives
/// as a field with a default taken from `Platform` at the one call site, so
/// the table below is gradeable for every target from any machine, which is
/// the point of having a table.
class TransportRequest {
  const TransportRequest({
    required this.localMode,
    required this.hasLocalBrain,
    required this.platformHasLocalBrain,
    this.override = '',
  });

  /// The app asked for the on-device brain.
  final bool localMode;

  /// A local brain model path was actually supplied (non-empty).
  final bool hasLocalBrain;

  /// This OS can run the on-device brain at all.
  final bool platformHasLocalBrain;

  /// `--dart-define=BITHUMAN_TRANSPORT` (or the test injection), lower-cased.
  /// An unrecognised value selects nothing and falls through to the default —
  /// it is not an error.
  final String override;
}

/// What a transport IS, as data rather than as a paragraph.
///
/// The capability fields are the machine-readable half of what
/// `realtime_transport.dart`'s factory used to assert in prose. Prose about
/// which platform barges how went wrong once already and stood for months
/// (see the note above [pickTransportDescriptor]); a field can be asserted.
class TransportDescriptor {
  const TransportDescriptor({
    required this.slug,
    required this.label,
    required this.selects,
    required this.usesNativeAudioUnit,
    required this.drivesLipsyncFromPcm,
    required this.needsApiKey,
    required this.canMute,
  });

  /// Stable identity: 'local' | 'webrtc' | 'websocket'.
  final String slug;

  /// Human label for a status line / an A/B report.
  final String label;

  /// Does this transport serve that request? Evaluated in registry order;
  /// the first true wins, so the last entry must be unconditional.
  final bool Function(TransportRequest request) selects;

  /// Our own audio unit owns mic + speaker (so the AEC reference is our own
  /// playout). False = a vendor stack owns the audio.
  final bool usesNativeAudioUnit;

  /// The mouth is driven by PCM this transport hands to the port. False = the
  /// mouth is driven from a track the port was pointed at instead.
  final bool drivesLipsyncFromPcm;

  /// A cloud credential is required to open a session.
  final bool needsApiKey;

  /// Mic mute is actually wired, so the UI's mute control does not lie. This
  /// field must equal the built transport's `canMute` — a test asserts it.
  final bool canMute;
}

bool _selectsLocal(TransportRequest r) =>
    r.localMode && r.platformHasLocalBrain && r.hasLocalBrain;

bool _selectsWebrtc(TransportRequest r) => r.override == 'webrtc';

bool _selectsDefault(TransportRequest r) => true;

/// LOCAL mode: the on-device brain via the plugin, no cloud. Checked FIRST, so
/// local mode wins over the A/B override — the behaviour the product app's
/// `transport_pick_test.dart` names and (being Mac-skipped) never graded.
const TransportDescriptor kLocalConverseTransport = TransportDescriptor(
  slug: 'local',
  label: 'On-device',
  selects: _selectsLocal,
  usesNativeAudioUnit: true,
  drivesLipsyncFromPcm: false, // the native brain feeds the mouth directly
  needsApiKey: false,
  canMute: true,
);

/// The libwebrtc cloud path — an explicit A/B opt-in, never shipped default.
const TransportDescriptor kWebrtcTransport = TransportDescriptor(
  slug: 'webrtc',
  label: 'Cloud (WebRTC)',
  selects: _selectsWebrtc,
  usesNativeAudioUnit: false, // libwebrtc's APM owns mic + speaker
  drivesLipsyncFromPcm: false, // lipsync taps the remote track instead
  needsApiKey: true,
  canMute: true,
);

/// The shipped cloud path on EVERY target — Android, iOS and macOS. The
/// unconditional tail of the registry.
///
/// ★ANDROID TAKES THIS ONE, AND THE FACTORY'S OWN DOCSTRING SAID OTHERWISE FOR
/// MONTHS. It claimed Android *must* take the WebRTC branch because the Android
/// plugin stubbed the native audio surface — three lines above the
/// `return WebSocketTransport(...)` Android had been taking. `BithumanPlugin.kt`
/// implements `audioStart` (it opens the mic EventChannel), `playSpeakerPCM` and
/// `interrupt`, and `MicCapture.kt` captures on VOICE_COMMUNICATION with the
/// platform AEC in MODE_IN_COMMUNICATION — the configuration `EchoProfile.android`
/// is measured against.
///
/// Proved the way an adoption claim has to be, off the device's own log rather
/// than off a branch: `[bhttfa] first delta` and `[bhdeliver]` are emitted by
/// `bithuman_realtime.dart` and by nothing else, and Android's graded
/// conversation run (`conversation_android.normalized.log`, the one
/// `EchoProfile.android` cites) carries 52 of each and zero `[webrtc]` lines.
/// One voice interaction model on every target: `server_vad`, the same event
/// handler, everywhere.
const TransportDescriptor kWebSocketTransport = TransportDescriptor(
  slug: 'websocket',
  label: 'Cloud',
  selects: _selectsDefault,
  usesNativeAudioUnit: true,
  drivesLipsyncFromPcm: true,
  needsApiKey: true,
  canMute: true,
);

/// The registered transports, in decision order. A 3rd transport appends one
/// entry (before the unconditional tail) and one `case` in `pickTransport`.
const List<TransportDescriptor> kTransportRegistry = <TransportDescriptor>[
  kLocalConverseTransport,
  kWebrtcTransport,
  kWebSocketTransport,
];

/// Resolve a request to the transport that serves it.
///
/// ★ONE VOICE INTERACTION MODEL ON EVERY TARGET, AND THIS IS WHERE THAT IS
/// TRUE OR FALSE. The factory this replaces carried a long paragraph asserting
/// that Android *must* take the WebRTC branch because the Android plugin
/// stubbed the native audio surface. That was false, sat three lines above a
/// `return WebSocketTransport(...)` Android had been taking for some time, and
/// a reader auditing "does every target barge the same way?" who believed it
/// would have gone looking for a second implementation to unify. There is one:
/// `server_vad`, the same event handler, everywhere.
///
/// Returns the first descriptor whose `selects` accepts [request]; the last
/// registry entry is unconditional, so this never fails.
TransportDescriptor pickTransportDescriptor(TransportRequest request) {
  for (final d in kTransportRegistry) {
    if (d.selects(request)) return d;
  }
  // Unreachable while the registry ends in an unconditional entry — which
  // `transport_registry_test.dart` asserts rather than trusting.
  return kWebSocketTransport;
}

/// Resolve a (possibly aliased) slug to its descriptor; null if unknown.
TransportDescriptor? transportDescriptorFor(String slug) {
  for (final d in kTransportRegistry) {
    if (d.slug == slug) return d;
  }
  return null;
}
