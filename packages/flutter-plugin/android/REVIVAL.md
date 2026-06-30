# android/ — Elevate frames-path revival (scope + status)

The android platform was retired 2026-06-01 (full converse/essence plugin
preserved at archive/android/, 2k lines). This directory is the 2026-06-11
minimal revival: ONE engine ('elevate'), ONE path (frames), backed by
`ai.bithuman:libelevate-android` — the le_core JNI AAR built from
bithuman-sdk `engine/elevate/runtime-cpu/android/` (m4b ONNX single graph +
cv2-parity paste; ~40.15 dB vs teacher, validated macOS/linux/cross-platform
in runtime-cpu STATE.md).

## What works (this dir)

- `load(path, engine: 'elevate')` — path = le-bundle dir on device storage ->
  textureId; 25 fps drive-protocol playback onto the Flutter texture
  (SurfaceTexture -> lockCanvas/drawBitmap, the archived plugin's proven
  pattern). `frameSize`, `isReady`, `engineVersion`, `dispose`.
- Dependency: mavenLocal `ai.bithuman:libelevate-android:0.1.0`
  (`cd bithuman-sdk/engine/elevate/runtime-cpu/android && gradle
  publishToMavenLocal`). Release path: publish to Maven Central like
  ai.bithuman:sdk.

## Parity gaps vs the Apple plugin (deliberate, in dependency order)

1. LIVE chat (audio -> motion): the Apple live chain (Expression actor + Co-
   reML motion extractor) is accelerator-bound and does NOT port to Android
   CPU (measured: DiT 6.8 s/chunk, decoder 2.9 s/chunk ORT-CPU M5 — see
   runtime-cpu/actor/ACTOR_SCOPE.md). The Android live path is the LMDM
   keypoint actor (hubert_student + lmdm_student ONNX, ~1.4 ms per 80-frame
   chunk on CPU) feeding `ElevateFrames.renderKeypoints` — JNI surface is
   already in place; needs the kp(265)->xd(63) host-side mapping port +
   audio capture plumbing (RealtimeAudioIO in archive/ is reusable).
2. Audio in/out — WIRED (2026-06, app layer, NOT this plugin): the cloud
   conversation is audible on Android. The example app routes Android down
   the WebRTC transport (example/lib/realtime_transport.dart
   `pickTransport`), the same one iOS uses: flutter_webrtc/libwebrtc owns
   mic + speaker + AEC; its AudioSwitchManager requests audio focus, holds
   MODE_IN_COMMUNICATION (so the voice-call volume keys work) and routes
   to the speakerphone by default. The plugin's native audio surface
   (`audioStart`/`playSpeakerPCM`/mic EventChannel) stays stubbed — that's
   why the WebSocket transport is mute AND deaf here and MUST NOT be used
   on Android. A/V sync caveat: the agent's VOICE is real but the avatar
   frames still play the canned drive protocol (item 1) — true phoneme
   lip-sync waits on the LMDM keypoint actor;
   `attachWebrtcRemoteAudio` is a no-op stub, deliberately, until then.
   MITIGATED (2026-06, mouth gating): the drive protocol is captured from
   a TALKING person, so looping all of it flapped the mouth nonstop. With
   a `motion_ranges.json` sidecar next to the bundle's manifest (generate:
   `tools/classify_motion_ranges.py <bundle-dir>` — classifies frames into
   IDLE/TALKING ranges by lip-keypoint openness), the plugin ping-pongs
   inside an IDLE (mouth-closed) range while the agent is silent and a
   TALKING range while its voice is audibly playing. The speaking signal
   is the Realtime `output_audio_buffer.started/stopped/cleared` window,
   forwarded Android-only by the WebRTC transport via `setSpeaking`.
   Stage the sidecar next to the staged bundle (debug build):
       adb push motion_ranges.json /data/local/tmp/
       adb shell run-as ai.bithuman.bithuman_example \
           cp /data/local/tmp/motion_ranges.json files/elevate/avatar.lab/
   No sidecar -> the legacy full-protocol loop, unchanged.
   Converse EventChannels, PiP, essence engine: still stubbed; revive from
   archive/android/ when essence-on-Android returns to scope.
3. Texture path is Bitmap+Canvas (40 ms budget holds at 720x1280 on the
   archived plugin's measurements); ImageReader/GL zero-copy is the known
   upgrade if profiling demands it.

## Build status (2026-06-11)

- Plugin + example APK: `flutter build apk --debug` in example/ (android
  host generated with `flutter create --platforms=android .`).
- DEVICE-VALIDATED (Galaxy Z Fold 5 / SM8550, same day): load -> textureId
  -> drive loop renders on the Flutter texture; plugin perf log shows
  render 125-129 ms/frame, 7.6-7.7 fps sustained in-app (b1 fp32, CPU,
  no core pinning). Full le_render device matrix + PSNR parity (40.15 ==
  golden) + KleidiAI A/B: bithuman-sdk
  engine/elevate/runtime-cpu/ANDROID_RESULTS.md. Fix landed on the way:
  texture registration moved to the platform thread (FlutterRenderer
  Handler requirement).
- 25 fps on phone CPU is NOT met by m4b fp32 (misses 1.6-2.4x; throttling
  is the dominant variable) — levers in dependency order: big-core
  affinity for the ORT pool, NPU EP (QNN/NNAPI), ImageReader/GL zero-copy.
