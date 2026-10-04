// The on-device brain's VOICE choice (LOCAL mode, iOS / macOS 26+).
//
// Two voices can speak a local reply:
//
//  * the BUILT-IN voice (Supertonic, [LocalBrainVoice.builtIn]) — the same
//    character voice on every device, but a ~200 MB download
//    ([LocalBrainModels.assets]);
//  * a SYSTEM voice ([LocalBrainVoice.system]) — an Apple Premium or Enhanced
//    voice the user already has. Nothing to download, but the voice depends on
//    what the user installed, so it differs from device to device.
//
// Siri voices are NOT available to apps (Apple does not offer them to
// third-party speech), and no API can download a voice: the user downloads
// Premium / Enhanced voices in Settings ([SystemVoices.downloadSteps],
// [SystemVoices.openSettings]).
//
// Typical start:
//
// ```dart
// final sv = await SystemVoices.query();
// final useSystem = userPrefersDeviceVoice && sv.hasHighQuality;
// if (!useSystem) await downloadBuiltInVoice();   // LocalBrainModels.assets
// final t = LocalConverseTransport(
//   avatar: avatar, ggufPath: gguf,
//   voice: useSystem ? LocalBrainVoice.system : LocalBrainVoice.builtIn,
//   supertonicAssets: useSystem ? null : supertonicDir,
//   systemPrompt: LocalBrainPersona.wisePup);
// ```
//
// With [LocalBrainVoice.system] the plugin falls back to the built-in voice when
// no Premium / Enhanced voice is installed at start; that needs
// `supertonicAssets`, so check [SystemVoices.hasHighQuality] first. The voice
// actually speaking is reported by [LocalConverseTransport.activeVoice].
import 'package:flutter/services.dart';

/// Values for `LocalConverseTransport(voice: …)`.
class LocalBrainVoice {
  LocalBrainVoice._();

  /// The built-in Supertonic character voice (needs its downloaded assets).
  static const String builtIn = 'M1';

  /// The best installed Apple Premium voice, else Enhanced voice, for English.
  /// Falls back to [builtIn] when only the compact default voices exist.
  static const String system = 'system';

  /// A specific Apple voice ([SystemVoiceInfo.id]); honoured whatever its
  /// quality, and replaced by [system]'s pick if it is no longer installed.
  static String systemVoice(String id) => '$system:$id';

  /// True for [system] and [systemVoice] values.
  static bool isSystem(String? voice) =>
      voice != null && (voice == system || voice.startsWith('$system:'));
}

/// One installed Apple voice.
class SystemVoiceInfo {
  const SystemVoiceInfo({
    required this.id,
    required this.name,
    required this.language,
    required this.quality,
    required this.gender,
    required this.personal,
  });

  factory SystemVoiceInfo.fromMap(Map<dynamic, dynamic> m) => SystemVoiceInfo(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        language: m['language'] as String? ?? '',
        quality: m['quality'] as String? ?? 'default',
        gender: m['gender'] as String? ?? 'unspecified',
        personal: m['personal'] as bool? ?? false,
      );

  /// AVSpeechSynthesisVoice identifier (pass to [LocalBrainVoice.systemVoice]).
  final String id;
  final String name;

  /// BCP-47, e.g. "en-US".
  final String language;

  /// "premium" | "enhanced" | "default" (compact).
  final String quality;

  /// "male" | "female" | "unspecified".
  final String gender;

  /// The user's own Personal Voice (listed only after [SystemVoices.requestPersonalVoice]
  /// was granted).
  final bool personal;

  /// Premium or Enhanced: the quality worth speaking a character with.
  bool get isHighQuality => quality == 'premium' || quality == 'enhanced';
}

/// The Apple voices installed on this device (iOS / macOS only; empty elsewhere
/// or with a plugin build that predates system voices).
class SystemVoices {
  const SystemVoices({
    required this.voices,
    required this.bestId,
    required this.personalVoice,
    required this.downloadSteps,
  });

  static const _channel = MethodChannel('ai.bithuman.avatar');

  static const SystemVoices none =
      SystemVoices(voices: [], bestId: null, personalVoice: 'unsupported', downloadSteps: '');

  /// Installed voices for the language, best first (Premium, Enhanced, then the
  /// compact defaults; novelty voices left out).
  final List<SystemVoiceInfo> voices;

  /// What [LocalBrainVoice.system] would pick right now (null = none installed).
  final String? bestId;

  /// Personal Voice access: "authorized" | "denied" | "notDetermined" | "unsupported".
  final String personalVoice;

  /// Where the user downloads a Premium / Enhanced voice (localized per platform).
  final String downloadSteps;

  SystemVoiceInfo? get best {
    for (final v in voices) {
      if (v.id == bestId) return v;
    }
    return null;
  }

  /// A Premium or Enhanced voice is installed: [LocalBrainVoice.system] will
  /// speak with it and the built-in voice need not be downloaded.
  bool get hasHighQuality => bestId != null;

  static Future<SystemVoices> query({String language = 'en'}) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('localSystemVoices', {'language': language});
      if (m == null) return none;
      return SystemVoices(
        voices: [
          for (final v in (m['voices'] as List? ?? const [])) SystemVoiceInfo.fromMap(v as Map),
        ],
        bestId: m['best'] as String?,
        personalVoice: m['personalVoice'] as String? ?? 'unsupported',
        downloadSteps: m['downloadSteps'] as String? ?? '',
      );
    } on MissingPluginException {
      return none;
    }
  }

  /// Ask the user (a system prompt, once) to let this app speak with their
  /// Personal Voice. Returns the new status; when "authorized", their Personal
  /// Voices appear in [query] with [SystemVoiceInfo.personal] (select one by id).
  static Future<String> requestPersonalVoice() async {
    try {
      return await _channel.invokeMethod<String>('localRequestPersonalVoice') ?? 'unsupported';
    } on MissingPluginException {
      return 'unsupported';
    }
  }

  /// Open the closest settings page for downloading a voice. macOS opens
  /// Accessibility → Spoken Content; iOS has no public link into Accessibility
  /// settings, so it opens this app's page in Settings — show [downloadSteps]
  /// alongside. Returns whether a page was opened.
  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('localOpenVoiceSettings') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
