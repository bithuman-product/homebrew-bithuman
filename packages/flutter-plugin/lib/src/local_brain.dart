// The on-device brain's shipped defaults: the persona prompts, the model set it
// is measured with, and the attributions their licenses require.
//
// Pure data (no IO): the app owns downloading (see bitHuman Live / jarvis
// `local_models.dart`), this file owns WHAT to download and how to describe it,
// so every app runs the same measured brain.

/// Persona prompts for [LocalConverseTransport.systemPrompt].
///
/// Written for a ~1B on-device model: short, concrete, spoken-style. The brain
/// ALSO enforces two things in code, so they hold even when a small model does
/// not follow the prompt: emoji / markdown / "*actions*" are stripped from the
/// captions and the voice, and a turn that mentions suicide or self-harm is
/// answered with a fixed crisis message (988 / local crisis line) instead of the
/// model, after which the model is told to stay out of character.
class LocalBrainPersona {
  LocalBrainPersona._();

  /// Wise Pup (Expression 2 showcase avatar A23WJF0199).
  static const String wisePup =
      'You are Wise Pup, a friendly and witty cartoon dog who chats with people out loud. '
      'Keep every reply to one or two short, playful sentences meant to be spoken: '
      'no emojis, no lists, no markdown, no actions in asterisks. '
      'Answer questions helpfully, in character. '
      'You are a cartoon dog, never a human, and you never say you are a person. '
      'Stay kind and family-friendly: no romance or flirting, and politely refuse anything '
      'violent, sexual, hateful, illegal or dangerous. '
      'If someone mentions suicide or hurting themselves, drop the act, be caring, and tell '
      'them to call or text 988 in the US or their local crisis line.';
}

/// One file of the on-device brain's model set.
class LocalBrainAsset {
  const LocalBrainAsset(this.remote, this.rel, this.bytes, this.sha256);

  /// Release-asset basename (unique across the set).
  final String remote;

  /// Path relative to the app's converse model root.
  final String rel;

  /// Exact size in bytes (progress + verification).
  final int bytes;

  /// Lowercase-hex SHA-256 of the file; verify before handing it to the brain.
  final String sha256;
}

/// The model set the brain is measured with (libconverse >= 2.4.0):
///
/// * LLM — Llama 3.2 1B Instruct, Q4_K_M GGUF (807.7 MB). Byte-identical to
///   `bartowski/Llama-3.2-1B-Instruct-GGUF` at 067b946c. Chosen over the old
///   Qwen2.5-0.5B for clearly better in-character replies; ~60-80 ms/token
///   budget on iPhone 15 Metal is well inside the reply pacing.
/// * Voice — Supertonic 3, half-precision STORAGE build (200 MB instead of
///   398 MB; compute stays float32 — the brain expands the graphs once on first
///   load). Built by bithuman-models `models/_core/converse/tools/make_fp16_storage.py`
///   from the files the previous set shipped (byte-identical to
///   `supertone-oss-archive/supertonic-3`).
///
/// [releaseTag] names the release these assets are PROPOSED to be published
/// under; until it exists an app must host them itself (see the PR notes).
class LocalBrainModels {
  LocalBrainModels._();

  static const String releaseTag = 'converse-models-v2';
  static const String defaultBaseUrl =
      'https://github.com/bithuman-product/homebrew-bithuman/releases/download/$releaseTag';

  /// Relative path of the GGUF (pass `<root>/$ggufRel` as `ggufPath`).
  static const String ggufRel = 'llama-3.2-1b-instruct-q4_k_m.gguf';

  /// Relative path of the Supertonic assets dir (pass as `supertonicAssets`).
  static const String supertonicRel = 'supertonic-fp16';

  static const List<LocalBrainAsset> assets = [
    LocalBrainAsset('Llama-3.2-1B-Instruct-Q4_K_M.gguf', ggufRel, 807694464,
        '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83'),
    LocalBrainAsset('supertonic3-fp16-vector_estimator.onnx', '$supertonicRel/onnx/vector_estimator.onnx', 128736697,
        '25b6e8e743c46e39224999821493998b1fc9b4e67c1fdb41e0230d44d3c3f78b'),
    LocalBrainAsset('supertonic3-fp16-vocoder.onnx', '$supertonicRel/onnx/vocoder.onnx', 50811658,
        'cefde0e0d2307063d1c18196f0a2762f007e55f2cc59bdb855a0819be4127545'),
    LocalBrainAsset('supertonic3-fp16-text_encoder.onnx', '$supertonicRel/onnx/text_encoder.onnx', 18475630,
        'c6b42b6f2c6aeeb1147a79ee6348fb15c222b3163e9bf2d9eb5b58d3c2a1ccff'),
    LocalBrainAsset('supertonic3-fp16-duration_predictor.onnx', '$supertonicRel/onnx/duration_predictor.onnx', 1994361,
        '3e83b1b27f117ccc3ce0700c28025ca43e280710165fe017ed6da54412f13c18'),
    LocalBrainAsset('tts.json', '$supertonicRel/onnx/tts.json', 8253,
        '42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09'),
    LocalBrainAsset('unicode_indexer.json', '$supertonicRel/onnx/unicode_indexer.json', 277676,
        '9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f'),
    LocalBrainAsset('M1.json', '$supertonicRel/voice_styles/M1.json', 291748,
        'e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b'),
  ];

  /// Total download (bytes) for [assets]: 1,008,290,487 (≈1.01 GB; one voice) vs
  /// 889 MB for the old Qwen-0.5B + fp32 set.
  static int get totalBytes => assets.fold(0, (s, a) => s + a.bytes);
}

/// Attribution + license notices the model licenses require an app to show.
class LocalBrainNotices {
  LocalBrainNotices._();

  /// Llama 3.2 Community License §1.b.i: display "Built with Llama" prominently
  /// on a related website, user interface, blog post, about page or product
  /// documentation of any product that uses it.
  static const String builtWithLlama = 'Built with Llama';

  /// Llama 3.2 Community License §1.b.ii: required notice text.
  static const String llamaNotice =
      'Llama 3.2 is licensed under the Llama 3.2 Community License, '
      'Copyright © Meta Platforms, Inc. All Rights Reserved.';

  /// Where the full license / use policy / model license live (link them from
  /// the app's About / legal screen; Supertonic's OpenRAIL-M use restrictions
  /// must also be part of the end-user terms — OpenRAIL-M §4(a)).
  static const String llamaLicenseUrl = 'https://www.llama.com/llama3_2/license/';
  static const String llamaUsePolicyUrl = 'https://www.llama.com/llama3_2/use-policy/';
  static const String supertonicModelLicenseUrl =
      'https://huggingface.co/supertone-oss-archive/supertonic-3/blob/main/LICENSE';
}
