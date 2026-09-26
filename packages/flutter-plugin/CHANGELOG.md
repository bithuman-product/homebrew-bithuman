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

**Measured 2026-09-23 on echelon**, a clean clone of `bithuman-examples` (`afa0bb4`) with only its
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
  * **Downloadable agent gallery (8 identities).** A Supabase manifest +
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

