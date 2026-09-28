# bithuman — the avatar umbrella Flutter plugin (Layer 2)

The **single Flutter dependency** the bitHuman avatar app consumes
(`bithuman-app` git-deps this repo). It is engine-agnostic glue — a `Texture`
widget + the method channel `ai.bithuman.avatar` + `RealtimeAudioIO`/`Converse*`
(OpenAI Realtime + on-device brain) — and it **statically aggregates N avatar
engine SDKs** under INVARIANT #1. macOS (Apple Silicon); iOS is cloud-only.

**Apple platforms (2.6.21):** the pod needs **iOS 16.0** and **macOS 13.0** (Apple silicon). A new
`flutter create` app targets lower, so raise both before `pod install`: `platform :ios, '16.0'` in
`ios/Podfile`, `platform :osx, '13.0'` in `macos/Podfile`, and the Runner targets' deployment
versions to match. Run `scripts/bootstrap.sh` once in the plugin checkout first: it fetches the
published engines (sha256-checked) into the pod, and on macOS the `EngineCore` static library
they link against (2.6.21).

> **This is Layer 2 of the `engine → sdk → app` architecture.** For the full,
> canonical map — both engines, all of their serving tiers, the bootstrap chain,
> the podspec mechanics, and the exact recipe to add a 3rd engine — read
> **[`ARCHITECTURE.md`](ARCHITECTURE.md)**. The governing design (status: BUILT,
> M0–M4) is `unified_architecture_design.md`.

Extracted in **M2** from `expression-2/sdk` (which was the umbrella in the
Phase-4 asymmetric layout) to its own repo so the umbrella belongs to **neither**
engine. The engines are now symmetric Layer-1 SDKs in their own repos, staged
here by `scripts/bootstrap.sh`'s N-engine loop:

- **expression2** — pure-Swift/CoreML, **SOURCE-ONLY** — from
  [`models/expression-2/sdk`](https://github.com/bithuman-product/bithuman-models/tree/main/models/expression-2/sdk) in the `bithuman-models` engine monorepo (**REQUIRED**, the default engine).
- **essence2** — the `be_essence2_*` C ABI as a plain static
  `libessence2.a` — from [`models/essence-2/sdk`](https://github.com/bithuman-product/bithuman-models/tree/main/models/essence-2/sdk) (**OPTIONAL**; a missing SDK / download degrades to expression-2-only via the `ESSENCE2_AVAILABLE` gate).

The shared engine interface (`BithumanEngine`) + the Dart registry
(`EngineDescriptor`/`kEngineRegistry`) come from Layer-0
[`BithumanEngineProtocol`](https://github.com/bithuman-product/homebrew-bithuman/tree/main/Sources/BithumanEngineProtocol)
(staged in-module as `shared/Classes/Protocol/BithumanEngine.swift`; the Dart
half is git-dep'd and re-exported by `lib/engine_registry.dart`).

## How it stays engine-agnostic (M3)

The plugin resolves a (dual-accept) engine slug → an engine via
`shared/Classes/EngineRegistry.swift` and drives whatever `any BithumanEngine`
comes back **purely by `capabilities.driveModel`** — no `loadExpression2()`/
`loadEssence2()` hard-coding, no `engineKind == "essence2"` branches, no
`avatar as? Essence2Runtime` downcast. `EngineRegistry.make(slug, ref)` is the
**sole** place a concrete engine type is named (macOS-only). Both proven drive
loops are kept verbatim and selected by capability:

- `.bufferedDisplayClock` (expression2) — producer buffers; a separate even 20 fps
  display tick; deep feed-ahead.
- `.atomicSlotClock` (essence2) — a continuous slot clock; one atomic feed+pull
  per tick (the byte-frozen essence-2 render path).

## INVARIANT #1 (the load-bearing constraint)

A CocoaPods `static_framework` pod can host **exactly one** vendored module-map
(C-module) xcframework — reserved here for **`libconverse.xcframework`** (the
on-device brain). **Every avatar engine's native core is a PLAIN static `.a`**,
its C ABI header folded into THIS pod's own umbrella module (so the pod's Swift
calls `be_essence2_*` with no `import`). Two vendored C-module xcframeworks break
each other's Clang module resolution (the clash commit `3b53fc0` fixed). The
podspec **asserts** this — it `raise`s the pod build if any staged engine ever
vendors an `.xcframework` instead of a `.a`, or if there is ever more than one
module-map xcframework. See `ARCHITECTURE.md` for the full mechanism.

**Revised in 2.6.20:** the Expression 2 engine is linked as the published Swift binary
frameworks (`Expression2`, `BithumanEngineProtocol`, `UnifiedModelHeader`), which are Swift
modules, not Clang module maps, so they do not take `libconverse`'s slot. The pod compiles no
engine source, and no engine source is fetched from anywhere.

A second class, `BithumanRealtimeSession`, wires the avatar to OpenAI's Realtime API for
full-duplex voice chat. The plugin owns a single VP-IO `AVAudioEngine` graph: Apple's Voice
Processing I/O subtracts the bot's voice from the mic input (no self-talk feedback), the
speaker and the avatar's lip-sync drain from the same chunk in the same instant (no A/V
drift), and a client-side VAD on mic peak fires barge-in within ~50 ms when the user starts
talking over the agent.

> **The product app lives in its own repo, [`bithuman-jarvis-app`](https://github.com/bithuman-product/bithuman-jarvis-app)**
> (macOS; it depends on this plugin via a pinned git dependency). This plugin is its
> reusable rendering + audio layer; the app drives BOTH engines through the registry +
> the `BithumanEngine` interface and adds the per-engine downloadable agent gallery.

## Install

```yaml
dependencies:
  bithuman:
    git:
      url: https://github.com/bithuman-product/homebrew-bithuman.git
      ref: <pin-a-commit>      # the app pins a fixed commit, not main
      path: packages/flutter-plugin
```

For local development against a checkout:

```yaml
dependencies:
  bithuman:
    path: ../homebrew-bithuman/packages/flutter-plugin
```

After `flutter pub get`, run the plugin's bootstrap once (it fetches libconverse
+ runs the N-engine loop): `bash scripts/bootstrap.sh`. To iterate on an engine,
point `BITHUMAN_EXPRESSION2_DIR` / `BITHUMAN_ESSENCE2_DIR` at a local engine
checkout; for the brain + a sibling SDK use `BITHUMAN_SDK_DIR`.

## Minimum API — static avatar

```dart
import 'package:flutter/material.dart';
import 'package:bithuman/bithuman.dart';

class AvatarView extends StatefulWidget { const AvatarView({super.key}); @override State<AvatarView> createState() => _S(); }
class _S extends State<AvatarView> {
  BithumanAvatar? _a;
  @override void initState() {
    super.initState();
    // apiSecret: your bitHuman API secret — from sign-in or your backend, never a literal.
    BithumanAvatar.load('/path/to/agent', apiSecret: apiSecret).then((a) => setState(() => _a = a));
  }
  @override void dispose() { _a?.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) =>
      _a == null ? const SizedBox() : Texture(textureId: _a!.textureId);
}
```

The avatar idles (real-footage idle loop) with no audio pushed.
`BithumanAvatar.load(path, {apiSecret, engine, motionDir, chunk})` routes to the engine named
by `engine` (dual-accept slug; default expression2) — the wire contract is frozen.

## Voice chat in 30 lines

```dart
import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';

final avatar = await BithumanAvatar.load(agentPath, apiSecret: apiSecret);
final session = BithumanRealtimeSession(
  apiKey: const String.fromEnvironment('OPENAI_API_KEY'), // OpenAI's key, not your bitHuman API secret
  avatar: avatar,
  systemPrompt: 'You are a friendly avatar host.',
  voice: 'alloy',
  vadThreshold: 1500,
);

session.statusStream.listen((s) => debugPrint('status: $s'));
session.botTranscriptStream.listen((delta) => debugPrint('bot: $delta'));
session.userTranscriptStream.listen((t) => debugPrint('user: $t'));
session.micLevelStream.listen((lvl) {/* drive a mic pulse */});
session.botLevelStream.listen((lvl) {/* drive a speaking pulse */});

await session.start();   // opens WS + starts VP-IO mic+speaker
// ... conversation runs; barge-in is automatic ...
await session.stop();    // closes WS, tears down audio graph
await avatar.dispose();
```

### …and the same thirty lines with no avatar at all

`avatar:` is typed `VoiceHost` (`lib/src/voice_host.dart`), not `BithumanAvatar` — a
fourteen-member protocol covering the mic, the speaker, the echo canceller, barge-in and
the on-device brain. `BithumanAvatar` implements it, which is why the snippet above is
unchanged; but so can anything else, and the voice module no longer imports the render
module at all.

That is what makes voice testable on its own: `test/e2e/headless_voice_host_test.dart`
runs a real `BithumanRealtimeSession` against `RecordingVoiceHost` — plain Dart, no
engine, no texture, no platform channel — on an ordinary Linux CI runner. Pass your own
conformer to record audio, drive a different renderer, or stand a voice session up in a
process that has no UI.

```dart
class MyVoiceHost implements VoiceHost { /* 14 members, no render */ }

final session = BithumanRealtimeSession(
  apiKey: key, avatar: MyVoiceHost(), systemPrompt: '…', voice: 'alloy', vadThreshold: 0,
);
```

Which transport a session gets is a registry, not an `if`: `lib/src/transport_protocol.dart`
carries one `TransportDescriptor` per transport (id, label, `canMute`,
`requiresLocalBrain`, the platforms it runs on) and `pickTransportDescriptor` routes from
that record. See ARCHITECTURE.md "Recipe: add a 3rd transport".

`session.start()` brings the native audio engine up before the WebSocket so the first mic frame OpenAI sees is already echo-cancelled.

## Engine registry (Dart)

Re-exported from Layer 0 via `package:bithuman/engine_registry.dart`:

| Symbol | Purpose |
| --- | --- |
| `kEngineRegistry` | the registered engines, in gallery order (`kExpression2`, `kEssence2`). The app renders one tab per entry. |
| `EngineDescriptor` | `canonical` + frozen `aliases` + `label` + `loadsFromLocalDir` + `engineAbi`. |
| `engineDescriptorFor(slug)` | dual-accept resolve a (possibly aliased) slug → its descriptor. |

A 3rd engine appends one `EngineDescriptor` here (and one line in
`scripts/bootstrap.sh`'s engine list + one `EngineRegistry.make` branch) — see
`ARCHITECTURE.md` § "Recipe: add a 3rd engine".

## Public Dart API

### `BithumanAvatar`

| Member | Purpose |
| --- | --- |
| `static load(path, {apiSecret, engine, motionDir, chunk})` | Load an avatar; routes to the named engine (dual-accept). Returns a `BithumanAvatar` with a fresh `textureId`. |
| `textureId` | Pass to `Texture(textureId: ...)`. |
| `pushAudio(Int16List pcm)` | Push 16 kHz mono PCM16. Native side schedules frame production as the queue drains. |
| `audioStart()` | Start the unified VP-IO mic+speaker engine. AEC + sample-accurate A/V sync. |
| `audioStop()` | Tear down the audio engine. |
| `playSpeakerPCM(Uint8List pcm24kPcm16le)` | Play 24 kHz PCM16 through the speaker AND drive lip-sync from the same chunk. |
| `micStream` | Echo-cancelled mic capture as 24 kHz PCM16 chunks. Forward straight to OpenAI Realtime. |
| `interrupt()` | Cancel mid-sentence. Flushes the speaker queue + wipes the avatar's lip-sync buffer. |
| `dispose()` | Drop the native runtime. Idempotent. |

Plus catalog helpers (anonymous, no auth):

| Member | Purpose |
| --- | --- |
| `fetchPublicAgents({limit})` | Fetch the public agent catalog from bithuman.ai. |
| `downloadAgent(agent, cacheDir)` | Stream-download an agent's model bundle, cached by id, header-validated. |
| `nativeEngineVersion()` | Diagnostic version stamp from the native side. |

### `BithumanRealtimeSession`

| Member | Purpose |
| --- | --- |
| `BithumanRealtimeSession({apiKey, avatar, model, systemPrompt, voice, vadThreshold})` | Construct. `model` defaults to `gpt-realtime` (OpenAI Realtime GA). |
| `start()` | Open WS, start VP-IO, begin forwarding mic. |
| `stop()` | Close WS, tear down audio. Single-use; build a new session for the next conversation. |
| `commitInputAudio()` | End-of-turn marker for non-VAD push-to-talk flows. |
| `applySettings({systemPrompt})` | Hot-update the system prompt mid-session (voice cannot be changed mid-call). |
| `muted` | When true, mic capture continues (needed for VP-IO reference) but bytes are not sent to OpenAI. |
| `statusStream` | `RealtimeStatus` events: connecting, open, userSpeaking, userStopped, responseDone, closed, error. |
| `botTranscriptStream` | Streaming partials of what the bot is saying. |
| `userTranscriptStream` | The user's transcribed speech (when OpenAI returns it). |
| `micLevelStream` | Mic peak in [0, 1] per ~85 ms chunk. |
| `botLevelStream` | Bot-audio peak in [0, 1] per chunk. |

The session auto-reconnects WS drops with 1/2/4/8/16/30 s backoff (cap 30 s, 8 attempts) before surfacing `RealtimeStatus.error`.

## Platform support

| Platform | Status |
| --- | --- |
| macOS (Apple Silicon, 13.0+) | shipped — on-device expression-2 (CoreML/ANE) + optional on-device essence-2 render + cloud/local brain |
| Android (arm64, 10+) | on-device expression-2 / essence-2 render + cloud brain, or the on-device LOCAL brain (see below) |
| iOS (device, 16.0+) | cloud brain only — on-device avatar render is macOS-only today (`platforms: [macos]` in each engine manifest) |

## Set your Apple signing team

iOS builds are code-signed with **your** Apple Developer team — the team ID is
**not** committed to the project. Export it before building (or add it to
`~/.env`, which `scripts/run-all.sh` reads automatically):

```sh
export DEVELOPMENT_TEAM=XXXXXXXXXX   # your 10-char team id (developer.apple.com/account)
flutter build ios                    # or: scripts/dev-apple.sh
```

`<bithuman-jarvis-app>/ios/Flutter/Bithuman.xcconfig` feeds `$(DEVELOPMENT_TEAM)` into the build
with automatic signing. macOS local builds sign ad-hoc and need nothing.

## What `scripts/bootstrap.sh` provisions per platform

Run it once after cloning — it downloads + sha256-verifies releases and lays the
native deps into `<plat>/Frameworks/` + each engine under `<plat>/Engines/<engine>/`
+ the demo CoreML models into `Assets/embody/`. Nothing is committed.

- **`libconverse.xcframework`** — the on-device LOCAL-mode brain (llama.cpp +
  Supertonic). The ONE module-map xcframework (INVARIANT #1). Fetched from the
  `vendor-v1` embody Release.
- **expression2** (REQUIRED) — its bootstrap fetches the expression-2 CoreML model
  bundle (the A42 demo). SOURCE-ONLY: no static lib. Adapter source →
  `Engines/expression2/Classes`; models → `Assets/embody`.
- **essence2** (OPTIONAL) — its bootstrap fetches + sha-verifies the
  `libessence2` release **this plugin pins** (`LIBESSENCE2_RELEASE` +
  `LIBESSENCE2_SHA256` in `scripts/bootstrap.sh`, the same release
  `Package.swift`'s `essence2Tag` serves) and extracts the per-platform
  `libessence2.a` + resources → `Engines/essence2/{Classes,include,Vendor}`;
  absent it, the build is byte-identical expression-2-only.

macOS needs two Homebrew dylibs at link + runtime via `@rpath`:
`brew install llama.cpp onnxruntime` (the app's xcconfig wires the `@rpath`). The
cloud OpenAI-Realtime mode needs neither — it's pure Swift.

## Android LOCAL mode (the on-device brain)

`localAudioStart` works on Android (arm64, Android 10+): speech in, the reply and the voice
all run on the phone, with no cloud and no OpenAI key. The Dart side is the same
`LocalConverseTransport` that drives Apple's libconverse, with the same channel names and events,
so an app that runs LOCAL mode on iPhone runs it on a Galaxy unchanged.

| stage | Android | Apple (libconverse) |
| --- | --- | --- |
| speech in | silero VAD (400 ms endpoint) + **Moonshine tiny** (sherpa-onnx) | Apple SpeechAnalyzer |
| reply | **llama.cpp** on the CPU, any chat GGUF (Llama-3.2-1B-Instruct Q4_K_M measured) | llama.cpp (Metal), Qwen2.5-0.5B |
| voice | **Supertonic** (sherpa-onnx int8 export), voice `M1` by default | Supertonic (fp32) |

The contract is Apple's `libconverse.h` (BC_ABI_VERSION 2) mirrored member for member in
`android/.../brain/ConverseEngine.kt`: push_audio / push_text / pull_audio / interrupt / reset /
state, and the same event kinds and states. What the Apple measurements taught is built in from the
start: reply audio goes to the avatar **as fast as it is synthesized** with an in-order
end-of-reply flush (no real-time pacing); endpointing is the VAD's own trailing silence (no forced
finalize); history is capped and the KV cache is reused turn to turn (the prompt prefix is kept,
and a trimmed history is slid down in the cache instead of re-prefilled); emoji, markdown and
*stage directions* are stripped; a turn the VAD splits in two is merged; a self-harm mention
gets a fixed crisis-line reply without asking the model, and the persona's house rules (never
claims to be human, no romance) are appended to any app prompt.

### Files the app provides

Two paths come from Dart (the same two Apple takes); the speech-in models sit beside the LLM:

```
<dir>/<model>.gguf                     ggufPath: the LLM
<supertonicAssets | <dir>/supertonic>/  duration_predictor.int8.onnx text_encoder.int8.onnx
                                       vector_estimator.int8.onnx vocoder.int8.onnx
                                       tts.json unicode_indexer.bin voice.bin
<dir>/stt/                             silero_vad.onnx preprocess.onnx encode.int8.onnx
                                       uncached_decode.int8.onnx cached_decode.int8.onnx tokens.txt
```

| asset | source | size | license |
| --- | --- | --- | --- |
| Llama-3.2-1B-Instruct Q4_K_M | `bartowski/Llama-3.2-1B-Instruct-GGUF` | 808 MB | Llama 3.2 Community License (attribution "Built with Llama"; 700 M MAU cap; AUP) |
| — or Qwen2.5-0.5B-Instruct Q4_K_M (Apple's) | `Qwen/Qwen2.5-0.5B-Instruct-GGUF` | 491 MB | Apache-2.0 |
| Supertonic 3, int8 | sherpa-onnx `tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11` | 145 MB (128 MB .tar.bz2) | model OpenRAIL-M, code MIT |
| Moonshine tiny, int8 | sherpa-onnx `asr-models/sherpa-onnx-moonshine-tiny-en-int8` | 124 MB | MIT |
| silero VAD | sherpa-onnx `asr-models/silero_vad.onnx` | 0.6 MB | MIT |

The app adds **26.5 MB** of native code (`libsherpa-onnx-jni.so` 23.6 MB, ONNX Runtime linked in
statically, and `libbhbrain.so` 3.0 MB, llama.cpp). Nothing in the shipped path is GPL: sherpa-onnx is
built from source with its espeak-ng dependency replaced by a no-op stand-in
(`android/src/main/cpp/no-espeak/`, see its README); Supertonic does not phonemize.

### Build notes

The Android native build compiles llama.cpp (pinned commit) and sherpa-onnx v1.13.8 from source
through CMake (NDK + CMake 3.22.1); the first build takes a few minutes. Offline builds:
`BH_LLAMA_CPP_DIR=/path/to/llama.cpp` and `BH_SHERPA_ONNX_DIR=/path/to/sherpa-onnx@v1.13.8`.
The ISA baseline is armv8.2-a + dotprod + fp16 (no i8mm assumed); on a Galaxy S25+ that costs
nothing measurable against an armv8.7-a build (prefill 237 vs 251 tok/s, generation 69 vs 66).

## Hardware floor

- **Mac**: Apple Silicon M3 or newer. Older Intel Macs and M1/M2 will run but are not benched.

## License

Apache-2.0. Copyright bitHuman.
