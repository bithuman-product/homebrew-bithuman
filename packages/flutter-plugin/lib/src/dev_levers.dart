import 'package:flutter/foundation.dart' show kReleaseMode;

/// DEV LEVERS — every `--dart-define` that can steer this plugin, declared in ONE
/// place, and a RELEASE build reads none of them.
///
/// Each lever is `enabled && …` / `enabled ? … : …` where `enabled` is
/// `!kReleaseMode`, a compile-time constant (`kReleaseMode` is
/// `bool.fromEnvironment('dart.vm.product')`). In `flutter build … --release` the
/// whole expression folds to `false` / `''` and the define's VALUE never enters the
/// AOT snapshot — the release arm in CI builds with every lever set to a sentinel
/// and asserts the sentinel is absent from `libapp.so`. Debug and profile builds
/// keep every lever.
///
/// Why (2026-09-16): a proof build carrying `BITHUMAN_DEV_STRESS=true` (60 s
/// monologues, no user input) and `BH_MIC_FILE` (a recorded voice injected into the
/// mic every reply) sat on the owner's phone as a release APK — "the agent starts
/// self talking non-stop". A dev lever a release build honours is a customer defect.
/// The same rule holds on Android (`FLAG_DEBUGGABLE`, #41) and in the plugin's Swift
/// (`DevLevers.swift`, `#if DEBUG`).
///
/// `scripts/check_dev_levers.sh` refuses any `fromEnvironment(` in `lib/` outside
/// this file, and any lever here that is not guarded by [enabled].
class DevLevers {
  DevLevers._();

  /// True in debug and profile builds; false in every release build.
  static const bool enabled = !kReleaseMode;

  /// Stress driver: request a ~60 s monologue after every `response.done`, so the
  /// run is continuous agent speech with zero user input (both transports).
  static const bool stress =
      enabled && bool.fromEnvironment('BITHUMAN_DEV_STRESS');

  /// WebRTC path: the agent greets unprompted on data-channel open (a full-path
  /// health check; the product rule is that the agent never speaks unprompted).
  static const bool greeting =
      enabled && bool.fromEnvironment('BITHUMAN_DEV_GREETING');

  /// Interruption proof: a raw 24 kHz PCM16 asset of the host app (or an absolute file
  /// path) mixed into the mic stream 6 s into every reply — a synthetic cut-in with a
  /// known onset.
  static const String micFile =
      enabled ? String.fromEnvironment('BH_MIC_FILE') : '';

  /// With [micFile]: mix it in ONCE per session instead, when this many milliseconds of the
  /// first reply have been HEARD (the host's playout) — a person talking over the
  /// character, at a known point of its voice. -1 (unset) = the stress-driver schedule.
  static const int micInjectAtMs =
      enabled ? int.fromEnvironment('BH_MIC_INJECT_AT_MS', defaultValue: -1) : -1;

  /// Echo-onset guard A/B (`BithumanRealtimeSession.echoOnsetGuard`): milliseconds of
  /// agent audio the guard covers; 0 turns it off. -1 (unset) = the session's own value.
  static const int echoGuardMs =
      enabled ? int.fromEnvironment('BH_ECHO_GUARD_MS', defaultValue: -1) : -1;

  /// Audio dump (diagnostics): a directory the realtime session writes the microphone
  /// chunks (as captured), the agent's audio (as handed to the host) and an index of
  /// both, with playout reports and barge events, to. Empty = off.
  static const String audioDump =
      enabled ? String.fromEnvironment('BH_AUDIO_DUMP') : '';

  /// Barge gate A/B (`BithumanRealtimeSession.bargeFloorDb`): the floor in dB under the voice
  /// heard; under -40 turns the gate off. 0 (unset) = the session's own value.
  static const int bargeFloorDb =
      enabled ? int.fromEnvironment('BH_BARGE_FLOOR_DB', defaultValue: 0) : 0;

  /// Dial a mock realtime server instead of OpenAI (integration tests).
  static const String wsUrl =
      enabled ? String.fromEnvironment('BITHUMAN_REALTIME_WS_URL') : '';

  /// Route the macOS / iOS cloud session over WebRTC instead of WebSocket + VP-IO
  /// (an A/B knob, never shipped behaviour).
  static const String transport =
      enabled ? String.fromEnvironment('BITHUMAN_TRANSPORT') : '';
}
