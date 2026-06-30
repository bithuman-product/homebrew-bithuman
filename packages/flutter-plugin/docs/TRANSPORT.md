# Realtime transport & AEC — ground truth and the unification plan

_Status: 2026-06 (task #56). Owner: example app `realtime_transport.dart` +
plugin native audio. Companion tooling: `scripts/stress-webrtc-iphone.sh`._

## 1. Current state (who owns audio, per platform)

| | macOS cloud | iOS cloud | Android cloud | local (macOS/iOS) |
|---|---|---|---|---|
| Transport | `WebSocketTransport` (`bithuman_realtime.dart`) | `WebRTCTransport` (`openai_webrtc_session.dart`) | `WebRTCTransport` | `LocalConverseTransport` |
| Audio I/O owner | plugin `RealtimeAudioIO` (one shared `AVAudioEngine`) | libwebrtc ADM (flutter_webrtc) | libwebrtc ADM (flutter_webrtc) | plugin `RealtimeAudioIO` |
| **AEC** | **Apple VP-IO** (`setVoiceProcessingEnabled(true)` on input+output node) | **Apple VP-IO** (managed by libwebrtc's iOS ADM) | platform `AcousticEchoCanceler` (API ≥ 29) over `VOICE_COMMUNICATION`; libwebrtc AEC3 as software backstop | Apple VP-IO |
| Barge-in | OpenAI server_vad (+ opt-in native energy VAD) | OpenAI server_vad (threshold 0.5, far_field NR) | OpenAI server_vad | native energy VAD (0.3 s sustain) |
| Lipsync feed | `playSpeakerPCM` (same chunks → speaker + queue) | `attachWebrtcRemoteAudio` → `WebrtcLipsyncRenderer` tap on the remote track | AudioTrackSink via reflection (Kotlin) | native pipeline |
| A/V onset | utterance gate: speaker held for first composited frame, **<150 ms skew** | direct playout + playout-anchor join (audio leads video for the K-slot head-latency window at onset; task #55 is shrinking this) | frames-path, `setSpeaking` ranges | utterance gate |

## 2. AEC ground truth (verified against sources, not assumed)

**iOS WebRTC path still runs Apple's AEC.** Chain of evidence:

- `flutter_webrtc 1.4.1` → CocoaPods `WebRTC-SDK 144.7559.01` (LiveKit
  libwebrtc m144; `example/ios/Podfile.lock`).
- `FlutterWebRTCPlugin.m` creates the factory with
  `RTCAudioDeviceModuleTypePlatformDefault` and `bypassVoiceProcessing:NO`
  (the app calls `WebRTC.initialize()` with no options — `main.dart`). The
  platform-default iOS ADM uses the `kAudioUnitSubType_VoiceProcessingIO`
  unit when voice processing is not bypassed → **Apple VP-IO is the echo
  canceller**, same engine as a phone call. libwebrtc's software AEC3 is not
  the canceller on iOS (built-in AEC is reported available to the APM; the
  APM still does NS/AGC per the getUserMedia constraints).
- Session config: `RTCAudioSessionConfiguration.webRTCConfiguration` =
  `playAndRecord` + `.voiceChat`. On PC-connected we call
  `Helper.setSpeakerphoneOn(true)`, which keeps category/mode and only ORs in
  `defaultToSpeaker` + output-port override — VP-IO stays engaged
  (`AudioUtils.m`).
- **Why the barge storm happened (feee578) and why direct playout fixes it
  (37094fd):** VP-IO only *cancels* audio rendered through its own unit;
  audio from other engines in the process is *ducked, not cancelled*. The
  side-channel `AVAudioEngine` speaker put the bot's voice outside the WebRTC
  ADM's echo reference → residual re-entered the mic → server_vad cancelled
  the response every ~2 s with no user speech. Direct track playout routes
  the bot's voice through the ADM's own VP-IO unit, making it the canceller's
  reference. The fix did **not** swap Apple AEC for software AEC — Apple's
  AEC was and is in the loop; the fix put the playout back inside its
  reference.

**Android:** `MethodCallHandlerImpl.java` builds `JavaAudioDeviceModule` with
`setUseHardwareAcousticEchoCanceler(SDK ≥ Q)` + built-in NS, capture source
`VOICE_COMMUNICATION`, `MODE_IN_COMMUNICATION` + speakerphone via
AudioSwitch. Devices without the platform effect fall back to libwebrtc AEC3.

> **RISK (untracked patch):** the local pub-cache copy of
> `flutter_webrtc-1.4.1/android/.../MethodCallHandlerImpl.java` is patched
> in-place (`useLowLatency=false`, "PATCHED" comment) so playback goes down
> the Java `AudioTrack` path where the lipsync `AudioTrackSink` fires —
> AAudio bypasses every Java hook. This patch lives **only in
> `~/.pub-cache`**: any other machine, CI, or `dart pub cache repair` loses
> it silently (symptom: Android voice plays but the mouth never moves).
> It must be promoted to a vendored fork / dependency_override before any
> Android release.

**macOS today (WS path):** `RealtimeAudioIO` — one `AVAudioEngine`, VP-IO on
input+output, speaker + lipsync fed the same chunks (shared clock), the
start-of-utterance gate, and Apple AEC covering the gated playback. This is
the best-behaved A/V surface of the three.

**macOS under flutter_webrtc (what unification would use):** flutter_webrtc
pins the ADM to `PlatformDefault` (=CoreAudio ADM) on macOS — deliberately
NOT the AVAudioEngine ADM, which crashes when screen-share audio and mic
coexist (flutter-webrtc#1986). The CoreAudio ADM has **no VP-IO**: echo
cancellation falls to **libwebrtc software AEC3** in the APM (what
Chrome/Meet use on desktop — adequate, but a different canceller than what
macOS ships with today).

## 3. Unifying all three platforms on WebRTC — assessment

**Gains**
- One transport implementation, one event schema, one barge-in path to
  maintain (today: 2 realtime clients + 2 native audio stacks).
- The WS client + `RealtimeAudioIO` mic/speaker path (~1.5k lines incl. the
  gate) eventually retire on cloud; LiveKit migration later = swap inside
  one transport.
- Lower audio RTT (UDP/Opus vs WS PCM16 base64 over TCP).

**Losses / risks on macOS (the platform being moved)**
1. **AEC regression risk:** Apple VP-IO → libwebrtc AEC3 (CoreAudio ADM, see
   §2). Desktop echo (open speakers + studio mics) is exactly where AEC3 vs
   VP-IO differences show up. Must be measured, not assumed — run the §5
   stress protocol on the Mac under `BITHUMAN_TRANSPORT=webrtc`.
2. **Utterance gate is lost:** direct WebRTC playout bypasses
   `RealtimeAudioIO`, so the <150 ms gated onset is replaced by the iOS
   playout-anchor behavior (audio leads video for the engine's head-latency
   window at onset). Whatever #55's onset work lands on iOS becomes the
   macOS ceiling too.
3. **Lipsync gap:** `attachWebrtcRemoteAudio` is `#if os(iOS)` —
   on macOS it returns `FlutterMethodNotImplemented` and the mouth idles.
   `WebrtcLipsyncRenderer` is reflection-based (no WebRTC pod dependency)
   and should port to macOS nearly verbatim, but it is real plugin work +
   re-validation of A/V pacing on macOS.
4. **Level meters:** `WebRTCTransport` emits no mic/bot levels yet (UI
   pulse degrades). Wireable via `getStats()` audio levels.
5. **e2e coverage:** Tier-1/Tier-2 session tests speak the mock **WS**
   server. There is no WebRTC mock — see §6.
6. **Mute semantics change:** native VP-IO mute → track-`enabled` mute.

**Recommendation: conditional GO — staged, evidence-gated.** The end-state
(one WebRTC transport everywhere) is right for maintenance, but macOS is the
best-behaving surface today and the move swaps its echo canceller and
deletes its A/V gate. Do not flip the default until the macOS A/B passes the
same stress bar as the iPhone (0 spurious barge-ins/min) and the lipsync
attach works on macOS.

## 4. Target state & migration steps

Target: `pickTransport` = local → LocalConverse; cloud → WebRTC on all
three; WS client retained only as a rollback flag for one release cycle.

- **Phase 0 (DONE, this change):** `--dart-define=BITHUMAN_TRANSPORT=webrtc`
  opt-in routes macOS cloud → `WebRTCTransport` (`realtime_transport.dart`;
  Tier-1: `transport_pick_test.dart`). Production builds unaffected.
- **Phase 1 (plugin):** extend `attachWebrtcRemoteAudio` +
  `WebrtcLipsyncRenderer` to macOS (drop the `#if os(iOS)`, gate the
  AVAudioSession-only bits); wire `setPlayoutAnchor` on macOS.
- **Phase 2 (evidence):** run the §5 stress arms on macOS under the define
  (open speakers, 50 %/100 %); compare AEC3 vs the WS/VP-IO baseline; check
  onset skew vs the gate (target: within the post-#55 iOS number).
  Wire `getStats()` levels.
- **Phase 3 (flip):** default macOS cloud → WebRTC; keep
  `BITHUMAN_TRANSPORT=ws` (then-new value) as rollback for one cycle; add a
  WebRTC-side e2e tier (§6); promote the pub-cache Android patch to a
  tracked fork. Then retire the WS cloud path (local mode keeps
  `RealtimeAudioIO` regardless — it is not WebRTC's concern).

## 5. Stress protocol (self-interruption / barge-storm)

`scripts/stress-webrtc-iphone.sh quiet50|loud100|bgaudio` — builds the
Elevate variant with `BITHUMAN_DEV_AUTOCONNECT` + `BITHUMAN_DEV_STRESS`
(continuous ~60 s monologues, re-armed after each `response.done` — zero
user input, so **every** `speech_started` is a spurious barge), installs
WITHOUT uninstalling, captures `devicectl --console`, and scores with
`stress-webrtc-metrics.py` (spurious barge-ins/min, cancels, AEC-probe
leaks, gate health; PASS = 0 spurious + 0 cancels). The iPhone volume slider
is the one manual step (no devicectl path to it); background audio for the
third arm is automated from the Mac (`afplay` loop).

## 6. WebRTC e2e mocking (what it would take — not built)

The hermetic mock (`e2e/mock_realtime`) is a WS server; `OpenAIWebRTCSession`
needs an SDP answerer + DTLS/SRTP/Opus peer + data channel — a real WebRTC
stack, not a socket fake. Cheapest credible options, in order:
1. **Transport-level fake (recommended):** inject a scripted
   `RealtimeTransport` above `pickTransport` for UI flows — no wire mocking;
   covers everything except `openai_webrtc_session.dart` itself.
2. Loopback peer in-process: a second `RTCPeerConnection` (flutter_webrtc on
   the sim) answers the offer and replays the mock event script over the
   data channel; needs an injectable SDP-exchange hook in
   `OpenAIWebRTCSession` (today it POSTs to api.openai.com directly).
3. aiortc (Python) mock server speaking the `/v1/realtime/calls` contract —
   heaviest, full fidelity.
On-device runs (§5) remain the method of record for AEC behavior — echo
physics don't simulate.
