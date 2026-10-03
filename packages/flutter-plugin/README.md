# bithuman — the bitHuman Flutter plugin

[![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/vq3FyeN6k4)

One Flutter dependency renders a bitHuman avatar on the device, on Android, iOS and macOS, and can
connect it to a voice conversation through bitHuman's realtime relay. Full guide:
**[docs.bithuman.ai/platforms/flutter](https://docs.bithuman.ai/platforms/flutter)**.

## Platforms

| Platform | Status |
| --- | --- |
| Android (arm64-v8a phone, API 29+) | Supported: Expression 2 and Essence 2 on the device. `load` takes the agent code and downloads the avatar. Emulators cannot load the engines. |
| iOS (16.0+, arm64 device) | Supported: Expression 2 and Essence 2 on the device (Essence 2 needs iOS 26, as in the [Swift package](https://docs.bithuman.ai/platforms/ios)). Run `scripts/bootstrap.sh` once; your app supplies the avatar files. |
| macOS (13.0+, Apple silicon) | Supported, as iOS; also `brew install llama.cpp onnxruntime`, which the plugin links. |

## Install

```yaml
dependencies:
  bithuman:
    git:
      url: https://github.com/bithuman-product/homebrew-bithuman.git
      path: packages/flutter-plugin
      ref: flutter-plugin-v2.6.35   # the current tag: docs.bithuman.ai/downloads
```

The pubspec needs Dart 3.11.5 or newer. On Android, set these in `android/app/build.gradle.kts` (the
plugin needs API 29 whichever model you use, and the engines ship arm64-v8a only):

```kotlin
android {
    defaultConfig {
        minSdk = 29
        ndk { abiFilters += "arm64-v8a" }
    }
    packaging { jniLibs { useLegacyPackaging = true } }
}
```

On iOS and macOS, raise the deployment targets (`platform :ios, '16.0'` in `ios/Podfile`,
`platform :osx, '13.0'` in `macos/Podfile`, and the Runner targets to match), then run
`scripts/bootstrap.sh` once in the plugin's folder (for a git dependency, `packages/flutter-plugin`
under `~/.pub-cache/git/homebrew-bithuman-…`). It downloads the published engines and checks their
sha256.

## Show an avatar

```dart
import 'package:bithuman/bithuman.dart';

final avatar = await BithumanAvatar.load(
  'A23WJF0199',            // Android: the agent code. iOS / macOS: the avatar files your app downloaded
  engine: 'expression2',   // or 'essence2'; pass it every time
  apiSecret: apiSecret,    // your bitHuman API secret, from your backend, never a literal
);

Texture(textureId: avatar.textureId);   // the avatar in your layout; idles until it speaks
```

On iOS and macOS, Expression 2 also needs `await BithumanAvatar.setExpression2AgentDir(dir)` with the
avatar's folder before `load`. An unknown `engine:` name fails with `PlatformException` code
`unsupported` on every platform.

## Play your own speech

```dart
await avatar.audioStart(enableMic: false);   // the speaker (required on iOS and macOS)
await avatar.playSpeakerPCM(chunk);          // 24 kHz mono PCM16 (Uint8List): plays it and moves the lips
await avatar.notifyTurnEnd();                // after the reply's last chunk
await avatar.interrupt();                    // cut the reply (barge-in)
await avatar.dispose();
```

`pushAudio(Int16List)` takes 16 kHz speech: on Android it is converted and played the same way (2.6.36);
on iOS and macOS it moves the lips with no sound.

## Voice conversation

`BithumanRealtimeSession` connects the avatar to bitHuman's realtime relay with your bitHuman API secret.
The conversation is billed to your account (the [realtime relay](https://docs.bithuman.ai/api/realtime)),
and no other provider's key is in your app.

```dart
import 'package:bithuman/bithuman_realtime.dart';

final session = BithumanRealtimeSession(
  apiKey: apiSecret,              // your bitHuman API secret (the same one load takes)
  avatar: avatar,
  model: 'gpt-realtime-mini',     // the model a standard API secret may use
  systemPrompt: 'You are a friendly avatar host.',
  speechReady: avatar.ready,      // dial once the avatar can move its mouth
);

// Captions: the agent's words as they are heard (cumulative per reply; replace, do not append).
session.spokenTranscriptStream.listen((e) => setState(() => caption = e.text));
// Why the session ended for good (UNAUTHORIZED, INSUFFICIENT_BALANCE, PAYWALL, PLAN_REQUIRED, ...).
session.errorStream.listen((e) => showError(e.code, e.message));

await session.start();   // the microphone and the speaker, with echo cancellation
// ... the conversation runs; barge-in is automatic (the server's voice detection) ...
await session.stop();    // single-use: build a new session for the next conversation
await avatar.dispose();
```

## How the plugin is built (for contributors)

The rest of this page is for people working on the plugin itself. For the full map (both engines, the
bootstrap chain, the podspec mechanics and the recipe to add a third engine) read
**[`ARCHITECTURE.md`](ARCHITECTURE.md)**.

The plugin is engine-agnostic glue: a `Texture`, the method channel `ai.bithuman.avatar`, the audio
graph and the realtime session. It links each engine's published binaries, staged by
`scripts/bootstrap.sh`'s engine loop on iOS and macOS and resolved from maven.bithuman.ai on Android:

- **expression2** (required): the published `Expression2` Swift binary on iOS and macOS;
  `ai.bithuman:expression2-android` on Android.
- **essence2**: the `be_essence2_*` C ABI as a plain static `libessence2.a` on iOS and macOS (from the
  `essence2-v…` release the plugin pins); `ai.bithuman:essence2-android` on Android. On iOS and macOS a
  build without it compiles Expression 2 only (the `ESSENCE2_AVAILABLE` gate), and a `load` that asks
  for Essence 2 there fails with `unsupported` (2.6.36).

The shared engine interface (`BithumanEngine`) + the Dart registry
(`EngineDescriptor`/`kEngineRegistry`) come from Layer-0
[`BithumanEngineProtocol`](https://github.com/bithuman-product/homebrew-bithuman/tree/main/Sources/BithumanEngineProtocol)
(staged in-module as `shared/Classes/Protocol/BithumanEngine.swift`; the Dart
half is inlined in `lib/src/engine_protocol.dart` and re-exported by `lib/engine_registry.dart`).

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

A second class, `BithumanRealtimeSession`, wires the avatar to a realtime voice session over one
WebSocket (bitHuman's relay with your API secret). On iOS and macOS the plugin owns a single VP-IO
`AVAudioEngine` graph: Apple's Voice Processing I/O subtracts the agent's voice from the microphone (no
self-talk), and the speaker and the avatar's lip sync drain from the same chunk at the same instant (no
A/V drift). Barge-in is the server's voice detection, behind the plugin's echo gate.

### The voice session with no avatar at all

`avatar:` is typed `VoiceHost` (`lib/src/voice_host.dart`), not `BithumanAvatar` — a
fourteen-member protocol covering the mic, the speaker, the echo canceller, barge-in and
the on-device brain. `BithumanAvatar` implements it, which is why the voice snippet above
passes the avatar; but so can anything else, and the voice module no longer imports the render
module at all.

That is what makes voice testable on its own: `test/e2e/headless_voice_host_test.dart`
runs a real `BithumanRealtimeSession` against `RecordingVoiceHost` — plain Dart, no
engine, no texture, no platform channel — on an ordinary Linux CI runner. Pass your own
conformer to record audio, drive a different renderer, or stand a voice session up in a
process that has no UI.

```dart
class MyVoiceHost implements VoiceHost { /* 16 members, no render */ }

final session = BithumanRealtimeSession(
  apiKey: apiSecret, avatar: MyVoiceHost(), model: 'gpt-realtime-mini', systemPrompt: '…',
);
```

Which transport a session gets is a registry, not an `if`: `lib/src/transport_protocol.dart`
carries one `TransportDescriptor` per transport (id, label, `canMute`,
`requiresLocalBrain`, the platforms it runs on) and `pickTransportDescriptor` routes from
that record. See ARCHITECTURE.md "Recipe: add a 3rd transport".

`session.start()` brings the native audio engine up before the WebSocket, so the first microphone frame the relay sees is already echo-cancelled.

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
| `static load(pathOrCode, {apiSecret, engine, skipAhead})` | Load an avatar. `engine`: `'expression2'` or `'essence2'` (also `'expression-2'`, `'essence-2'`); pass it every time (default `'expression2'` since 2.6.36). Android takes the agent code; iOS / macOS the avatar files. An unknown engine throws `PlatformException` `unsupported`. Returns a `BithumanAvatar` with a fresh `textureId`. |
| `textureId` | Pass to `Texture(textureId: ...)`. |
| `pushAudio(Int16List pcm)` | 16 kHz mono PCM16. Android: converted to 24 kHz and played with lip sync, as `playSpeakerPCM` (2.6.36). iOS / macOS: lip sync only, no sound. Prefer `playSpeakerPCM`. |
| `audioStart({enableMic})` | Start the audio unit: the speaker, and the echo-cancelled microphone unless `enableMic: false`. Required before `playSpeakerPCM` on iOS / macOS. |
| `audioStop()` | Tear down the audio engine. |
| `playSpeakerPCM(Uint8List pcm24kPcm16le)` | Play 24 kHz PCM16 through the speaker AND drive lip-sync from the same chunk. |
| `notifyTurnEnd()` | After the reply's last chunk: the final partial lip-sync chunk is flushed, so the last word is not clipped. |
| `micStream` | Echo-cancelled mic capture as 24 kHz PCM16 chunks (the realtime session forwards them). |
| `interrupt()` | Cancel mid-sentence. Flushes the speaker queue + wipes the avatar's lip-sync buffer. |
| `audioInterruptions` | The platform took the session's sound away (`began`: a phone call ringing or answered, also from its banner or notification; Siri or an assistant; another app's call) or gave it back, as `BithumanAudioInterruption`s with a `reason` (`call`, `focus`, `system`). iOS and Android; macOS never. |
| `dispose()` | Drop the native runtime. Idempotent. |
| `static loadEvents` | Android: what a running `load` is doing, as `BithumanLoadEvent`s — `fetch` (exact bytes of the identity's download), `fetched`, `prepare`, `prepared`. Filter on `code`. iOS/macOS send none. |
| `static cancelLoad(code)` | Android: stop a running `load` of `code`; it throws `PlatformException` `load_cancelled`, and the download keeps what it has for next time. |

Plus catalog helpers (anonymous, no auth):

| Member | Purpose |
| --- | --- |
| `fetchPublicAgents({limit})` | Fetch the public agent catalog from bithuman.ai. |
| `nativeEngineVersion()` | Diagnostic version stamp from the native side. |

### `BithumanRealtimeSession`

| Member | Purpose |
| --- | --- |
| `BithumanRealtimeSession({apiKey, avatar, model, systemPrompt, voice, speechReady, echoOnsetGuard, bargeFloorDb, endOnAudioInterruption})` | Construct. `apiKey`: your bitHuman API secret; the session runs through bitHuman's realtime relay and is billed to your account. `model` defaults to `gpt-realtime`, which the relay allows only on accounts entitled to it (`PLAN_REQUIRED` otherwise): pass `'gpt-realtime-mini'`. `vadThreshold` is accepted and ignored (the server detects speech). `bargeFloorDb`: while the agent is heard, how close (dB) to its voice the microphone must come, for 200 ms, to cut it in; quieter sound is its echo and goes up as silence. Null = the device's default (Android -11, iPhone and macOS -18); under -40 turns the gate off. |
| `start()` | Open WS, start VP-IO, begin forwarding mic. |
| `stop()` | Close WS, tear down audio. Single-use; build a new session for the next conversation. |
| `commitInputAudio()` | End-of-turn marker for non-VAD push-to-talk flows. |
| `applySettings({systemPrompt})` | Hot-update the system prompt mid-session (voice cannot be changed mid-call). |
| `muted` | When true, mic capture continues (needed for the echo canceller's reference) but nothing is sent. |
| `statusStream` | `RealtimeStatus` events: connecting, open, userSpeaking, userStopped, responseDone, closed, error. |
| `spokenTranscriptStream` | `BithumanSpokenText` events: the agent's words released as the listener hears them (`text` is the reply's caption so far; a new `reply` number starts a new caption). The last event of a reply is `isFinal`; when it was cut (barge-in, a typed turn, `stop()`) it is also `interrupted` and holds only the words heard. Use this for captions. |
| `botTranscriptStream` | Streaming partials of what the bot is saying, as the text ARRIVES (for a spoken reply, well ahead of the voice). |
| `userTranscriptStream` | The user's transcribed speech (when the session returns it). |
| `micLevelStream` | Mic peak in [0, 1] per ~85 ms chunk. |
| `botLevelStream` | Bot-audio peak in [0, 1] per chunk. |
| `errorStream` / `lastError` | Why the session stopped for good: the relay refused or ended it (`UNAUTHORIZED`, `INSUFFICIENT_BALANCE`, `PAYWALL` (the account's plan or remaining minutes do not cover a voice session), `PLAN_REQUIRED`, `FORBIDDEN`, `SESSION_DURATION_LIMIT`, `MODEL_LOCKED`, `BAD_REQUEST`), or the avatar's engine refused its model file (`MODEL_REJECTED`). The codes: [docs.bithuman.ai/platforms/flutter/errors](https://docs.bithuman.ai/platforms/flutter/errors). Emitted once, before `RealtimeStatus.error`; the session then tears itself down (microphone and speaker off, captions ended) and its streams close. It does not reconnect; build a new session to try again. |
| `interruptionStream` | The avatar's `audioInterruptions` while the session runs. With `endOnAudioInterruption` (default true) a `began` is followed by the session stopping itself (`closed`), so nothing more is billed; `endedByInterruption` then says why. |

The session auto-reconnects WS drops with 1/2/4/8/16/30 s backoff (cap 30 s, 8 attempts) before surfacing `RealtimeStatus.error`.

## Set your Apple signing team

iOS builds are code-signed with **your** Apple Developer team; no team ID is committed. Set it in
Xcode (Runner target, Signing & Capabilities) or pass it to the build. macOS local builds sign ad hoc
and need nothing.

## What `scripts/bootstrap.sh` provisions per platform

Run it once after cloning — it downloads + sha256-verifies releases and lays the
native deps into `<plat>/Frameworks/` + each engine under `<plat>/Engines/<engine>/`
+ the demo CoreML models into `Assets/embody/`. Nothing is committed.

- **`libconverse.xcframework`** — the on-device LOCAL-mode brain (llama.cpp +
  Supertonic). The ONE module-map xcframework (INVARIANT #1). Fetched from the
  `vendor-v1` embody Release.
- **expression2** (REQUIRED) — the published `Expression2` Swift binary frameworks
  (sha256-checked), plus the demo model bundle → `Assets/embody`.
- **essence2** (OPTIONAL) — its bootstrap fetches + sha-verifies the
  `libessence2` release **this plugin pins** (`LIBESSENCE2_RELEASE` +
  `LIBESSENCE2_SHA256` in `scripts/bootstrap.sh`, the same release
  `Package.swift`'s `essence2Tag` serves) and extracts the per-platform
  `libessence2.a` + resources → `Engines/essence2/{Classes,include,Vendor}`;
  absent it, the build is byte-identical expression-2-only.

macOS needs two Homebrew dylibs at link + runtime via `@rpath`:
`brew install llama.cpp onnxruntime` (the app's xcconfig wires the `@rpath`). The
cloud OpenAI-Realtime mode needs neither — it's pure Swift.

## Hardware floor

- **Mac**: Apple Silicon M3 or newer. Older Intel Macs and M1/M2 will run but are not benched.

## License

Apache-2.0. Copyright bitHuman.
