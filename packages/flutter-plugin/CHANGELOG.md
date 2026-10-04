## Unreleased — the on-device brain, fast enough for a free tier

Needs libconverse **2.4.0**. Until a vendor bundle carries it, stage a local build with
`BITHUMAN_CONVERSE_XCFRAMEWORK=<path> scripts/bootstrap.sh`. The pod still builds against the
older brain (the split-sentence merge is then off).

* **Faster replies (LOCAL mode).** The brain hands its speech to the avatar as fast as it is
  synthesized (up to 3 s ahead, like a cloud reply) and flushes the avatar as soon as the whole
  reply has been handed over, instead of pacing it at playback speed. The avatar's mouth starts
  about 2.5 s sooner; lip-sync still follows the audio clock and a barge still cuts instantly.
* **Faster end of turn.** Apple SpeechAnalyzer runs with `.fastResults`: the user's turn is
  committed 0.4–0.9 s after they stop talking instead of about 2 s.
* **Split sentences are one turn.** "Hi Wise Pup! … How are you?" used to become two turns and
  the second was dropped. A part the user started saying before the reply was audible is now
  merged into the same turn. Finals with no letters or digits are ignored.
* **macOS no longer links Homebrew llama.cpp.** libconverse 2.4.0 carries a pinned static
  llama.cpp; `brew upgrade llama.cpp` could crash the app on load (ABI mismatch). ONNX Runtime
  still comes from Homebrew on macOS.
* **Persona and model set.** `LocalBrainPersona.wisePup`, `LocalBrainModels` (Llama 3.2 1B
  Instruct and a half-size Supertonic voice) and `LocalBrainNotices` (the attributions the model
  licenses require). See `THIRD_PARTY_NOTICES.md`.
* The brain strips emoji, markdown and `*actions*` from captions and speech, and answers a turn
  about suicide or self-harm with a fixed crisis message (988 / local crisis line).

### The hybrid brain: on-device speech, a cheap cloud text model (iOS; needs libconverse 2.5.0)

* **`replyMode: 'host'`** (`LocalConverseTransport(replySource: ...)`, the same Dart API as the Android hybrid brain): speech-to-text, the clause chunker,
  the Supertonic voice, barge-in and the avatar feed stay on the device; the REPLY TEXT comes from
  the app — typically a cheap text model behind the app's own server (no key on the phone, no
  speech-to-speech minute). The brain asks with a `reply_request` event, the app streams the answer
  back with `localReplyText(id, text, done:)`, and a barge-in sends `reply_cancel` (the app drops its
  stream; measured: the cancel leaves within 5 ms of the barge).
* **Parakeet speech-to-text on iOS** (`sttDir:`, the same argument as Android's): a Silero VAD + NVIDIA Parakeet TDT 110M (int8,
  137 MB download, CC BY 4.0) through sherpa-onnx, staged by `scripts/build-sherpa-ios.sh` against
  the pod's own onnxruntime (+2.1 MB app binary). iPhone 18 Pro, prerecorded accented / child
  speech under an avatar: the turn is committed 0.62 s (p50) after the user stops, against 1.1–1.3 s
  for Apple's SpeechAnalyzer (with outliers past 6 s), and speech onset is detected in ~0.3 s
  against 0.6–2.6 s. Without `sttDir` the app keeps Apple's SpeechAnalyzer (nothing to download).
* **`bargeOnSpeech:`** — the on-device VAD barge: the user starting to talk over the character
  stops the voice and the avatar and cancels the reply (0.28–0.48 s from speech onset with Parakeet).
* **`injectAudio:` + `localInjectWav(path)`** (testing): the microphone is never opened; prerecorded
  16 kHz files are spoken into the speech-to-text in real time under a noise floor, and the
  session reports `metric` events (speech end, final, first audio, heard, barge, fps, memory) so a
  harness measures the whole pipeline on the device without a speaker-to-mic loop.

### Apple's on-device model as the brain's LLM (needs libconverse 2.5.0)

* **No LLM download on Apple Intelligence devices.** On iOS / macOS 26 with Apple Intelligence
  turned on, LOCAL mode can run Apple's on-device model (the Foundation Models framework) instead
  of Llama 3.2 1B, so the app downloads only the voice: 200.6 MB instead of 1008 MB.
  `BithumanAvatar.appleIntelligenceStatus()` says whether that works here and why not
  (`deviceNotEligible`, `appleIntelligenceNotEnabled` — the user can turn it on in Settings —,
  `modelNotReady`, …); `LocalBrainModels.assetsFor(apple:)` is the download for that answer.
* `localAudioStart` / `LocalConverseTransport` take `llm:` (`auto` = Apple's model where it is
  available, else the GGUF; `apple`; `llama`). `ggufPath` is optional when Apple's model runs.
* When Apple's model refuses a turn (its own guardrail), the avatar says an in-character line
  (`LocalBrainPersona.wisePupRefusal`) and the refused turn leaves the history, so it cannot make
  the model refuse the turns after it. The 988 crisis reply is still decided before any model
  sees the turn. The first reply is prewarmed at load.
* **It is slower, not faster.** On an M4 Mac, Apple's model takes about 0.4 s to its first words
  with nothing else running and about 0.7 s while the avatar renders (Llama: 0.05 s). A typed
  turn reaches the avatar's mouth in a median 2.1 s with Apple's model against 1.2 s with Llama.
  Choose it for the download size, not for speed.
* FoundationModels is weak-linked: the plugin still loads on older systems.

## 2.6.36 — 2026-10-04 — Security: a kept avatar opens only for a credential bitHuman's door said yes to; iOS / macOS: an app linking Essence 2 starts on every OS the pod declares (essence2-v1.15.4); Android `pushAudio` plays your speech; the public model ids on Android; an unknown engine fails by name on iOS / macOS

iOS / macOS engines: Essence 2 **`essence2-v1.15.4`** (was `essence2-v1.15.3`), Expression 2 **`v2.20.3`** (was
`v2.20.1`), the bytes Swift package 2.20.3 serves; macOS `enginecore-v1.0.2` (unchanged). Android: **`essence2-android`
0.9.4** (was 0.9.3) and **`expression2-android` 0.6.0** (was 0.5.2), maven.bithuman.ai; `test/release_pins_test.dart`
fails the suite on any lower or pre-release pin. Two defaults change (see Changed). Read **Behaviour changes** before
you update: some calls that worked before now fail by name.

### Behaviour changes (action needed)

1. **macOS: the pod's floor is macOS 26.0** (was 13.0). The on-device brain's macOS library (libconverse) is built
   for macOS 26 (`minos 26`), and the pod now takes its floor from the binaries it vendors. A macOS app below 26.0
   fails `pod install` with the floor named (or its build, by name, when `Podfile.lock` already resolves the pod).
   Set `platform :osx, '26.0'` in `macos/Podfile` and `MACOSX_DEPLOYMENT_TARGET = 26.0` in every build
   configuration of the Runner target, and keep `$(inherited)` in `GCC_PREPROCESSOR_DEFINITIONS`. Through 2.6.35 a
   macOS app built at 13.0 started only on macOS 15.4 and later anyway (see Security). **iOS stays at 16.0.**
2. **Catch `BithumanEntitlementException`** from `BithumanAvatar.load` and from the installers (`downloadAgentImx`,
   `downloadExpression2Avatar`, `downloadExpression2Agent`, `downloadEssence2Bundle`). It is a
   `BithumanAvatarException`, not a `PlatformException`, so a `try` that catches only `BithumanModelRejected` and
   `PlatformException` lets it through. `refused: true`: bitHuman said no to this credential for this avatar (do
   not retry with it). `refused: false`: bitHuman could not be asked (offline, a timeout, a 5xx); retry online.
3. **Android, Expression 2: `load` without `apiSecret` now fails** (`load_failed`, "needs the app's credential"), as
   Essence 2 already did. Until now it ran, and billed, as whichever account loaded before it in the process.
4. **The installers need `apiSecret` for any avatar that is not public.** A signed `avatarUrl`, `bundleUrl` or
   catalog `url` alone no longer installs an account's own avatar: bitHuman's door is asked first, with the
   `apiSecret` you pass, and refuses a call without one. Public avatars still install with no key.
5. **Android: an open more than 24 h after the door's last yes to that credential needs the network**, and so does
   the first open of each kept avatar after updating (an earlier version left no record). Offline then, `load`
   throws `BithumanEntitlementException(refused: false)`. Within the 24 h, a kept avatar opens with no network.
6. **Essence 2 refuses by name below iOS 26 / macOS 26.** An app that links Essence 2 now starts on every OS the pod
   declares (iOS 16+), but Essence 2 itself renders on iOS 26 / macOS 26 and later; below that `load(engine:
   'essence2')` fails with `PlatformException` code `unsupported`, naming the OS it needs. Check the OS before you
   download Essence 2 files. Expression 2 runs everywhere the pod does.
7. Recommended: call **`BithumanAvatar.clearCredentials()`** (new) when an account signs out. The engines forget the
   account's API secret; on Android every load still running ends with `load_cancelled`; on iOS / macOS the
   Expression 2 agent dir is forgotten too (call `setExpression2AgentDir` again before the next Expression 2 load
   that needs one).

### Security

* **A kept avatar opens only for a credential bitHuman's door has said yes to (high).** The cache directory you
  pass belongs to your app, not to an account. Until now every installer here returned a kept avatar at once to
  whoever called next: `downloadAgentImx` its `<cacheDir>/<id>.imx`, `downloadExpression2Avatar` and
  `downloadExpression2Agent` their `<cacheDir>/<code>/`, `downloadEssence2Bundle` its `<cacheDir>/<id>.elevatedir/`.
  So after account A opened its private avatar, account B signed in on the same device (after a sign-out, for
  example) was handed A's files. bitHuman's door is owner-scoped and refuses B, but it was never asked before a kept
  file opened, and the session meter checks the key, not the avatar. Now:
  * Each call's credential (`apiSecret`, or none) needs an entitlement mark for the kept avatar, written when
    bitHuman's door says yes to exactly that credential and dropped when it says no (401, 403, or 404 `NOT_FOUND`;
    404 `MODEL_ARTIFACT_NOT_READY`, a 5xx or an outage are not a no). The mark is named by a salted hash of the
    credential, the native stores' tag, and sealed; the key is never written to disk.
  * With a fresh mark the kept copy opens at once, as before, also with the door down: for 24 hours after the
    door last said yes for an account's own avatar, 7 days for a public one (one the door serves with no
    credential). The door is asked again in the background; its no makes the next call fail. A public avatar's
    7 days end as soon as the door answers any account 404 `NOT_FOUND` for it (it was made private or deleted).
  * Without a fresh mark (another account, no credential, a mark that is missing, tampered with or too old) the door
    is asked first, and the call throws the new `BithumanEntitlementException` (a `BithumanAvatarException`) unless
    it says yes: `refused: true` when the door said no, `refused: false` when it could not be asked (fail closed).
    The kept files are never deleted by a refusal, and nothing is downloaded again when the door says yes.
  * **Who the door says yes to is the platform's rule** (the one `POST /v1/auth/validate` applies to an
    `agent_code`): the avatar's owner, an active member of the workspace it is shared into, or anyone when it is
    public. bitHuman's container door (`GET https://api.bithuman.ai/v1/agent/<code>/model/download`) serves the
    first two and bitHuman's public showcase; another account's public avatar outside the showcase is 404
    `NOT_FOUND` there but is served by the member door the native stores fetch from (`&member=web_manifest.json`
    for Expression 2, `&member=manifest.json` for Essence 2; Android's store: `&member=android_store.v1.json`, its Android catalog).
    So after the container door's "not yours" (404 `NOT_FOUND` to a key, 401 to no key), the gate asks that member
    door once with the same credential: its yes is a yes; anything else keeps the container's no, so the kept copy's
    marks are dropped (fail closed), and when the member door did not answer (a 5xx, a 429, a timeout) the
    exception says "could not confirm" (`refused: false`; the next open asks again). An
    Expression 2 or Essence 2 avatar another account published therefore opens as it did through 2.6.35. Exactly
    two cases differ from `validate`: a kept `.imx` (`downloadAgentImx`) follows the container door alone, as its
    download does (the platform serves another account's container only for the showcase), and a featured avatar
    its owner made private is refused (neither door serves it to another account).
  * Only the platform door's answer for the avatar's own code marks it. `downloadAgentImx` asks about a kept file
    there, never at the row's `modelUrl`; a download without a key still comes from the row's `modelUrl`, and the
    platform door is then asked once, with no credential, for the mark. A redirect is a yes only when it leaves
    bitHuman's door hosts for the signed file URL over https; hosts compare as DNS names (letter case, a trailing
    dot), so `WWW.bithuman.ai.` is a door host (bitHuman's apex redirects every path to www, and www redirects a
    trailing slash, for any code). `downloadExpression2Avatar` and `downloadExpression2Agent` take `apiSecret` and
    ask the door (`?model=expression-2`) before they download, so another account's private avatar is never
    downloaded or installed.
  * `downloadEssence2Bundle` takes `apiSecret` and asks the platform door for the entry's `agentId`
    (`?model=essence-2`), before it downloads and for a kept bundle, never the entry's `url` (which you pass and
    which is not bound to the agent). The public catalog's avatars answer with no key, as before; an account's own
    bundle needs its `apiSecret`.
  * `BithumanAvatar.load` checks a path one of these functions returned, and the folder `setExpression2AgentDir`
    named, with the `apiSecret` you pass to `load`, as the installer would: an app that saved the path cannot skip
    the check. The path is checked as the file system opens it: symlinks resolved and `.`, `..` and `//` folded,
    then the nearest folder above it that holds this package's marks (`.door-auth/`) is the cache and the first
    folder or file below it the avatar, so no other spelling (`<dir>/.`, `<dir>/sub/..`, a link from elsewhere)
    and no file inside an install escapes. Your app's own files, outside these cache folders, are not checked.
  * The first open of each kept avatar after updating asks the door once (a cache from an earlier version has no
    marks), and with the door down that one open fails. A code bitHuman's door does not know is refused.
* **iOS / macOS: an app that links Essence 2 starts on every OS the pod declares (high).** Through 2.6.35 the pods
  declared iOS 16.0 and macOS 13.0 while the staged Essence 2 engine (`essence2-v1.15.3`'s `libessence2.a`) was
  built for iOS 26 and macOS 26: an app at the declared floor could not start on iOS below 18.4 or macOS below 15.4,
  whether it used Essence 2 or not. This version stages `essence2-v1.15.4`, the same engine built at the package
  floor (iOS 16, macOS 13); Essence 2 renders on iOS 26 / macOS 26 and later and refuses by name below that at
  `load` (`unsupported`). Each pod also reads its floor from the binaries it vendors (the highest minimum of every
  device slice; a binary it cannot read counts as 26.0): iOS 16.0 and macOS 26.0 with today's engines (the
  on-device brain's macOS library is built for macOS 26; Behaviour changes 1). An app below the floor fails `pod
  install` with the floor named, and an app whose `Podfile.lock` already resolves the pod fails its build by name
  (`BHDeploymentFloor.h`; keep `$(inherited)` in your target's `GCC_PREPROCESSOR_DEFINITIONS`).
* **Android: the same rules (high).** Through `essence2-android` 0.9.3 and `expression2-android` 0.5.2 the native
  stores this plugin opens on Android had the same cross-account gap: a cached private avatar opened for any API
  secret on the phone. 0.9.4 and 0.6.0, pinned here, close it in the stores: a cached private avatar opens only for
  a credential the door said yes to; another account's gets the refusal a download would (`404 Agent not found`),
  and nothing is downloaded again for the owner. The plugin applies the owner's offline rule on top, which the
  stores' marks do not: `load` asks bitHuman's door for the code with the load's `apiSecret` when that credential's
  last yes is more than 24 hours old (otherwise at once, and the door is asked in the background), with the member
  door for another account's public avatar as above. A refusal, or a door that cannot be asked then, fails the load
  with `BithumanEntitlementException`, before the store's cache is asked.
* **A load runs, and bills, as its own credential (medium).** On Android a load of Expression 2 without `apiSecret`
  built a store whose door fell back to the process-wide credential an earlier load had set, so it could open, and
  bill, an earlier account's avatar in the same process (also after a Dart hot restart); it is now refused by name,
  as Essence 2 already was. Each Android load now fetches with its own credential and sets the engines'
  process-wide credential (which arms the session meter) only after the door's yes, immediately before the engine
  is created, under one lock: a load still downloading when the app calls `clearCredentials` is cancelled
  (`load_cancelled`) and never creates an engine with its credential, so another account signing in meanwhile is
  never billed for it; a sign-out that lands just as such a load sets its credential is caught under that lock and
  the signed-out key is emptied again, never left in the process-wide credential; and a refused load leaves the
  credential as it was. On iOS and macOS a load without
  `apiSecret` clears the engines' credential instead of keeping the last one, and an Expression 2 load renders the
  agent dir its own Dart side checked and sent with the load (`''` for none), never one another Flutter engine, a
  Dart side before a hot restart, or an account before `clearCredentials` named. New:
  `BithumanAvatar.clearCredentials()` for sign-out.

### Changed

* **`engine:` defaults to `'expression2'`.** The old default, `'essence'`, named no engine: Android refused it
  (`unsupported`) and iOS and macOS fell back to Expression 2. The fallback is now the explicit default, so a `load`
  without `engine:` loads Expression 2 everywhere. Pass `engine:` every time.
* **`BithumanRealtimeSession`'s `model` defaults to `gpt-realtime-mini`** (`BithumanRealtimeSession.defaultModel`).
  The old default, `gpt-realtime`, is served by the relay only on accounts entitled to it, so a session on a standard
  API secret that left `model` out was refused at the start (`FORBIDDEN`). Entitled accounts that want the full model
  pass `model: 'gpt-realtime'`.

### Fixed and added

* **Android, Expression 2: an installed avatar picks up updates** (`expression2-android` 0.6.0). Opening an
  avatar already on the phone returns at once and checks for a newer published version in the background, at most
  once an hour; a changed file (for example a repaired idle clip) is installed beside the old one and used from the
  next `load`. Opening an installed avatar no longer depends on the network within 24 h of the door's last yes to
  that credential (see Security). If the app is closed while the phone prepares an avatar for the first time, the
  preparation finishes in the background and the next open is fast. Your app's merged manifest gains the engine's
  job service (only the system can bind it). A session bills from its first frame, idle frames included.
* **`pushAudio` works on Android.** Until now Android had no `pushAudio`, the call the docs taught for your own
  speech: it threw `MissingPluginException`. It now takes the 16 kHz speech, converts it to 24 kHz and plays it through
  the same path as `playSpeakerPCM`, so it is heard and the lips follow it; call `notifyTurnEnd()` after the last chunk.
  On iOS and macOS `pushAudio` still moves the lips with no sound. For the same result on every platform, use
  `audioStart(enableMic: false)`, then `playSpeakerPCM` (24 kHz), `notifyTurnEnd()` and `interrupt()`.
* **Android accepts the public model ids.** `load(engine: 'essence-2')` and `load(engine: 'expression-2')` now load
  Essence 2 and Expression 2 (they failed with `unsupported`), as on iOS and macOS. `'essence2'` and `'expression2'`
  still work.
* **An unknown engine fails by name on iOS and macOS.** A name no engine has, or `'essence2'` in a build that does not
  carry the Essence 2 engine (bootstrap did not stage it), rendered Expression 2 without a word. `load` now fails with
  `PlatformException` code `unsupported`, as on Android, and the message says what to pass or how to fix the build.
* **Every channel call is answered on both platforms.** A new test (`test/channel_parity_test.dart`) checks that each
  method the Dart side calls has a branch on Android and on iOS / macOS, or is listed as unsupported with a reason.
  Android now answers the on-device brain's calls (`localAudioStart` and `localPushText` with `unsupported`; it has no
  local mode) and `isModelContainer`; iOS and macOS answer `setSpeaking` as Android does. Each threw
  `MissingPluginException` before.
* **README and pubspec.** The README's voice example now uses your bitHuman API secret through bitHuman's realtime
  relay (it showed an OpenAI key), presents iOS as supported, states the default engine, and drops `downloadAgent`
  (no such function) and a link to a private repository. The pubspec's documentation link is
  `docs.bithuman.ai/platforms/flutter`.
* **iOS / macOS: an out-of-date avatar file is named in the log** (waits for an Apple engine that refuses such files;
  the plugin's half is in place since 2.6.29).

  The log line is `[essence2] OUT-OF-DATE AVATAR FILE … download it again`, with the engine's sentence, instead of a
  bare `rc=-2 — idle only`. Download the file again
  (`GET /v1/agent/{code}/model/download`). (Essence2Kit's `Essence2Download.identity(agentCode:)` +
  `Essence2Engine.create` refresh a downloaded file by themselves.)

## 2.6.35 — 2026-10-03 — iOS / macOS: Expression 2 engine v2.20.1 (Swift package 2.20.1)

Tag `flutter-plugin-v2.6.35`. iOS / macOS Expression 2 `v2.19.2` -> **`v2.20.1`** (Swift package 2.20.1); Essence 2
`essence2-v1.15.3`, macOS `enginecore-v1.0.2` (unchanged). Android unchanged from 2.6.34: `essence2-android` 0.9.3,
`expression2-android` 0.5.2. No plugin code change.

* **Expression 2 engine v2.20.1 on iOS and macOS.** The change in 2.20.1 is in the Swift package's download stores: a
  downloaded avatar opens at once instead of waiting on bitHuman's server, and still opens when the server does not
  answer (about 90 ms instead of about 570 ms, measured by bitHuman). This plugin opens the files your app gives it and
  does not use those stores, so how the plugin opens an avatar does not change; it carries the same engine binary as
  the Swift package.

## 2.6.34 — 2026-10-03 — Android: an installed Essence 2 avatar opens in about 3 s; downloads continue in the background

Tag `flutter-plugin-v2.6.34`. Android `essence2-android` 0.9.2 -> **0.9.3** (maven.bithuman.ai); `expression2-android`
0.5.2. iOS / macOS unchanged from 2.6.31. No plugin code change.

* **An installed Essence 2 avatar opens in about 3 s (Android).** The engine keeps its compiled GPU programs per device
  and driver instead of compiling them on every open: measured by bitHuman on a Galaxy Z Flip5, 2.5–4.3 s instead of
  6.0–11.2 s (the first open after an install compiles once, about 5 s). The warm-phone gains of 0.9.2 are kept.
* **Downloads survive the background (Android).** A first download fetches several parts at once, resumes, and goes on
  as a background job when the app leaves the screen (no notification). Your app's merged manifest gains
  `ACCESS_NETWORK_STATE` and the engine's job service.
* **An avatar file installed before the mouth-corner re-publish refreshes itself (Android).** The store no longer opens such an install
  from its cache; the load downloads the changed parts (not the whole identity) and opens the current one. If the
  engine still refuses (a check that passed), the load fetches it again once and opens it — a second refusal ends the
  load with `MODEL_REJECTED`.

## 2.6.33 — 2026-10-02 — Expression 2 characters published without an idle clip no longer stay blank (Android)

Tag `flutter-plugin-v2.6.33`. Engines unchanged from 2.6.32: Android `essence2-android` 0.9.2, `expression2-android`
0.5.2; iOS / macOS as in 2.6.31.

* **Expression 2 characters published without an idle clip no longer stay blank (Android).** When a character's files
  do not include its idle clip, `expression2-android` installs none (`Expression2Avatar.idleLoopUnavailableReason`
  says why, and the plugin logs it once). The player waited for an idle frame before showing anything, so the first
  frame never came, the avatar never became ready and the screen stayed blank. Now the plugin renders one frame from a
  moment of silence and shows it until the first reply: the character appears and can talk. iOS and macOS were not
  affected (the engine shows its rest frame there).

## 2.6.32 — 2026-10-02 — Android: Essence 2 keeps moving more smoothly on a heat-throttled phone (engine 0.9.2)

Tag `flutter-plugin-v2.6.32`. Android `essence2-android` 0.9.1 -> **0.9.2** (maven.bithuman.ai); `expression2-android`
0.5.2. iOS / macOS unchanged from 2.6.31. No plugin code change.

* **Android Essence 2 engine 0.9.2: on a heat-throttled phone, Essence 2 characters keep moving more smoothly.** When
  the phone has been busy for a while and caps its GPU, the engine renders the character's 720p output and scales it
  up to the full-size frame, then returns to full resolution once the phone cools. The 720p file (~4.8 MB) is fetched
  after the first session on 0.9.2, so the step-down is available from the next session. Measured by bitHuman on a
  Galaxy Z Flip5 at its deepest throttle: about 75% of the frames the voice needs reached the screen (median), against
  37% with 0.9.1.

## 2.6.31 — 2026-10-02 — iOS / macOS: Essence 2 engine v1.15.3; the voice-gated presenter is the default again, with a stall guard

Tag `flutter-plugin-v2.6.31`. iOS / macOS Essence 2 `essence2-v1.15.2` -> **`essence2-v1.15.3`** (Swift package
2.20.0); Expression 2 `v2.19.2`, macOS `enginecore-v1.0.2`; Android `essence2-android` 0.9.1, `expression2-android`
0.5.2 (unchanged).

* **Essence 2 on iOS and macOS: the voice-gated presenter is the default again, with a stall guard.** Each frame's
  40 ms of voice is released when the frame is shown (2.6.29's presenter); now, when a display tick has no frame
  while the reply's voice is waiting, that tick's voice is released anyway and the picture catches up (the frames
  whose voice already played are skipped), so the voice never waits more than one tick (40 ms). Each firing logs
  `[bhvoice] stall-guard`. **Correction to 2.6.30:** 2.6.30 made the voice on its own clock the default and said
  that with it a slow engine is "a late face, never a broken voice"; that was not measured on a slow Apple device.
  Measured on the iPhone 18 Pro, the shipped 2.6.29 voice-gated presenter had no voice gaps (7 Sofia replies, 0 gaps
  of 40 ms or more, lip-sync about 18 ms), while the voice on its own clock needs a 200 ms cushion there (gaps of
  160–200 ms after a barge-in without it) and starts the voice later. With this release on that phone (Sofia, 4
  replies; Wise Pup, 2): 0 voice gaps of 40 ms or more, lip-sync 14–17 ms, and the first sound 189–358 ms after the
  reply's first audio for Sofia (476–592 ms with the voice on its own clock).
* **`BithumanAvatar.load(..., voiceClock: true)` (iOS, macOS, Essence 2):** opts in to 2.6.30's presenter: the voice
  starts 200 ms after the reply's first frame and plays on its own clock, and each frame is shown as its sound is
  heard. Ignored on Android and by Expression 2.
* **Skip-ahead on iOS and macOS now links** against `essence2-v1.15.3`. It stays opt-in (`skipAhead: true`) and
  acts with `voiceClock: true`; on the iPhone 18 Pro it rarely has anything to skip.
* Expression 2 on iOS and macOS writes the same per-reply `[bhvoice] REPLY` log line (voice gaps, first sound, A/V).

## 2.6.30 — 2026-10-02 — Essence 2's voice no longer waits for the picture on iPhone and Mac; downloadAgentImx fetches today's catalog

Tag `flutter-plugin-v2.6.30`. Engines unchanged: iOS / macOS Expression 2 `v2.19.2`, Essence 2 `essence2-v1.15.2`,
macOS `enginecore-v1.0.2`; Android `essence2-android` 0.9.1, `expression2-android` 0.5.2.

* **Essence 2's voice plays on its own clock (iOS, macOS).** Until now the Apple presenter released each frame's
  40 ms of voice only when that frame was shown, so an engine running behind was heard as a choppy voice. The voice
  now opens a short cushion after a reply's first frame is ready (200 ms) and then plays without waiting; each frame
  is shown when its audio is heard. A frame whose audio has gone by is dropped while a newer one is ready, and the
  newest is shown even when late, so a slow engine is a late face, never a broken voice or a frozen face. Measured on
  an M4 Mac (Sofia, greetings and barge-ins, 9 replies a side): A/V offset within 3 ms (8 ms before), 0 voice gaps,
  and the ~10 sub-2 ms breaks per reply the per-frame release left are gone; the first word comes the cushion later.
  One `[bhvoice] REPLY` log line per reply carries the voice gaps, first sound and A/V offset. Expression 2 is
  unchanged.
* **Skip-ahead on iOS and macOS, with an Essence 2 engine that has it.** `BithumanAvatar.load(..., skipAhead: true)`
  (Android's option, off by default) now also reaches Apple: the presenter tells the engine where the voice is and
  places each frame by the engine's own index. The pinned Essence 2 engine (`essence2-v1.15.2`) has no skip-ahead, so
  on Apple the option takes effect with the next engine (essence2-apple v1.15.3); the plugin compiles the calls in
  only when the engine it is built with has them.
* **`downloadAgentImx` fetches today's catalog.** It follows the door's redirect to the signed file URL (redirects
  issued by a bitHuman door, or to a host on `allowedHosts`; https only), takes `apiSecret:` (the key goes to the
  door only, never to the file host), and says what it can download: a gallery Essence 2 character anonymously, and
  any character the key's account owns; another account's Essence 1 / Expression 1 character is refused with an
  explanation (401 / 404). A kept file opens at once; whether it is still the published one is checked in the
  background and a changed file downloaded for the next open; a kept Essence 2 file from before the 2026-10-01
  re-publish is fetched again once. `BithumanAgent` gains `modelType`; `kBithumanModelHosts` is exported.
* **Android: skip-ahead stays off by default.** On the Galaxy Z Flip5 (12 runs a side, a cool and a warm phone),
  skip-ahead showed more of a reply's frames than without it (greetings 83% vs 68%, barge-ins 73% vs 69%) but three
  of its runs still had a second of frozen face, so it stays opt-in (`skipAhead: true`).
* `scripts/bootstrap.sh`: `ESSENCE2_XCF_DIR=<dir>` stages a candidate Essence 2 engine.

## 2.6.29 — 2026-10-02 — Essence 2 keeps moving while it talks (Android); a model the engine refuses ends the call; a faster voice start (Expression 2 only)

Tag `flutter-plugin-v2.6.29`. Android `essence2-android` 0.9.0 -> **0.9.1** (maven.bithuman.ai), `expression2-android`
0.5.2. iOS / macOS engines unchanged: Expression 2 `v2.19.2`, Essence 2 `essence2-v1.15.2`, macOS
`enginecore-v1.0.2` (Swift package 2.19.4).

* **Sofia and every Essence 2 character keep moving while they talk (Android).** On the Galaxy Z Fold5 and Z Flip5
  `essence2-android` 0.9.0 rendered well below the 25 frames a second the voice needs, and the face froze behind the
  voice. 0.9.1 keeps its threads on the fast cores and walks the idle video forward only. **Skip-ahead, opt-in:**
  `BithumanAvatar.load(..., skipAhead: true)` also tells the engine where the voice is, so a phone that still renders
  below real time skips a frame whose audio has already been heard and shows the newest one; each frame shown sits on
  its own audio, so the lips stay in step. It is off by default in this release. The skipped count is in the
  player's `PROD` log line (`skipped=`) and the engine's `[le-skip]` line.
* **New error code `MODEL_REJECTED` (iOS, macOS, Android).** When the on-device engine refuses to create from the
  model file (a file it cannot open, `be_essence2_create` -2 on iOS / macOS, or an Expression 2 model whose files it
  refuses), `BithumanAvatar.load` throws `BithumanModelRejected` (`code`, `engine`, `nativeCode`, and a `message` with
  the engine's own sentence), and a `BithumanRealtimeSession` on that avatar ends with `MODEL_REJECTED` on
  `errorStream`, torn down exactly like a `PAYWALL`. Until now iOS and macOS showed a still face and never became
  ready, and Android failed the load as `load_failed`. Expression 2 on iOS / macOS reports its refusal after `load`
  (its warm-up runs later) through `BithumanAvatar.modelRejections`; `ready` completes then. **Source change for
  custom voice hosts:** `VoiceHost` gains `modelRejections` (a host without an engine may return an empty stream).
* **The coverage log counts what the viewer sees (Android).** `COVERAGE … cov=` is now unique speech frames shown ÷
  frames due for the audio played; it used to count a held frame shown again under its audio, and read 86-93% on a
  frozen face. One `bhcov UTT` line per utterance, and a `bhcov FROZEN` line when, for more than a second, the last
  second of voice showed fewer than half its frames.
* **Faster voice start, Expression 2 only (Android).** A reply's first words no longer wait for the silence
  already queued for the speaker while the character was idle: when everything the speaker still holds is silence,
  it is dropped and the reply starts at once, and its first frame goes up when the speaker reports that voice
  playing. Measured on a Galaxy Z Fold5 with Expression 2 (first voice byte to first heard sample, median):
  1.24 s -> 0.91 s with the next `expression2-android` (1.76 s with 0.5.2). Essence 2 keeps the previous start:
  that silence is the lead its frames need, and without it the face froze behind the voice.

## 2.6.28 — 2026-10-01 — the character's own voice no longer cuts it off; Sofia opens without waiting on the network; a paywall ends the call cleanly

Tag `flutter-plugin-v2.6.28`. Engines unchanged: iOS/macOS Expression 2 `v2.19.2`, Essence 2
`essence2-v1.15.2`, macOS `enginecore-v1.0.2` (Swift package 2.19.4); Android `essence2-android`
0.9.0, `expression2-android` 0.5.2.

* **The character's echo no longer interrupts it (iOS, macOS, Android).** On a loudspeaker, the
  echo canceller lets short bursts of the character's own voice reach the microphone, and the
  realtime service could take them for the person talking over it. While the character is heard,
  and for half a second after, the session now passes the microphone to the service only when it
  is close in level to the voice heard (within `BithumanRealtimeSession.bargeFloorDb`: by default
  11 dB on Android, 18 dB on iPhone and macOS) and stays there for 200 ms. Quieter sound, the
  echo, goes up as silence. A person talking over the character still cuts in, about 100 ms
  later than before. The opening-seconds guard now follows the voice as it is heard, not when
  the reply arrived. A sound in the room while the character is silent still counts as speech.
* **Sofia and every Essence 2 character open without waiting on the network (Android).** A
  character already on the phone opens from its verified local copy at once; the check for an
  updated version runs after it is live, and an update is used from the next open. On a Galaxy
  Z Fold5 and Z Flip5, Sofia's launch to live went from 5.9 s / 9.2 s to 4.2 s / 4.5 s (medians).
* **A paywall ends the call, and any session that ends on an error releases everything
  (iOS, macOS, Android).** The relay's `PAYWALL` (no Live minutes left) is now a terminal error
  on `errorStream`, like `INSUFFICIENT_BALANCE`. After a terminal error the session also turns
  the microphone and speaker off, ends the captions and closes its streams; until now it only
  closed the connection. Such a session cannot be started again: build a new one.
* **Captions of a reply cut short show only what was said (iOS, macOS, Android).** When a reply
  is cancelled part-way, or a reconnect loses its end, `spokenTranscriptStream` no longer
  releases its whole transcript: it stops at the words its received audio can have carried.

## 2.6.27 — 2026-10-01 — captions in step with the voice; no crash when the app closes on Android; privacy manifest shipped

Tag `flutter-plugin-v2.6.27`. Engines unchanged: iOS/macOS Expression 2 `v2.19.2`, Essence 2
`essence2-v1.15.2`, macOS `enginecore-v1.0.2`; Android `essence2-android` 0.9.0,
`expression2-android` 0.5.2.

* **Captions in step with the voice (iOS, macOS, Android).** A reply's text and audio reach the app
  together, well before the voice has spoken them, so a caption built from `botTranscriptStream`
  showed the end of a reply while the character was still on its first sentence.
  `BithumanRealtimeSession.spokenTranscriptStream` releases the agent's words as they are heard:
  each `BithumanSpokenText` is the reply's caption so far (`text`, cumulative; a new `reply` number
  starts a new caption), and the reply's last event is `isFinal`. A barge-in, a typed turn or
  `stop()` ends the caption with only the words heard (`interrupted`). The position comes from the
  audio host, which now reports how much of the agent's audio has been heard
  (`BithumanAvatar.speechPlayout`, `BithumanPlayout {played, fed}`). `botTranscriptStream` is
  unchanged. **Source change for custom voice hosts:** `VoiceHost` gains `speechPlayout`; an
  implementation that cannot tell may return an empty stream, and captions are then estimated
  from when the audio was handed over.
* **No crash when the app closes with an avatar on screen (Android).** Leaving the app with Back
  while a character was shown could end in "FlutterJNI is not attached to native" (seen on some
  devices). The avatar's texture is now released at once when Flutter lets go of the
  plugin, before anything else is closed.
* **Privacy manifest shipped (iOS, macOS).** The plugin's `PrivacyInfo.xcprivacy` declares the
  file-timestamp (C617.1) and system-boot-time (35F9.1) APIs it uses, and is bundled into the app
  as `bithuman_privacy.bundle`.
* **Release builds keep what people say out of the device log.** A release build logs only the
  length of a transcribed turn, never its words.
* **The Android engines never come from a local Maven cache.** `mavenLocal()` no longer serves the
  `ai.bithuman` group, so a build always resolves the published engine.

## 2.6.26 — 2026-10-01 — no seam at the mouth corners; the Android engine comes from maven.bithuman.ai

Tag `flutter-plugin-v2.6.26`. Engines: iOS/macOS Expression 2 `v2.19.2`, Essence 2
`essence2-v1.15.2`, macOS `enginecore-v1.0.2` (Swift package 2.19.4); Android `essence2-android`
0.9.0, `expression2-android` 0.5.2.

* **No seam at the mouth corners (Essence 2, every platform).** The generated mouth is now blended
  into the photo with a wider, feathered edge, so the step that could show at the mouth corners while
  the avatar talks is gone. Android takes it with `essence2-android` 0.9.0. On iOS and macOS it
  arrives with the avatar files themselves, and Essence 2 `essence2-v1.15.2` carries it on the
  engine's fallback renderer too. No API change.
* **The Android engine resolves from maven.bithuman.ai; apps add nothing.** bitHuman publishes its
  Android engines to its own Maven repository, https://maven.bithuman.ai, and `essence2-android`
  0.9.0 is the first version served only there. The plugin declares that repository for the
  `ai.bithuman` group in every project of the app, so a Flutter app needs no change to its Gradle
  files. Versions already on Maven Central keep resolving from Central.
* **macOS 13 links again (macOS).** The macOS engine core is built for macOS 13
  (`enginecore-v1.0.2`); with `enginecore-v1.0.1` an app targeting macOS 13 failed to link
  ("built for newer 'macOS' version (14.0)").

## 2.6.25 — 2026-09-30 — the call ends when the phone rings; earbuds keep the call; smoother Android texture; faster first frame

Tag `flutter-plugin-v2.6.25`. Engines unchanged: iOS/macOS Expression 2 `v2.19.2`, Essence 2
`essence2-v1.15.1`, macOS `enginecore-v1.0.1`; Android `essence2-android` 0.8.1,
`expression2-android` 0.5.2.

* **A phone call ends the session (iOS, Android).** A call answered from its banner (iOS) or its
  notification (Android) leaves the app on screen. The audio paused, but the realtime session went
  on and was billed under the call. The platform's interruption now reaches Dart as
  `BithumanAvatar.audioInterruptions` (`BithumanAudioInterruption`: `began`/ended, `reason`
  `call` | `focus` | `system`, `shouldResume`). `BithumanRealtimeSession` forwards it on
  `interruptionStream` and, by default (`endOnAudioInterruption: true`), stops itself on `began`, so
  nothing more is billed; `endedByInterruption` says why. iOS reports its audio-session
  interruptions (a call ringing or answered, Siri, an alarm; `call` when CallKit sees a call).
  Android now holds transient audio focus for the call, as a call app does. It reports a lost focus
  (a phone call, another app's call, an assistant; a duck request is not one) and, on Android 12
  and later, a phone call's audio mode. A call already holding the audio when the session starts is
  reported at once and the session ends quietly (Android keeps the microphone closed; iOS refuses
  the audio unit after reporting it).
* **Bluetooth earbuds and headsets keep the call (Android, iOS).** When the microphone opened,
  Android forced the loudspeaker whatever was connected, and iOS overrode the route to the speaker
  as well. Now a connected Bluetooth headset (classic or LE Audio), a wired or USB headset, USB-C
  headphones or a hearing aid keeps the call. The loudspeaker is chosen only when none is
  connected. A device that comes or goes during the call re-routes it (`[bhroute]` lines on
  Android). When a headset does not take the call (its link fails), the call falls back to the
  loudspeaker.
* **The microphone opens and closes off the UI thread (Android).** On a Galaxy Z Flip5, opening it
  (the audio mode, the route, the recorder) held the platform thread ~0.9 s at every dial (104
  frames skipped), and closing it ~0.5 s at every hang-up (58 frames). Both now run on one serial
  thread, in order; the microphone joins the call a moment after it opens.
* **The avatar texture is a SurfaceProducer (Android).** Under Impeller a SurfaceTexture cost
  ~10 ms of raster per frame through a GLES interop. Galaxy Z Flip5 at 120 Hz, idle: raster p50
  10.4 → 5.1 ms, frames over budget 321/357 → 2/351.
* **An Expression 2 container is expanded once, off the platform thread (iOS, macOS).** Every cold
  start and character switch used to rewrite ~200 MB on the UI thread. The container now expands
  once and is reused when its record matches (iPhone 15: 0.32–0.54 s → 0.01 s).
* **Readiness is polled at 40 ms for the first 3 s** (was 500 ms), then 250 ms, then 1 s after
  ~10 s: the character appears up to ~0.5 s sooner. Launch to live character, cached: Flip5
  2.98 → 2.60 s, iPhone 15 2.87 → 2.61 s, M4 Mac 2.27 → 1.80 s.
* **No orphan session when the engine detaches mid-load (Android).** A load that finished after
  the Flutter engine detached registered a session nobody could stop, and its player ran on. It now
  closes what it made.

Compatibility:
* `VoiceHost` has one more member, `audioInterruptions` (a broadcast stream: the session listens on
  every `start()`). A class of yours that `implements VoiceHost` adds it; one that never
  interrupts returns an empty broadcast stream.
* A session now ends on every interruption's `began`, not only a phone call's: Siri or an
  assistant, an alarm, another app's call or playback taking the audio. Pass
  `endOnAudioInterruption: false` to keep a session open and decide from `interruptionStream`.
* On Android the call holds transient audio focus, as a phone call does: music in another app
  pauses during the call and resumes after it.
* The transports in `realtime_transport.dart` do not forward interruptions yet; their sessions
  still end on them, and a transport reports `closed`.
* iOS links CallKit, for `CXCallObserver` only (to tell a phone call from other interruptions). The
  plugin places, reports and answers no calls.
* Bluetooth adds its own output latency. A Bluetooth headset keeps the call now, and lip-sync has
  not been measured on one yet.

## 2.6.24 — 2026-09-30 — security: the Apple engines take the metering fix

Tag `flutter-plugin-v2.6.24`. Engines: iOS/macOS Expression 2 `v2.19.2`, Essence 2
`essence2-v1.15.1`, macOS `enginecore-v1.0.1` (unchanged); Android `essence2-android` 0.8.1,
`expression2-android` 0.5.2 (unchanged).

* **Security (iOS, macOS).** The on-device meter in a release build ignores its tuning settings,
  so usage is always billed as the service defines it. Update to this version.
* **A lost credential check no longer refuses the session (iOS, macOS).** When the startup check
  gets no answer, a 5xx or a 429, the engine asks once more after 250 ms. A 2xx or a rejection is
  never repeated.

## 2.6.23 — 2026-09-30 — dispose is safe at any moment; no Mac freeze at hang-up; echo-onset guard; Android load progress and cancel

Tag `flutter-plugin-v2.6.23`. Engines unchanged: iOS/macOS Expression 2 `v2.19.0`, Essence 2
`essence2-v1.15.0`, macOS `enginecore-v1.0.1`; Android `essence2-android` 0.8.1,
`expression2-android` 0.5.2.

* **Dispose is safe at any moment (Android, iOS, macOS).** On Android `dispose` closed the engine
  while the player's threads were still inside it: the producer could be decoding an idle frame
  when the decoder was released, and the writer could read the position of an audio track that had
  just been released. Either threw on a player thread and the app crashed — for example when a
  character the person had switched away from finished loading and was disposed at once. Now every
  thread that uses an engine is stopped and joined before the engine is closed, once; the join and
  the close run off the UI thread, and on Android `dispose()` returns when the engine is closed. A
  thread that is still inside the engine after 30 s leaves it open (logged) instead of closing it
  under that thread, and an exception on a player thread is logged (the picture holds its last
  frame) instead of ending the app. `setIdleHold(false)` never starts a fresh player beside a held
  one that is still running. Apps no longer need to hold the avatar and wait before `dispose()`.
  On iOS and macOS `dispose()` returns at once as before, and the engine is released after the
  render ticks and the Expression 2 warm-up thread are done with it; that release is no longer
  skipped when the texture object was freed first (the engine's shutdown did not run).
* **No greeting over a still face.** `BithumanRealtimeSession(speechReady: avatar.ready)` holds the dial
  (and so the connect greeting) until the engine's speech path is live (max 60 s, logged as
  `[bhready]`). Measured 2026-09-28 on an iPhone 15: the greeting's first delta landed 12:22:40.6 and
  the Expression 2 warm-up finished 12:22:46.3 — ~6 s of greeting with no lip-sync. Optional; apps
  that already await `avatar.ready` before `start()` are unchanged.
* **Echo-onset guard (iPhone, Android).** For the first `echoOnsetGuard` of agent audio in a session, mic
  chunks captured while the agent is audible and whose peak is below −18 dBFS go up as digital silence
  (the uplink stays continuous). The iPhone 15 loudspeaker run of 2026-09-28 had two false
  `speech_started` barge-ins in the first reply, on canceller-onset residuals of −28 / −23 / −27 dBFS
  peak; a person talking to the phone is far above the floor and still cuts the agent. The window
  counts audible time (the canceller's clock), so a long reply that arrives in one burst is guarded
  while it plays. The default is the device's `EchoProfile.onsetGuard`: 8 s on iPhone and Android (a
  Galaxy Z Flip5 at its lowest call volume had one false `speech_started` ~3 s into the greeting in each
  of 2 runs without it, none with it), off on macOS, whose measured residual sits far below the floor.
  `Duration.zero` disables it; dev A/B lever `--dart-define=BH_ECHO_GUARD_MS=<ms>` (not in release).
  Logged as `[bhecho]`.
* **`vadThreshold` is optional and documented as LOCAL-mode only.** The relay/OpenAI session's barge
  is server VAD; the constructor's required `vadThreshold` never reached anything, and the native line
  `[bhduplex] GATE off (vad_threshold=0) — this session cannot be interrupted by the microphone` read
  as "barge-in is broken" to an app passing `vadThreshold: 1500`. The native line now says the local
  gate is off and the barge is the transport's, and the session logs
  `[bhduplex] transport barge=server_vad threshold=… interrupt_response=1`.
* **macOS: hang-up / character switch no longer freezes a speaker-only session.** `RealtimeAudioIO.stop()`
  removed the mic tap unconditionally; on an engine that never had an input, `engine.inputNode`
  instantiates one and binds the input device synchronously on the platform (= UI) thread, which never
  returned (sampled on an M4 iMac: `AVAudioIOUnit_OSX::EnableInputDevice` →
  `HALC_ShellDevice::CreateIOProcID`). Now guarded on `micActive`, as the iOS branch already was.
* **Android:** `BithumanAvatar.loadEvents` reports what a native `load` is doing while it runs,
  so a wait screen can show real progress instead of measuring the download folder: `fetch`
  (bytes on disk against the identity's exact size, about 8 a second; a resumed download starts
  from what it already has), `fetched` (`cached` when nothing had to be downloaded), `prepare`
  (the engine is being created; a first open also compiles it for the device) and `prepared`.
  Each `BithumanLoadEvent` carries the agent `code` and the time since that load began.
  Subscribe before calling `load`.
* **Android:** `BithumanAvatar.cancelLoad(code)` stops a running `load` of that code, for example
  when the user picks another character mid-download. The download stops at its next read and
  keeps what it has (the next `load` of that code resumes it), an engine that is being created is
  closed as soon as it exists, and that `load` throws `PlatformException(code: 'load_cancelled')`.
  It returns whether a load was cancelled.
* Additive: an app that neither listens nor cancels sees no change. The events use their own
  channel, `ai.bithuman.avatar/load` (native → Dart `event {code, stage, done, total, cached, ms}`,
  Dart → native `cancel {code}`), and the native side sends the next event only after Dart has
  answered the last, so an app without a listener gets no warnings about discarded channel
  messages. On iOS and macOS `load` opens a local path and downloads nothing (the download helpers
  report their own `onProgress`), so no events arrive there and `cancelLoad` returns false (it also
  returns false, rather than throwing, when the native side answers with an error).
* Tests: `EngineUsersTest` (Android, plain JVM: `scripts/test_android_unit.sh <app dir>`) covers
  dispose mid idle decode, before any thread ran, twice, with a held player winding down, and a thread
  stuck inside the engine, with a negative control for the old order. The headless voice test now
  expects the host's own echo-profile gain (it failed on every macOS host), and `flutter analyze`
  reports no issues.

## 2.6.22 — 2026-09-28 — security fix: restrict internal symbols in the macOS engine core

Tag `flutter-plugin-v2.6.22`.

* **Security (macOS):** the macOS `EngineCore` moves to `enginecore-v1.0.1`, a rebuild that keeps
  only its public C doors linkable. Please update. iOS is unaffected; Expression 2 and Essence 2
  are unchanged (`v2.19.0` / `essence2-v1.15.0`). Run `scripts/bootstrap.sh` again.

## 2.6.21 — 2026-09-28 — engine update; macOS EngineCore included

Tag `flutter-plugin-v2.6.21`.

* **iOS/macOS:** Expression 2 moves to the Swift package's `v2.19.0` binaries and Essence 2 to
  `essence2-v1.15.0` (both sha256-checked by `scripts/bootstrap.sh`, and the same bytes as Swift
  package 2.19.0). On macOS the engines' licensing and metering core is now linked once from
  `EngineCore` (a plain static library from the `essence2-v1.15.0` release): `bootstrap.sh`
  stages it and the macOS pod links it with `Security` and `curl`. iOS links nothing from it.
  Run `scripts/bootstrap.sh` again after upgrading.
* **Android:** unchanged — `ai.bithuman:essence2-android` 0.8.1 and `ai.bithuman:expression2-android` 0.5.2.
* Sessions bill active session time, talking or idle (the service's rule since 2026-09-26); the
  comments that still said "talking time only" are corrected.

## 2.6.20 — 2026-09-27 — Realtime voice through bitHuman's relay; iOS/macOS link the published engines

Tag `flutter-plugin-v2.6.20`.

* **Realtime voice:** `BithumanRealtimeSession(apiKey: …)` now takes your **bitHuman API secret** and
  dials bitHuman's realtime relay (`wss://api.bithuman.ai/v1/realtime`). The relay speaks the OpenAI
  Realtime protocol and bills the conversation to your account (10 credits per minute, the avatar
  included); the plugin sends no meter of its own. There is no `ek_…` token to mint any more:
  `RealtimeService.mintEphemeralToken` is deprecated and the mint endpoint is being retired. An OpenAI
  API key (`sk-…`) still dials OpenAI directly. A refusal a retry cannot fix (a rejected secret, no
  credits, a plan without realtime, the session time limit) stops the session once and is reported
  on the new `errorStream` / `lastError`; it no longer loops through reconnects. The WebRTC opt-in
  needs an OpenAI key; with a bitHuman secret it uses the relay.
* **iOS/macOS:** the Expression 2 engine is linked as the published Swift package binaries
  (`Expression2`, `BithumanEngineProtocol`, `UnifiedModelHeader` from tag `v2.18.0`, sha256-checked);
  the build no longer fetches engine source from anywhere. Essence 2 moves to `essence2-v1.14.2`
  (memory stays flat in long sessions that feed audio without pauses).
* **Android:** `ai.bithuman:essence2-android` 0.8.0 -> **0.8.1** (the same long-session memory fix) and
  `ai.bithuman:expression2-android` 0.5.1 -> **0.5.2**.

## 2.6.19 — 2026-09-26 — Android: Essence 2 frames reach the screen without a CPU copy; both engines fixed billing

Tag `flutter-plugin-v2.6.19`.

* **Android:** `ai.bithuman:essence2-android` 0.6.0 -> **0.8.0**, and the Essence 2 path uses the SDK's
  zero-copy delivery: the GPU renders each frame into a hardware buffer (32 of them, the SDK's
  maximum from 0.8.0), the player keeps it in its ring as a hardware `Bitmap`, and the texture is drawn
  with a hardware canvas. Before, every frame was read back from the GPU, copied into a `ByteBuffer`,
  copied into a `Bitmap` and blitted by the CPU (three 8.3 MB copies at 1920x1080, 25 times a second).
  Measured on a Galaxy S25+ (Essence 2, 1920x1080, four scripted replies, two runs per arm, the same
  engine bytes with and without it): process CPU **1.65-1.73 cores vs 1.84-1.85**, GPU busy
  26.7-27.1 % vs 23.4-23.6 %, delivered 25 fps while talking in every run, presenter backlog
  (`coalesced`) 18-27 vs 46, stale 0 in all runs. Same pixels.
  A device without the SDK's GPU compositor keeps the copy path and logs why.
  Debuggable host apps can force the copy path with `adb shell setprop debug.bh.e2.copy 1` for A/B runs.
* **Android:** `ai.bithuman:expression2-android` 0.5.0 -> **0.5.1** and `essence2-android` 0.8.0 carry the
  billing fixes: each installation names itself on the meter, the meter's endpoint can only be a
  bitHuman host, and essence-2's frame rate for billing is fixed in compiled code.
* **Android:** a failed load now logs the exception's own message. `android.util.Log` prints no stack
  trace when the cause is an `UnknownHostException`, so a failed download used to log only
  `load failed`.
## 2.6.18 — 2026-09-26 — iOS/macOS: the Essence 2 engine names its install on every usage report

Tag `flutter-plugin-v2.6.18`.

* **iOS/macOS:** the Essence 2 engine moves to `essence2-v1.14.0` (libessence2 `00f4c612…`, resources
  `151e5228…`). Its usage reports carry a per-install id (a random UUID kept in the app's Application
  Support directory) instead of an empty one; set `BITHUMAN_INSTALL_ID` to choose it yourself. The engine's
  C interface gains two additive calls; the plugin's adapter is unchanged (bithuman-models #1473).

## 2.6.17 — 2026-09-25 — iOS/macOS: an app can link its own MLX beside the Essence 2 engine

Tag `flutter-plugin-v2.6.17`.

* **iOS/macOS:** the Essence 2 engine moves to `essence2-v1.13.0` (libessence2 `ada8bbb0…`, resources
  `11843e96…`). The engine no longer carries a private copy of MLX, so an app that links its own
  MLX (mlx-swift) links beside it — CocoaPods adds `-ObjC`, which made the old engine's copy collide
  (bithuman-models #1461). The engine library is 22 MB instead of 171 MB, and the resources archive
  no longer ships an `mlx-swift_Cmlx.bundle` (the pod's `*.bundle` glob is empty and that is correct).
  The engine adapter source stays at bithuman-models `fd37bdfb7`: the C interface is unchanged.

## 2.6.16 — 2026-09-24 — Android: Expression 2 lip sync, faster first frame after a pause

Tag `flutter-plugin-v2.6.16`.

* **Android:** `ai.bithuman:expression2-android` 0.4.10 -> **0.5.0**: the first frame of each stream is
  shown twice, so the mouth no longer leads the voice (the same fix iOS/macOS got in 2.6.15).
* **Android:** `ai.bithuman:essence2-android` 0.5.15 -> **0.6.0**: the first frame after a listening
  gap arrives sooner (1,090 -> 242 ms on a Galaxy S25+); renders are otherwise bit-identical.
* Both AARs retry a failing download on one shared budget per store instead of per file.

## 2.6.15 — 2026-09-23 — Expression 2 lip sync on iOS and macOS

Tag `flutter-plugin-v2.6.15`.

* **iOS/macOS:** Expression 2 moves to v2.7.0 (UnifiedModelHeader `8cd64a4a…`) and the engine source
  to bithuman-models `fd37bdfb7`: a stream's first frame is presented one extra time, so the mouth no
  longer leads the voice (SyncNet v2: about -65 ms before, about -15 ms after). Essence 2 is unchanged
  (essence2-v1.12.1).

## 2.6.14 — 2026-09-23 — the Essence 2 engine links without warnings

Tag `flutter-plugin-v2.6.14`.

* **iOS/macOS:** the Essence 2 engine moves to `essence2-v1.12.1` (libessence2 `64b6635b…`, resources
  `d5247f61…`) and the engine adapter source to bithuman-models `8bae6d8f3`: the slices no longer name
  module-cache files in their debug info, so an app's link prints no `.pcm: No such file or directory`
  warnings (#1263). The engine's code is unchanged.

## 2.6.13 — 2026-09-23 — one credential setter on Android, and the Essence 2 engine without link warnings

Tag `flutter-plugin-v2.6.13`.

* **Android:** `ai.bithuman:essence2-android` **0.5.14 → 0.5.15** and `ai.bithuman:expression2-android`
  **0.4.9 → 0.4.10** (bithuman-models #1223). The plugin sets the API secret through the one setter each
  SDK now has — `Essence2Credential.set` / `Expression2Credential.set` — which covers the download and
  the session; the deprecated `*Metering.apiSecret` it used before still works in older apps.
* **iOS/macOS:** the Essence 2 engine moves to `essence2-v1.12.0` (libessence2 `921c64b6…`, resources
  `e9b4f870…`) and the engine adapter source to bithuman-models `6ff1fd069`: `be_essence2_last_refusal`,
  and slices that carry no builder path and no `CoreAudioTypes` autolink, so an app link no longer warns
  (#1224).

## 2.6.12 — 2026-09-23 — every engine bills talking time only, and Expression 2 needs the API secret on both platforms

Tag `flutter-plugin-v2.6.12`.

* **Android:** `ai.bithuman:expression2-android` **0.4.8 → 0.4.9** (its first on-device session
  meter) and `ai.bithuman:essence2-android` **0.5.13 → 0.5.14** (talking-time billing, the 300 s
  online grace, a never-vouched key renders nothing). The expression-2 load path sets
  `Expression2Metering.apiSecret` from the `apiSecret` the app passes, as the essence-2 path
  already did — without an API secret 0.4.9 refuses to create a session.
* The iOS/macOS half now pins the Apple engines the Swift package serves at v2.14.2:
`essence2-v1.11.0` (libessence2 `08511e16…`, resources `3024f455…`), UnifiedModelHeader
`v2.6.5` (`5e3e56a0…`), and engine adapter source bithuman-models `ec9a3ab83`.

* **Expression 2 is metered on Apple from this engine on.** `EngineRegistry.make` passes the
  `apiSecret` the app hands `load` to `Expression2Credential.set` before creating the engine.
  Without it a Release build of Expression 2 v2.6.5 refuses to render (an installed app has no
  `BITHUMAN_API_SECRET` in its environment) — the essence-2 branch already did the same.
* Both engines bill **talking time only**; idle is free. After the service has vouched for the
  key, an outage keeps rendering for 300 s of frames, then pauses until it answers again.

## 2.6.11 — 2026-09-23 — the container is the engine's to read

Tag `flutter-plugin-v2.6.11`.

**This package no longer carries a reader for bitHuman's model container.** The container
format is proprietary (owner ruling 2026-09-16: closed source, private repositories only), and
until this release `lib/bithuman.dart` expanded it in Dart — in a public repository. The Dart
reader is deleted. The engine, whose compiled code already reads the container, now expands it
through the platform channel. The public Dart API is unchanged.

* **`downloadExpression2Avatar`**: a download that is a zip still goes through `unzip`; anything
  else goes to the new native method `unpackModelContainer`, which the Apple half answers with the
  engine's own unpacker (off the platform thread). Android answers `unsupported` by name, because
  it loads an identity by code (`BithumanAvatar.load`) and never needed a container on disk.
* **`downloadAgentImx`** no longer compares magic bytes in Dart. It asks the engine
  (`isModelContainer`); where the engine cannot tell (Android), the load itself refuses a bad file.
* **Both expression-2 installers now require the per-identity decoder `dec_p2_v3_all`.** The
  pinned engine refuses an identity without it, so an install without it rendered nothing. It is
  now refused at install, by name, and an earlier install without it is fetched again instead of
  re-used. This is the defect behind the product app's dead gallery (12 of 12 identities).
* CI: the container-reader ratchet in `flutter-plugin-tests.yml` is at **0**, and
  `test/avatar_install_test.dart` pins the new shape (8 arms, network-free).

★**Exposure, recorded rather than rewritten.** The reader was in this public repository from
2026-06-30 (`32e0bb4`) until this release, and every tag cut in that window carries it. Nothing was
ever published to pub.dev (its API answers 404 for the package), so the exposure is git history
and GitHub tag archives. Deleting it is mitigation, not erasure; history is not rewritten.

## 2.6.10 — 2026-09-23 — the Apple half builds again from a clean clone

Tag `flutter-plugin-v2.6.10`.

**`flutter-plugin-v2.6.8` and `v2.6.9` do not build a macOS app from a clean clone** (measured on
both). The bootstrap's Expression 2 step refused its own model bundle, stopped before it copied the engine
source into the pod, and the app build then failed at `cannot find 'Expression2Engine' in scope`.
That error was never an interface mismatch with the Swift SDK; the engine source was simply not
there.

* **The model bundle is cut to the two shared graphs.** The pinned vendor bundle (2026-07-01)
  carries one demo face whose per-identity decoder, `dec_p2_v3_all`, the current engine requires
  and the bundle does not have. The bootstrap now keeps only `w2v_frontend` and `audiotokenizer`,
  the shape the engine's own check accepts ("identity-free"). Every face reaches the engine as an
  `.avatar`, which carries its own decoder. The app gets ~108 MB smaller; the digest pin on the
  download is unchanged.
* **`UnifiedModelHeader` is the Swift SDK tag's bytes.** The pod staged `v2.6.3` while
  `Package.swift` (Swift SDK `v2.14.1`) serves `v2.6.4`. It now stages `v2.6.4`
  (`eb5fde20…`), and `scripts/check-apple-engine-pin.sh` refuses a commit where the two differ
  (A6, with two negative arms in `apple-engine-pin.yml`).

Engine coordinates are unchanged: the adapter source is bithuman-models `05e443da9`, the
engine `essence2-v1.10.0`, the same bytes Swift SDK `v2.14.1` serves.

**Measured 2026-09-23 on a Mac with a clean clone of the product app** pinned to this change, cold
pub cache. The bootstrap reported `identity-free bundle OK`, and staged expression2 + essence2 and
UnifiedModelHeader v2.6.4. The app's 30 unit tests passed. `flutter build macos --debug` succeeded:
the app carries `Expression2Engine` and `_be_essence2_create`, `Resources/embody` holds
`w2v_frontend` + `audiotokenizer` and no face, and the app is 434 MB.

The app's session test passed on Expression 2: launch, engine ready, call, a scripted reply, a
barge-in cancel, a typed turn and hang-up. Essence 2 rendered from a current published identity:
the engine was ready at 1920x1080, texture frames flowed, and a metered beat was delivered.

## 2.6.9 — 2026-09-23 — both Android engines move to Central's current: expression2-android 0.4.8, essence2-android 0.5.13

Tag `flutter-plugin-v2.6.9`.

* `ai.bithuman:expression2-android` **0.4.7 → 0.4.8**. 0.4.8's POM declares the Qualcomm Hexagon
  delegate and runtime (`com.qualcomm.qti:qnn-litert-delegate` / `qnn-runtime` 2.49.0) itself, so the
  two lines this plugin declared by hand for 0.4.7 are **deleted**; they still resolve, transitively.
* `ai.bithuman:essence2-android` **0.5.12 → 0.5.13** (public 2026-09-23): the AAR ships its own keep
  rule for its JNI bridge, so a consumer's R8 cannot rename it whatever its `proguardFiles(...)` say.
  A Flutter release build always includes Android's default ProGuard file, so this plugin was never
  exposed; the engine output is unchanged (same handset proof as 0.5.12: lip contour bound,
  generated mouth share 0.000000 / 0.000000).

**Measured 2026-09-23 on an iMac M4**, a clean clone of `bithuman-examples` (`afa0bb4`) with only its
plugin `ref:` pointed at this change, cold Gradle and pub caches, `flutter build apk --release
--target-platform android-arm64` → rc 0. Gradle resolved `expression2-android-0.4.8.aar`,
`essence2-android-0.5.13.aar`, `qnn-litert-delegate-2.49.0.aar` and `qnn-runtime-2.49.0.aar` from
Maven Central. R8's `mapping.txt`: `ai.bithuman.elevate.NativeBridge -> ai.bithuman.elevate.NativeBridge`,
`ai.bithuman.expression2.Native -> ai.bithuman.expression2.Native`. In the APK, `lible_jni.so`
`b97e7ff033ec442c…` and `libexpr2jni.so` `e8dab183ff6ed37e…` equal the ones inside Central's AARs, and
`libQnnTFLiteDelegate.so` is present.

## 2.6.8 — 2026-09-20 — Essence 2 on Android draws the mouth with the identity's own lip contour

Tag `flutter-plugin-v2.6.8`. **An app that pins this tag gets the mouth drawn by the
identity's own lip contour**; `flutter-plugin-v2.6.7` and earlier resolve an engine that
draws it as a wider ellipse.

`ai.bithuman:essence2-android` **0.5.10 → 0.5.12** (public on Maven Central since
2026-09-19, `lastUpdated` 20260919172817). Until 0.5.12 every Android AAR drew that region
as a wider ellipse — not for want of the contour (the engine has carried the bind since
0.5.11) but because the Android publishing step rewrote each identity's model onto a mouth
tile whose shape the load-time bind does not recognise, so on Android alone the bind
declined. 0.5.12 publishes the plain student form for the Android row and the bind takes.

Measured through the **published** bytes, on an SM-S936U1 rendering `A23KSG5258`: the
engine reports the lip contour bound at load (20 verts, feather 6.0 px) and that the wider
region is not reachable in that session; its refusal line — which **is** compiled into the
shipped library, so the path can decline — never fires; and the mouth is still taken
entirely from the identity's own recorded texture, **0.000000 mean / 0.000000 max**
generated share over 62 rendered frames.

Measured on the pin itself, 2026-09-20, from this repository: Gradle resolves
`ai.bithuman:essence2-android:0.5.12` from repo1.maven.org, a release APK built against it
carries `lible_jni.so` **byte-identical** (sha256 `083ee4e5950ba3da…`) to the one inside
Central's AAR, and that library answers `strings … lip_delivery` **4** where 0.5.10's
answers **0**.

**No plugin source change.** AAR sha256
`8512fc644bcbed156d5656409082faf0e02eabbbf699e4e757d35213995823ac` (12,090,958 B) ==
Central's own `.sha256` sidecar. An app reaches this only through a published tag, which
is what `flutter-plugin-v2.6.8` is for: the example app moves its `ref:` from
`flutter-plugin-v2.6.6` to this tag, and until an app moves its own ref it keeps
resolving whatever engine its pinned tag named.

## 2.6.7 — 2026-09-19

Tag `flutter-plugin-v2.6.7`. **Both Apple paths move to `essence2-v1.9.0` — the first published
engine whose mouth is 100% taken from the source video, and whose native CoreML model reads the
lip contour.**

Measured on the `essence2-v1.8.0` bytes this plugin pinned until now, with the engine's own
per-pixel census on A23KSG5258 (bithuman-models #944): generated share **0.0978 mean / 0.9991
max** over 717 rendered frames — ~9.8% of the mouth band generated on average, some pixels fully
generated — and no mouth-mask line at all (the silent ELLIPSE). The source-only head and the
native lip contour both post-date the v1.8.0 tag. `essence2-v1.9.0` reads **0.0 / 0.0** and names
its mask on every session.

And the reader (#948): the bundle's native CoreML model now takes a 5th input `lip_delivery` from
`lip_template.v1.json`, so the model's OWN blend mask — the one that draws the elliptical region on
the chin — is shrunk by the same contour the teeth path already uses. A bundle whose CoreML model is
still the 4-input package beside a template (every served bundle today) is REFUSED by name and
rendered through onnxruntime instead: same picture, the reason on the log, until bundles are
re-published with the 5-input package.

NO PLUGIN SOURCE CHANGE. `LIBESSENCE2_*` and `BITHUMAN_MODELS_REF` in `scripts/bootstrap.sh` move
with `Package.swift`'s `essence2Tag` + checksum in one commit (`check-apple-engine-pin.sh` A1..A5).

## 2.6.6 — 2026-09-17

Tag `flutter-plugin-v2.6.6`. **expression-2 on Apple rendered ZERO frames — and did it
while the app talked out loud.** Two independent defects, either one sufficient on its own
(#77). Every Apple app that takes its models from this plugin alone was affected: the Mac
and, unfixed until this tag, the iPhone.

| | what shipped | what happened |
|---|---|---|
| `{macos,ios}/bithuman.podspec` | `s.resources = ['Assets/embody']` | CocoaPods resolves a file pattern **relative to the podspec** — `<plugin>/<plat>/Assets/embody`. `scripts/bootstrap.sh` staged the embody CoreML members one level up. The glob matched **nothing**, and an empty CocoaPods file pattern is not an error, so the build was green and the app carried no expression-2 graphs at all. |
| `Expression2Container.unpack` | shipped in this pod, **called by nothing** | A downloaded agent arrives as a packed container, while `Expression2Engine.modelURL`/`resURL` only join a NAME onto `activeAgentDir` — so every per-identity member resolved to a path *inside a file*. essence-2 already expanded its own container; expression-2 on Apple did not. |

**Measured on the owner's iPhone 15, on the customer path, before and after.** Same phone,
same `A02HCY0444.imx` in the app's own Documents, same cold launch:

| | before (`flutter-plugin-v2.6.5`) | **after (this tag)** |
|---|---|---|
| `setExpression2AgentDir` | `→ …/Documents/A02HCY0444.imx` (a FILE, stored verbatim) | `[embody] container expanded A02HCY0444.imx → …/Library/Caches/expression2-unpacked/A02HCY0444` |
| shared graphs | `[embody] MISSING w2v_frontend_cpuAndNE.mlpackage in bundle` | all four compiled from the bundle; `dec_p2 per-identity decoder ACTIVE` |
| warmUp | `warmUp FAILED — missing model(s)` / `produced no idle frame` | `warmUp done — ready (idle=yes)`, `idle painted — engine live` |
| idle clip | `idle clip unavailable: no idle.mp4 for this identity` | `idle clip open (200 frames, streamed in place, wraps at the authored end)` |
| `.mlpackage` in the shipped `.app` | **0** | **4** |

★**A `find` for `*.mlpackage` returning non-zero is necessary and nowhere near
sufficient** — the app launched, connected, listened and answered out loud in the broken
state too. Only the picture was missing, which is why this survived: `bithuman-jarvis-app`
carries its own Runner *"Bundle embody models"* phase, so the dead glob never showed
there, and `bithuman-examples`' `app/avatar_chat` — the app on the phones and the Mac —
has no such phase.

A DIRECTORY agent path still passes through untouched; only a FILE is expanded, and an
expansion that fails returns the path **unchanged** and logs why, so the engine keeps
refusing loudly by name rather than quietly rendering a neighbouring identity.

---


**The Dart voice module stopped importing the render module.** `bithuman_realtime.dart`
and `realtime_transport.dart` opened with `import 'bithuman.dart'` and four constructors
took `required BithumanAvatar avatar` — the concrete render class. They now take
`VoiceHost` (`lib/src/voice_host.dart`, fourteen members: mic, speaker, barge-in, the
WebRTC lipsync attach, the on-device brain), and **`BithumanAvatar implements VoiceHost`**
with no new code. The arrow points render → voice.

**Source-compatible for every consumer.** `avatar: avatar` still compiles wherever `avatar`
is a `BithumanAvatar`; measured against `bithuman-examples/app/avatar_chat` and
`bithuman-jarvis-app`, whose analyzer output is byte-identical before and after.

What it buys: a voice session with no avatar is now a thing the type system can say.
`test/e2e/headless_voice_host_test.dart` runs a real `BithumanRealtimeSession` against
fourteen methods of plain Dart — no engine, no texture, no method channel — on a Linux
runner. "To test voice chat we do not even need visuals", executed.

Also: transport routing is a registry rather than an `if`
(`lib/src/transport_protocol.dart` — descriptor, capability record, resolver, and a
written recipe), and the routing rule takes the platform as an argument, so the two
Apple-only rows that CI has never graded are graded now. Held by
`scripts/check_voice_render_edge_dart.sh` (8 rules, one mutation each, exact partition)
beside its Swift twin.

## 2.6.5 — 2026-09-16

Tag `flutter-plugin-v2.6.5`. **The Android half of the barge-in fix.** The pin moves
`ai.bithuman:essence2-android` **0.5.9 → 0.5.10**, public on Maven Central since
`maven-metadata.xml` `lastUpdated 20260916205927`.

★ **WHICH VERSION FIXED WHICH PLATFORM — read this before assuming 2.6.4 closed it.** The
defect the owner reported is one defect with three copies, and they shipped on different
clocks:

| | Apple (`essence2Tag`) | **Android (`essence2-android`)** |
|---|---|---|
| 2.6.3 | broken (v1.7.0) | broken (0.5.9) |
| 2.6.4 | **fixed** (v1.8.0) | still broken (0.5.9) |
| **2.6.5** | fixed (v1.8.0) | **fixed (0.5.10)** |

So **2.6.4 shipped the fix on Apple while still pinning the Android AAR that carries the
bug** — interrupt the agent on Android under 2.6.4 and the video behind the avatar still
snaps back to the start of its clip. Nothing is wrong with 2.6.4's Apple work; it simply
was not the whole defect, and a reader upgrading for "an interruption stops rewinding the
driver video" needs to know that sentence was true of one platform at that version.

**What the Android half is.** Every cut, and every new utterance, seeded the next walk at
driver frame 0 and the composited face followed it there. It rides on the frame it was on
now (bithuman-models #774). It is ONE default value —
`Essence2Avatar.resetAudio(startFrame: Int = 0 → -1)`, where `-1` means continue the walk.

★ **Proved from the published bytes, and it could not have been proved any other way.** A
Kotlin default lives in `resetAudio$default`, not in a signature, so
`api/essence2-android.api` is **byte-identical** between 0.5.9 and 0.5.10 and no
API-surface check could ever have caught this. Read off the `classes.jar` Central serves,
with the published 0.5.9 as its own control:

| read off `Essence2Avatar.resetAudio$default` | published 0.5.9 | **published 0.5.10** |
|---|---|---|
| `startFrame` default opcode | `iconst_0` — rewind to frame 0 | **`iconst_m1`** — continue the walk |

AAR sha256 `4074a827835a534dfc8176554fd18380ae3265037cb71402c6661a6cc5553e3c` — **==
Central's own `.sha256` sidecar** (sha1 `3acad881da94…` == its `.sha1`) — `lible_jni.so`
`59ddea6a3a64cbb42471e93f12385e38302caee726ccbf421a4bd94b8c7cea19`; `.aar`/`.pom`/
`.module`/`-relink.zip` all VALIDSIG by `0C6FA32B…D477FFA1` from a **keyserver-only**
keyring, a one-byte tamper reads BADSIG, and a version that does not exist 404s — so a 200
means something.

**No plugin source change.** `javap -p` over every class in 0.5.10's `classes.jar` is
identical member for member to 0.5.9's, so the same `AvatarEngine` adapter opens it and
everything 0.5.9 carried is still here (the warp prior in place, the motion thread, the
driver cursor).

★ **2.6.4 also carried a change its own entry does not name**, recorded here so the
history is complete rather than re-derived later: homebrew-bithuman #68, the LOCAL-mode
interrupt gate. It replaces a sustained-energy floor with **HOLD → CONFIRM → RELEASE**, and
**it is OFF on the cloud path**, where `server_vad` already barges faster and better
informed — so a consumer on the default transport, Android included, gets nothing new from
it. Why it is not simply a better constant, which is the part worth keeping: on LOCAL paths
there is no server VAD, so an energy gate is the only thing that can interrupt the agent —
and no floor can do that job here, because the two distributions overlap. Within 2 s of
onset **6 of 16 real barge-ins never reached the 4000 floor, while the agent's own echo
residual reached 4049-6530**; every floor from 500 to 7000 was swept and none puts both
failure modes at zero. So the shape changed instead: HOLD pauses the speaker losslessly
the instant something might be speech (the reply keeps buffering, nothing is decided),
CONFIRM re-reads the microphone with the far end now physically silent and the echo gone
with it, RELEASE resumes from the sample it stopped on if nobody was there — a false alarm
costs a ~0.3 s hiccup instead of the agent's turn. A self-interruption would need
speech-level microphone energy while nothing is playing, which echo cannot produce: a
property of the shape, not a lucky number. **If you are ever tempted to simplify it back
to a threshold, that sweep is why it cannot be one.**

★ **The pin moved only after Central served 0.5.10**, never after a local publish.
Measured 2026-09-16: `mavenLocal()` cannot SHADOW a version Central serves — a `~/.m2`
poisoned with a different artifact at the same coordinate still resolved Central's bytes —
but it CAN supply a version Central LACKS, which is how plugin 2.4.0 came to import a class
Central's 0.4.6 did not have. Resolution proved from a clean cache with an empty
`GRADLE_USER_HOME`, `FAIL_ON_PROJECT_REPOS`, no `mavenLocal()` and `maven.repo.local` at an
empty directory; both negative controls fire — published `0.4.6` dies on `Unresolved
reference 'Expression2IdleLoop'`, and a pin one version ahead dies on `Could not find
ai.bithuman:essence2-android:0.5.11`.

## 2.6.4 — 2026-09-16

Tag `flutter-plugin-v2.6.4`. ★ This entry says "one change" and the tag carries two: it
also includes homebrew-bithuman #68, the LOCAL-mode HOLD → CONFIRM → RELEASE interrupt
gate, which landed between 2.6.3 and this tag and is named in 2.6.5's entry above. The
Apple essence-2 engine pin moves
`essence2-v1.7.0 → essence2-v1.8.0` on **both** Apple paths in one commit (`Package.swift`'s
`essence2Tag` + `libessence2` binaryTarget checksum, and this package's own
`LIBESSENCE2_*` block), with `BITHUMAN_MODELS_REF` moved to `6bed5ee7a` — the tree that
engine was built from.

**An interruption stops rewinding the driver video** (bithuman-models #774). The owner
reported it twice: *"for essence-2 the interruption shouldn't rewind driver video to start
— it should ride on the current frame and continue playing video continuously for
continuity. Right now sometimes especially during talking interruption I can see obvious
discontinuities there."*

`LeCoreSession.idleAdvance` copied `idleBGR` — the driver video's frame 0, read once at
init — whenever the engine's ring was empty, and `le_utt_interrupt` **purges that ring by
design**, so a barge-in landed there every single time. Measured on the engine's own bytes
at a 50 ms display tick across three real cuts: the delivered si read `55 56 57 [0] 58 59
60` — the driver's first frame spliced into the middle of the walk — **exactly 3 frames
(150 ms) per cut, and up to 19 frames (~1 s) at an utterance onset**, which is the same
defect the moment the user starts talking. The fix is a deletion: `idleAdvance` returns 0
and the presenter keeps the frame it has, which IS the current frame. The shared core
learns the same answer — `le_a2x_reset` with `si0 < 0` continues the walk it is on.

No plugin source changes were needed: `composeTickEssence2` and `publishIdleLoopFrame`
already read `rt.idle(into:) > 0` and hold the texture otherwise, and the one caller that
takes the adapter's `rt.idle` property (with its flat-grey `fallbackIdle`) is
`setupAtomicSlotClock`, which runs before any frame has been delivered — exactly the case
where the engine still answers with frame 0, because that is genuinely where the walk is.

★ **Proved from the published bytes, not from a changelog and not from a version string.**
The `libessence2.xcframework.zip` of `essence2-v1.8.0` was re-downloaded **anonymously**
from the tap (`curl`, no credential), re-hashed to `06be42fe…` against both its own sidecar
and the checksum pinned here, unzipped, and read with `nm` + `llvm-objdump` on all three
slices — then the same commands on `essence2-v1.7.0`, the engine shipping in 2.6.3, as the
control:

| read off the slice | essence2-v1.7.0 | **essence2-v1.8.0** |
|---|---|---|
| `everDelivered` ivar-offset symbol — the Apple half | 0 | **2** |
| `idleBGR` symbol — the reader's own control | 2 | 2 |
| `le_a2x_reset` sign test on `si0` (`tbz w1, #0x1f`) | 0 | **1** |
| `idleAdvance` instruction count | 79 | **85** |

macos-arm64, ios-arm64 and ios-arm64-simulator read identically. In 1.8.0 `idleAdvance`
reads `ldrb w24, [x20, #0x78]` (the `everDelivered` flag) under the lock and
`tbnz w24, #0x0, <mov x0, #0>` — hold — before it can reach the `idleBGR` copy at
`[x20, #0x70]`; in 1.7.0 that copy is unconditional.

**Android is NOT covered by this tag.** `ai.bithuman:essence2-android:0.5.9`, pinned in
`android/build.gradle`, was staged from a commit four before #774, so the Android half of
the same defect (`Essence2Avatar.resetAudio(startFrame: Int = 0)`) is still live there. That
coordinate is a Maven Central publish and stays the owner's click.

## 2.6.3 — 2026-09-16

Tag `flutter-plugin-v2.6.3`. One change: the Android essence-2 pin moves
`ai.bithuman:essence2-android` **0.5.8 → 0.5.9**, the coordinate the owner published to
Maven Central on 2026-09-16 (served from `repo1.maven.org` since `maven-metadata.xml`
`lastUpdated 20260916194252`; AAR sha256 `bafe6e2926…` == Central's own `.sha256`
sidecar, `lible_jni.so` `fec2c0ecc…`, `.aar`/`.pom`/`.module`/`-relink.zip` all VALIDSIG
by `0C6FA32B…D477FFA1` from a keyserver-only keyring, one-byte tamper reads BADSIG).

**The warp prior plays in place** (bithuman-models #747). `Identity::P(si)` was an
offset into a 394,788,864 B `P.f16` that the SDK expanded from a 2,966,479 B
`P_hevc.mov` at activate and mmap'd — fully resident after one lap, for a member read
one frame at a time on the driver's own walk. It is a cursor now, through the same
`DriverCursor` the driver uses. On a Galaxy S25+ through THIS plugin's adapter: engine
create **891.1 → 164.1 ms**, VmRSS after one lap **1,018,944 → 683,268 kB**, the
mapping's **385,536 kB → 0**, **394,788,864 B → 0 B** written to app storage, per-push
**17.733 → 16.454 ms**, and **304/304 delivered frames identical si for si** through
ART.

No plugin source changes — `javap` over every class in 0.5.9's `classes.jar` is
identical member for member to 0.5.8's, so the same `AvatarEngine` adapter opens it.

★ **Proved against the published coordinate, from a clean cache.** The plugin's
SDK-facing Kotlin (`AvatarEngine`, `AvatarPlayer`, `AvatarStats`, `MicCapture`) compiles
against `expression2-android:0.4.7` + `essence2-android:0.5.9` with an empty
`GRADLE_USER_HOME`, `FAIL_ON_PROJECT_REPOS`, no `mavenLocal()` and `maven.repo.local`
pointed at an empty directory; the bytes Gradle resolved are Central's
(`eb72f9209…`, `bafe6e292…`). Two negative controls fire: against Central's published
**0.4.6** the same compile dies on `Unresolved reference 'Expression2IdleLoop'`, and a
pin one version AHEAD of Central dies on `Could not find
ai.bithuman:essence2-android:0.5.10` — which is the failure a local publish would hide.

## 2.6.2 — 2026-09-16

**A measurement build says so on screen, and the echo canceller is attested rather
than assumed.** Twice on 2026-09-16 the owner watched our own instrumentation and
filed it as a product defect — an iPhone FLOORS probe that paints black by
construction ("black screen"), and a macOS arm running the stress driver, which
by design requests the next monologue after every response ("it keeps self
talking on and on"). Both builds were doing exactly what they were told and
neither said so, and no instrument could settle it after the fact: a `strings`
scan of the Mach-O cannot see a Flutter dart-define. `MeasurementBanner` in
`lib/ui_kit.dart` now names every lever that makes the app BEHAVE unlike the
product — self-driving, injected microphone, unprompted greeting, a non-default
transport, a mock server — in a band that never fades and never hides. It costs a
release build nothing: each lever is `DevLevers.enabled && …` with
`enabled = !kReleaseMode`, so the widget folds away at compile time. Alongside it,
both platforms write a `[bhaec]` line AFTER the audio graph is running, read back
off the OS (Apple: `AVAudioEngine.isVoiceProcessingEnabled` on both IO ends;
Android: `AcousticEchoCanceler.enabled` with the audio mode), re-attested on the
device hot-swap path — so a session that ran without the platform canceller can
no longer look identical to one that ran with it.

**A tag names an engine.** The Apple engine edge had no pin. `locate_engine_sdk`
took a ref and both call sites omitted it, so the engine adapter Swift compiled
into the pod came from bithuman-models **main HEAD at bootstrap time**, into
gitignored directories, with no revision recorded anywhere in the built
artifact — two developers building `flutter-plugin-v2.6.1` a week apart got
different engine code and neither could tell. The binary half was worse: the
pod ran the engine SDK's bootstrap with no engine coordinate, so the tag came
from a default in the engine repo — `essence2-v1.2.0`, a pre-release whose own
title reads "superseded by essence2-v1.5.0", last rolled 2026-09-06 — while
`Package.swift` served `essence2-v1.7.0` on the SwiftPM path. Five releases
apart, one repo, no gate between them. Measured on the published slices:
v1.2.0 carries 0 `DriverCursor` and 0 `decoded IN PLACE`, v1.7.0 carries 257 and
1. Nothing that ran on a device linked v1.2.0 — every Apple build overrode the
default by hand — but the plugin's own committed globs were written for it, so
`s.resources` looked for `a2x_w2v.*.onnx` (a v1.2.0-era name), the app carried
no audio encoder, and `be_essence2_create` returned -2 on the first macOS run of
2026-09-16.

The coordinates now live in `scripts/bootstrap.sh`, committed and immutable,
exactly as `android/build.gradle` names `ai.bithuman:essence2-android:0.5.8`:
`BITHUMAN_MODELS_REF` (a 40-hex commit sha for the adapter source, passed at both
call sites and checked out by the clone path) plus the engine release, its
digest, and the resources pair, passed explicitly to the engine SDK's bootstrap
so the engine repo's default never decides. Every build log now names the
revision it resolved, including the developer override and sibling-checkout
paths that cannot be pinned. `scripts/check-apple-engine-pin.sh` refuses a
commit where the pod and `Package.swift` name different engines or different
bytes, where the source pin is a branch rather than a sha, or where a call site
drops the ref; its CI job re-creates all six defects and requires a refusal for
each.

**Dev levers cannot steer a release build; one echo table.** Every environment variable
the Apple plugin read (15 of them — `EMBODY_MARKER_EVERY`, the A/V sync marker that
flashes a frame white with a click; `BITHUMAN_NO_VPIO`, which removes the echo canceller;
`EMBODY_TEST_AUDIO` / `EMBODY_TEST_WAV`, which drive the engine with no conversation; the
debug-log switches; the probe-file directory) now goes through one door,
`shared/Classes/DevLevers.swift`, whose single read is `#if DEBUG` — a Release build
returns nil for every name whatever the environment holds. Two probe files
(`embody_app_idle.bgr`, `embody_av.txt`) that every build wrote to `/tmp` are written only
when a debug build names a directory. Every `--dart-define` the plugin honoured
(`BITHUMAN_DEV_STRESS`, `BITHUMAN_DEV_GREETING`, `BH_MIC_FILE`, `BITHUMAN_REALTIME_WS_URL`,
`BITHUMAN_TRANSPORT`) is declared once in `lib/src/dev_levers.dart` as
`!kReleaseMode && …`, a compile-time constant that folds away in `flutter build --release`.
Android was already gated on `FLAG_DEBUGGABLE` (2.4.0). `scripts/check_dev_levers.sh`
refuses a read outside a door; `scripts/prove_dev_levers_release.sh` compiles the Swift door
as Release and Debug and runs both with every lever set.

The `server_vad` threshold and the uplink gain policy are one table,
`lib/src/echo_profile.dart`, keyed by device class (iPhone 0.5 / Android 0.5 / Mac 0.7 with
VP-IO AGC off), each row carrying the post-canceller residual it was measured against, the
date, and the falsifier (0 self-interruptions over ≥ 3 × 60 s of the agent talking with
nobody in the room) — as `const` asserts, so a row without those numbers does not compile.
Both transports read it; the Swift side takes `vpioAgc` from `audioStart` instead of a
`#if os(macOS)` literal, and re-applies it on the audio-device hot-swap path (before, a Mac
device change came back with AGC on). Shipped behaviour on every device is unchanged: the
values are the ones 2.6.0 carried, now with their evidence beside them.

## 2.6.1 — 2026-09-16

Tag `flutter-plugin-v2.6.1`. One change: the Android essence-2 pin moves
`ai.bithuman:essence2-android` **0.5.7 → 0.5.8**, the coordinate the owner published
to Maven Central on 2026-09-16. 0.5.8 delivers every frame (0.5.7 delivered 72–77 % of
a reply's frames under the plugin's un-paced transport — bithuman-models #737): the
SDK's own motion thread extends the motion frontier, never behind a `feed()`, and the
driver cursor cannot hand out the slot the decoder is writing (#738). No plugin source
changes; the same `AvatarEngine` adapter opens 0.5.8. Both Android pins
(`expression2-android:0.4.7`, `essence2-android:0.5.8`) now resolve from
`mavenCentral()` alone — this is the first tag a stranger's clone builds on Android
without mavenLocal.

## 2.6.0 — 2026-09-16

Tag `flutter-plugin-v2.6.0`. Android runs essence-2 (#49) and macOS presents, hears and
opens essence-2 correctly (#51). ★ One consumer-visible constraint: **minSdk is 29** on
Android (2.5.0 built at 26) — a host app declaring `minSdk = 26` fails the manifest merge
until it says 29; `essence2-android` declares 29 and the Android half links it now.

★ **What this tag pins on Android, and what it does not yet carry.** `android/build.gradle`
pins `ai.bithuman:expression2-android:0.4.7` and `ai.bithuman:essence2-android:0.5.7`.
0.5.7 is public and is the AAR whose motion frontier advanced only behind `feed()` — under
this plugin's own un-paced transport (no pacer since 2.5.0) it delivered **72-77 % of every
reply's frames** on a Galaxy S25+ (1380 of 1813 units; the rest of the audio played under
a frozen last frame — bithuman-models #737). The fix is the SDK's motion thread in
`essence2-android` **0.5.8**, staged in the Portal for the owner's click; when it is public
the pin moves in the next plugin release. Until then, essence-2 on Android through this
tag is the 0.5.7 shape. (0.4.7 is likewise staged, not public; the expression-2 half of
this tag resolves from Central only after that click — unchanged from 2.5.0.)

* **Android runs essence-2.** `load(engine: 'essence2')` on Android opens the published
  `ai.bithuman:essence2-android` AAR (0.5.7+, the identity fetched by code through the
  metered door with the app's credential, which also arms the engine's meter). The
  player is now written against `AvatarEngine` — the same admission / write-ahead /
  presentation / idle rules run on either SDK; what differs per engine (frame rate,
  where a frame's audio position comes from, what a reset and a tail are) is stated in
  one file, `AvatarEngine.kt`. Before this the Android half refused every engine but
  expression-2 by name. minSdk is 29 (essence2-android declares 29).

* **macOS presents at 20 fps again, hears itself less, and can open essence-2.** Four
  measured defects on an iMac (M4, macOS 26.6.2), the first macOS run of the conversation
  contract (`conversation_duplex`, bithuman-models #729), each with its fix:
  * *The picture ran at 8.5 fps with 60 frames waiting.* The 50 ms display tick is a
    `DispatchSourceTimer`, and macOS coalesces an unflagged timer for a process it does
    not consider interactive: gaps of 135-190 ms between presented frames, 2143 of them
    in 400 s, median 8.5 fps during speech, 24 mid-reply holds. `.strict` on both drive
    timers (expression-2's 50 ms display clock, essence-2's 40 ms slot clock): 20.0 fps,
    0 holds, 45 gaps in 420 s, all of them between replies. iOS never coalesced them and
    is unchanged by the flag.
  * *The agent interrupted itself on its own echo.* The iMac's canceller leaves the far
    end at -46..-56 dBFS RMS (peaks -34) where the iPhone's leaves -70..-90; at the
    proven 0.5 the server's VAD read that as the user 3 times in 357 s and 3 in 370 s of
    monologue. Two changes: VP-IO's automatic gain on the uplink is off on macOS (it
    amplifies the residual between the user's words; residual max -46 -> -54 dBFS,
    onset median -60 -> -73), and the server_vad threshold on macOS is 0.7 (the dial the
    transport already names for exactly this). 0 self-interruptions in 354 s / 35 turns,
    10/10 injected cut-ins detected, attenuation still 0 dB (captured == sent).
  * *A release build linked no CConverse on macOS.* `flutter build macos --release`
    targets arm64 + x86_64, the vendored xcframework has only `macos-arm64`, and
    CocoaPods emitted nothing for it. `EXCLUDED_ARCHS[sdk=macosx*] = x86_64` on the pod
    and the app target.
  * *essence-2 could not open on Apple.* The podspec's resource glob `a2x_w2v.*.onnx`
    matched none of the release's loose ONNX files (`w2v_ess_fp16_v1.onnx`,
    `audio_encoder_fp16_window_{trunk,head}.onnx`), so `be_essence2_create` returned -2
    ("no shared audio frontend"); every `*.onnx` under the engine's resources is shipped
    now. And the `apiSecret` `load` was handed was dropped on the floor on Apple
    ("accepted for API compatibility but unused"): essence-2 bills the session it serves
    and refused (-3) on an iPhone whose Keychain held the key. It now rides the
    `AvatarRef` to `be_essence2_set_api_secret` before the engine is created.
  Measured on the fixed build, expression-2 on macOS: TTFA 674 ms (n=45), delivery
  ratio 10.9, holds 0, 0 self-interruptions / 354 s, 10/10 cuts with 0 leaks, cut ->
  idle 35 ms, idle 199 -> 0 x14.

## 2.5.0 — 2026-09-16

Tag `flutter-plugin-v2.5.0`. Four user-visible changes on iOS and macOS (#47) — the
conversation the owner accepted on Android in 2.4.0, made true on the Apple halves —
and the Android engine pin moves to the AAR that carries the class this plugin imports.

* **Duplex on Apple: the microphone is never gated while the agent talks.**
  `RealtimeAudioIO` soft-limited the uplink to room level whenever the agent was audible
  (iOS: a 3 s mic-start grace, an AEC warm-up squelch of 5–30 s per session, a 0.3 s
  sustained-speech gate; macOS: the 0.3 s gate) — by its own comment, "no barge-in
  during the first ~10 s of agent speech". Deleted. Voice-processing I/O on both nodes
  carries the echo; measured on an iPhone 15: a −18 dBFS far end cancels to −70…−90 dBFS
  steady, only the onset transient reaches ~−35 dBFS. The attenuation the contract
  forbids is 0 by construction — nothing between capture and the EventChannel touches
  the samples — and `bhmic` logs captured and sent levels side by side.
* **No pacer.** The Dart transport metered reply deltas to ~1× (+180 ms) on every
  platform but Android. Deleted everywhere: the reply reaches the plugin as fast as the
  server sends it and the ENGINE bounds the backlog (expression-2 parks its producer at
  `maxQueuedFrames = 64`; essence-2's ring is 8 deep). On iOS this is time-to-first-audio
  and parity, not a pause fix — the pause was Android's.
* **No drop-oldest cap; a cut leaves no old frame.** `AvatarTexture.audioQueue` was capped
  (96k samples expression-2, 32k essence-2) and dropped its OLDEST on overflow — a
  silent lipsync loss the pacer hid. Deleted. `barge()` resets the texture first (epoch
  + engine) and drops the speaker FIFO second; the display tick reads the epoch at the
  top and fences any frame pulled across the cut. `bhbarge` counts LEAK / FENCED /
  OLD-SLICE so 0 is proven, not assumed.
* **The conversation instrument.** A release iOS build's Dart `print` never reaches the
  console `devicectl` attaches, so every Apple arm reported only its native half.
  `BithumanAvatar.nativeLog` carries the transport's lines (`bhmic`, `bhfar`, `bhfeed`,
  `bhrun`, `bhfifo`, `bhbarge`, `bhdeliver`) into the same stream as the presenter's,
  the same names on Apple and Android, read by the cross-platform conformance suite.
* **Android engine pin → `ai.bithuman:expression2-android:0.4.7`.** 2.4.0 pinned 0.4.6
  while importing `Expression2IdleLoop`, a class Central's 0.4.6 does not have (that
  artifact was built before the in-place idle loop landed; it holds 48 frames as a
  `List<Bitmap>`). 2.4.0 compiled only against a mavenLocal 0.4.6 built from a later
  main; against Central it does not build. 0.4.7 is the first Central artifact with the
  class. Until 0.4.7 is public, this half resolves from mavenLocal only — stated here
  and in `android/build.gradle`.

## 2.4.0 — 2026-09-16

The first tagged plugin release (`flutter-plugin-v2.4.0`). Everything below shipped to
main between the 2.3.3 engine bump and this tag; a developer consuming the plugin by git
URL with no ref has been getting it as it landed. Accepted by the owner on his own phone,
in his words: *"Now android works! The interaction turns out nicely."*

Four user-visible behaviour changes since 2.3.3, each landed as its own squash on main:
the avatar FILLS a phone screen under one rule for both models (#41); the voice no longer
pauses for a late frame and the transport no longer paces the sink — about 900 ms off
time-to-first-audio (#42); the idle clip plays whole, first frame to last, and wraps at
the authored end (#43); the microphone stays open while the agent talks, so a cut-in
interrupts — duplex, VAD unified with iOS (#44).

* **The idle clip plays from its first frame to its last and wraps there, on every
  platform, and nothing holds it.** The owner: *"I only see the 1 s or so of the idle
  video and then it loops back"* — and then: *"it shouldn't cut at all as it should just
  play from beginning to end and then loop to beginning because the idle video is
  designed in such the first frame is visually identical to the last frame."* He was
  right on both counts. `idle.mp4` is 10 s / 200 frames with its seam at the END, and
  three players capped it — the Apple SDK at 48 frames, the Android SDK at 48 "as Apple
  caps its own", the plugin's `IdleClip.kt` at 40 "the Apple SDK caps its own at 48" —
  each justifying its constant by the next one's. The caps existed because a held frame
  is 0.9-1.2 MB (180-240 MB for the clip; essence-2's 1248x704 clip would be 527 MB), and
  the fix is not a bigger list: both SDKs now decode the clip IN PLACE from one hardware
  decoder (`AVAssetReader` / `MediaCodec`) and wrap where the file ends. Apple: the
  engine's `idleNextPixelBuffer()` hands the decoder's own IOSurface buffer to the Flutter
  texture untouched (`publishPixelBufferToTexture`), so an idle tick costs no pixel copy;
  the protocol's `idleLoop: [[UInt8]]` — the list that invited the cap — is gone, and
  `idle(into:)` is the one idle-motion surface. Android: `Expression2IdleLoop.next(bitmap)`
  fills a slot of the same bitmap ring speech uses, so the player holds no idle frames at
  all; `IdleClip.kt` (the stopgap download, "delete this when the SDK exposes the loop")
  is deleted. The SDK logs every wrap with its index; the player's `bhav PROD` line
  carries `idleAt=i/N idleWraps=k idleStall=0`.
* **Android half of the plugin.** `android/` implements the SAME `ai.bithuman.avatar`
  MethodChannel and `ai.bithuman.avatar.mic/<textureId>/<gen>` EventChannel the Apple
  halves serve, so ONE Flutter app runs on a Galaxy with byte-for-byte the widgets it
  runs on an iPhone. Engine: expression-2 through the published
  `ai.bithuman:expression2-android` AAR (pinned 0.4.6 — Maven Central carries 0.4.1 at
  the time of writing, so until 0.4.6 is published there this half resolves from
  mavenLocal only; that is the press gate, stated here on purpose). On Android
  `load(path)` takes the agent CODE and `apiSecret`: the identity is fetched through
  the metered door into the SDK's own store. Presentation is `AvatarPlayer.kt` — the
  audited one-unit A/V player from the Android chat example (a frame and its 50 ms of
  sound are one object, presented against the device's own sample counter; idle is the
  same machinery, from the SDK's `idleLoop` — its cursor over the identity's clip,
  decoded in place, every frame of it) — adopted as a file behind a SurfaceTexture
  sink, not re-implemented.
  `MicCapture.kt` carries the echo-cancelled, HALF-DUPLEX microphone (silence is sent
  while the agent is audible, never a hole). The Dart transport's Android→WebRTC detour
  and its canned-mouth `setSpeaking` branch are deleted: every platform takes the
  WebSocket transport, whose bot PCM the avatar lipsyncs from. The consuming app must
  set `packaging { jniLibs { useLegacyPackaging = true } }` or the Hexagon delegate
  cannot open its libraries and the SDK falls back to the CPU silently.
* **ONE UI kit for every surface — `package:bithuman/ui_kit.dart`.** The avatar is
  the interface; the chrome is translucent glass over it and hides itself. Components:
  `Motion` (one easing, four durations), `Frosted`, `GlassIconButton`, `RoundButton`,
  `LoadingRing`/`LoadingState`, `SessionState`/`StatusPill`, `PromptCapsule`,
  `AutoHidingChrome`, `BubbleView`, and `WindowChrome` (Dart side of the macOS window).
  `glass_tokens.dart` moved down from bithuman-jarvis-app; `avatar_fit.dart` now carries
  the ruled fit policy (`AvatarSurface.phone|desktop`: phones crop a landscape canvas's
  sides with the character centred and show a portrait canvas at full width; desktop
  never crops). Surfaces import the kit and draw nothing of their own.
* **macOS window chrome in the plugin (`macos/Classes/WindowChrome.swift`).** Borderless
  glass window (edge-to-edge canvas, `Glass.rWindow` corners, traffic lights on hover,
  drag-anywhere) and the floating-circle companion (`enterBubble`/`exitBubble`: an
  always-on-top `Glass.bubbleSize` circle at the lower-right, frame + aspect lock + level
  saved and restored), registered on the `ai.bithuman.window` channel by the plugin.
  Moved down from jarvis's Runner so the demo and jarvis share one implementation; a
  Runner that still creates its own `WindowChrome` on the same channel keeps winning
  until it deletes it.

* **Essence 2 (on-device Elevate) `.elevatedir` download flow.** Added
  `fetchEssence2Catalog` + `downloadEssence2Bundle` (+ `Essence2CatalogEntry`)
  — the Elevate twin of the Essence `.imx` model_url flow. The client fetches
  the `elevate-catalog-v1` index (https + optional host allow-list), downloads a
  content-addressed `.tar.gz` bundle, verifies its canonical SHA-256 (via the
  system `shasum`, so no new package dep — the extraction is already macOS-only
  via `tar`), and extracts it into a ready-to-load `.elevatedir` (meta.json
  marker checked; staging-dir + atomic rename; cache-aware). Before this the app
  had NO essence-2 download path, so on-device Essence 2 could only run from a
  bundle baked on a dev machine — a user could not download the Essence-2 demo
  agent to run it offline. Producer:
  `models/essence-2/engine/light/*/ml/pipeline/publish_elevatedir.py`.

* **bootstrap: a stale engine-SDK cache now FAILS LOUD instead of silently
  pinning old engine source.** The shared `~/.cache/bithuman/bithuman-models`
  refresh used plain `git fetch … || true`; on machines whose cache was
  created via gh's auth, the un-credentialed refresh of the private repo
  failed silently and the pod kept compiling a frozen engine adapter (found
  as a pre-`dec_P2` `Expression2Engine` staged from a 07-01 cache while every
  log line read success). The refresh now goes through gh's credential helper
  (`gh auth login` / `GH_TOKEN`) and a refresh failure aborts the bootstrap
  with the exact remedies.

* **Engine registry: the combined `essence-2` creation name routes to the
  essence2 engine.** The platform (2026-07-02 model-release UX) stores
  `agents.model='essence-2'` verbatim and folds it onto the light family —
  whose on-device leg is essence2. Added as a frozen alias in the Swift
  `EngineRegistry` + Dart `kEssence2` (lockstep with bithuman-models
  `models/essence-2/sdk` `Essence2Engine.id`/manifest), so a catalog/manifest
  entry carrying the combined name no longer falls through the unknown-slug
  fallback onto the default expression2 engine. `essence-2-quality` stays
  cloud-only.

* **Account hub + `engine/sdk/app` reorg + dead-code cleanup.** All chrome
  consolidated behind one top-left Clerk avatar → a single in-app **hub**:
  profile · credits (on-device **1 cr/min** vs OpenAI **10 cr/min**, 99 free
  credits/mo, Upgrade) · avatar gallery · runtime · voice · personality ·
  password · sign out · quit. Real Clerk account management via public
  `ClerkAuthState` APIs only — custom UI, no prebuilt widgets, so the OAuth
  deep-link issue stays sidestepped. A typed message now **barges** like a
  spoken turn, and the voice-processing unit no longer **ducks other apps'
  audio** (macOS 14+). The repo was reorganized into
  `engine / sdk / app / training / inference` (the Flutter plugin split into
  `sdk/` + the product app, since spun out to the standalone `bithuman-app`
  repo), and ~1.5k lines of dead UI code from the
  refactor were removed. (Follow-up: retire the orphaned detached-settings
  window subsystem.)

* **embody-apple native macOS app — self-contained, embody-only, multi-agent.**
  The Flutter app is now an **embody-only** Apple-Silicon talking-head app
  (avatar = pure-Swift/CoreML `Expression2Runtime`; brain = OpenAI Realtime *or*
  on-device libconverse). The `essence`/`elevate` engines were removed (−1926
  lines). It is **self-contained under `embody/`**: `scripts/bootstrap.sh` fetches
  the `vendor-v1` GitHub release (`embody-vendor.tar.gz` = libconverse.xcframework
  + A42 CoreML models), sha256-verifies it, and a Runner build phase bundles the
  models into the `.app` (no sibling SDK / no `~/embody-ane` needed).
  * **Downloadable agent gallery (8 identities).** A hosted manifest +
    per-identity `~88 MB` bundles (student + audiotokenizer + canon + idle.mp4);
    `Expression2Runtime.activeAgentDir` loads per-agent weights while the shared
    w2v/taehv graphs ship once in the app. Switching also applies a gender-matched
    voice + persona.
  * **Per-agent idle video.** Each agent idles *as itself* (server-rendered, or a
    Seedance clip from the source image cropped to the 416×720 framing). Fixes the
    "every agent idled as Einstein" bug — `resURL` no longer falls back to the
    bundled A42's `idle.mp4`/`canon` for a downloaded agent.
  * **Sharp render from frame 0 (speech-warm seed).** The first reply of every
    non-A42 agent used to render *warped/soft* for ~15-20 s then sharpen: the
    per-utterance reset seeded the ctx ring with the *silence-rest* state (≈base
    identity), which takes ~20 s of audio to diffuse to the identity's speaking
    look. Fix: at warm-up, feed a short generic-speech clip (`embody/warm.wav`,
    synthesized by `bootstrap.sh` via macOS `say`) through the model so the captured
    reset seed is the **speaking-converged** state — sharp from frame 0, full ANE
    speed. (fp32 is too slow to ship; canon-seed renders the base identity and never
    converges.) Onset sharpness (var-of-Laplacian) ~95 → ~200.
  * **Audio robustness:** Bluetooth/loudspeaker hot-swap (Core Audio HAL
    listeners), device-switch crash fixed (Obj-C `@try/@catch` shim around
    `installTap`), mic-permission gate, VP-IO/AEC so the agent doesn't interrupt
    itself, local-mode barge, and a tail-flush so the last word isn't clipped.

* **embody (on-device CoreML) — clean speech onset, exact A/V sync, instant barge.**
  Brought the Apple/CoreML `embody` engine to parity with the server's clean onset
  (`Expression2Runtime.swift`):
  * **No onset "snowflake".** The first chunk (`ci=0`) of each response was a cold
    wav2vec2 window with no left context → ~1 s of static that "converged" to the
    face. It now prepends a 6-**token** silence left-context margin to that window and
    shifts `base` past it, so it emits the *same* first-second content but computed
    warm — identical A/V, no static. (Token units, not frame units: the
    audiotokenizer downsamples the 55-frame w2v window ~4× to 14 tokens, so the margin
    is `onsetBase · WIN_LAT·SPF / numTokens` ≈ 18857 samples; `numTokens` is captured
    from the model at warm-up.)
  * **Exact A/V sync.** Speaker audio is metered 50 ms per published lip-frame
    (count-based pairing), and each response resets the engine stream so frame N maps
    1:1 to its audio. (A continuous-stream experiment that desynced this — and
    re-animated the previous sentence at each onset — was reverted.)
  * **Instant clean barge.** `resetState()` bumps a generation counter, so an
    in-flight background `processChunk` discards its frames instead of appending
    ~1.6 s of stale animation after an interrupt — the avatar snaps back to the idle
    video immediately, with the audio queue cleared.
  * Also on this branch: **USM unsharp-mask sharpen** (`EMBODY_SHARPEN`, GPU-parity
    crispness), a **detached Flutter settings window**, and a **macOS-26 local-mode
    gate** (`isLocalModeSupported`).

* **Engine bumped to 2.3.3** — Android `ai.bithuman:sdk` 1.16.0 → 2.3.3 (ABI 7;
  API verified source-compatible). iOS/macOS build against the current
  libessence (2.3.3) via the sibling SDK + the fixed Flutter bootstrap. Plugin
  version → 2.3.3. (Per-platform build/run verification pending.)

* **Migrated to OpenAI Realtime GA** — the beta endpoint was retired
  upstream and now refuses connections with close code 4000
  (`invalid_request_error.beta_api_shape_disabled`). Changes:
  * Drop the `OpenAI-Beta: realtime=v1` header.
  * Default `model` flipped from `gpt-4o-realtime-preview-2024-12-17`
    to `gpt-realtime`.
  * `session.update` payload rewritten to the GA shape: top-level
    `type: 'realtime'`, `output_modalities: ['audio']`, audio config
    nested under `audio.input` / `audio.output`, `voice` lives inside
    `audio.output`, `turn_detection` inside `audio.input`, format
    object `{type: 'audio/pcm', rate: 24000}` (was the string `'pcm16'`).
  * Inbound event renames: `response.audio.delta` →
    `response.output_audio.delta`, and `response.audio_transcript.delta`
    → `response.output_audio_transcript.delta`.
* **Reconnect-backoff fix** — the WebSocket reconnect counter now resets
  on the first inbound server event rather than on TCP-dial success.
  Without this, server-side close-after-handshake (auth rejected, schema
  rejected, beta deprecation) looped forever in `connecting` instead of
  surfacing `RealtimeStatus.error`; the max-retries ceiling was
  unreachable because every dial reset the counter to zero.

