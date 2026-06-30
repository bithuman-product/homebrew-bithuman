# bitHuman app e2e harness — simulator-first, automated, hermetic

The validation backbone for app changes across macOS / iOS / Android (one
codebase, three targets). **Policy: every change is first proven logically
sound, end to end, on simulators — automatically (audio and events are
injected; no human clicking) — before any on-device pass.**

```
e2e/
  run_all.sh            ← one command: Tier 1 + Tier 2 across reachable sims,
                          summary table, parseable pass/fail (exit code)
  mock_realtime/        ← hermetic OpenAI-Realtime WS mock (pure Dart)
    lib/mock_realtime.dart   library: MockRealtimeServer + synthesized PCM
    bin/serve.dart           standalone CLI for device / manual runs
  scenarios/            ← THE RIGOROUS SIMULATION GATE (E2E_TARGETS=gate):
                          regression scenarios with measured asserts +
                          gate_metrics.py (log → JSON measurements →
                          threshold verdicts) — see e2e/scenarios/README.md
  baselines/            ← archived gate-metrics.json snapshots (trend record)
example/test/e2e/       ← Tier 1 (no device, ~5 s)
example/integration_test/
  e2e_session_flow_test.dart   ← Tier 2 core: full app vs mock voice (macOS)
  e2e_boot_smoke_test.dart     ← Tier 2: boot → avatar canvas (all targets)
  engine_smoke_test.dart       ← Tier 2: plugin-direct engine + injected PCM
  e2e_idle_stability_test.dart ← GATE scn 1: mic-on idle (macOS + iOS sim)
  e2e_storm_lifecycle_test.dart← GATE scn 2: storm / barge / stuck gate
  e2e_drive_soak_test.dart     ← GATE scn 3/4/5: Android pacing/gate/governor
  native_log_capture.dart      ← dup2(2) NSLog capture (macOS unified log
                                 redacts NSLog bodies; stderr is the truth)
```

## Quick start (what an agent runs)

```bash
flutter/bithuman/e2e/run_all.sh                    # tier1 + macOS + iOS sim
E2E_TARGETS=gate        flutter/bithuman/e2e/run_all.sh   # the FULL gate
E2E_TARGETS=tier1,macos flutter/bithuman/e2e/run_all.sh
E2E_TARGETS=android     flutter/bithuman/e2e/run_all.sh
```

Output ends with a summary table; exit 0 ⇔ every selected target passed
(`skip` never fails a run). Per-target logs land in
`/tmp/bithuman-e2e-harness/`.

**Hot-file churn:** if other agents have uncommitted edits to the native
plugins in your checkout, build from a clean worktree
(`git worktree add /tmp/bh-e2e-wt HEAD`), copy `e2e/`, `example/test/e2e/`,
the three `integration_test/e2e_*`/`engine_smoke_test.dart` files,
`example/pubspec.yaml` and `lib/bithuman_realtime.dart` over, and run there
— the harness only depends on those paths.

## Tier 1 — widget/unit (`example/test/e2e/`, plus the pre-existing
`avatar_canvas_fit_test.dart`)

Pure Dart, no device, runs in seconds. The REAL realtime client
(`lib/bithuman_realtime.dart`) talks to a REAL loopback WebSocket served by
`mock_realtime`; the native engine is a recorded test double
(`fake_avatar_platform.dart`).

| file | proves |
|---|---|
| `realtime_session_mock_test.dart` | connect contract (GA `session.update` shape, server-VAD config), **voice policy** (exactly one connect greeting today — see TODOs), audio deltas → unified speaker/lipsync, transcript stream, **pacing governor** (burst 1 s of deltas must release ≥ ~realtime), **barge-in** (`response.cancel` + `avatar.interrupt` + stale-delta drop), cancel-when-idle guard, mic mute = deaf, **clean stop** (interrupt + audioStop + socket closed + no late audio) |
| `transport_state_machine_test.dart` | the exact `TransportStatus` sequence the UI chrome switches on: `connecting → listening → responseDone → userSpeaking → thinking → responseDone → closed` |
| `engine_config_test.dart` | engine-default logic (host = essence; Android's elevate default is asserted on-emulator), download-host allow-lists, voice/VAD defaults |

## Tier 2 — real app on simulators (`example/integration_test/`)

All Tier 2 profiles are launched with:

```
--dart-define=DEV_AUTH_BYPASS=true        # skip the Clerk gate
--dart-define=OPENAI_API_KEY=e2e-mock-key # FAKE; keeps the app off the
                                          # ephemeral-token backend (the mock
                                          # accepts any Bearer). Never a real key.
```

### macOS — `e2e_session_flow_test.dart` (the core deliverable)

The full product loop against the in-process mock voice backend
(`BithumanRealtimeSession.debugEndpointOverride` → `ws://127.0.0.1:<port>`):

launch → avatar texture on canvas → elevate warm-up gate clears → **mic
tap** → WS connect (handshake asserted server-side) → scripted reply streams
(synthesized PCM @24 kHz + transcript; captions UI verified) → **barge-in**
(client must emit `response.cancel`) → recovery reply → **hang-up** (client
closes the socket, UI back to idle, no stuck gate). `run_all.sh` additionally
greps the run log for the NATIVE markers the in-process test can't see:
`[elevate-av] … first frame` and `[realtime] ws closed`.

Engine asset: with `BITHUMAN_ENGINE=elevate` the app cache-hits
`~/Library/Application Support/ai.bithuman.app/elevate/A63GVG1577.elevatedir`
(no network). First-ever elevate run on a machine pays a one-time ~2 min
CoreML compile — the test budgets for it (`E2E_LOAD_BUDGET_S`, default 240).

### iOS Simulator — `e2e_boot_smoke_test.dart` — **SUPPORTED (2026-06-11)**

`libessence2.xcframework` and `libconverse.xcframework` now vendor an
**ios-arm64-simulator** slice (libessence + onnxruntime already had one) —
built by `bithuman-sdk` `engine/{elevate,converse}/build-xcframework.sh`
(arm64-only: Apple-Silicon hosts; Intel hosts would need x86_64 sim builds
of every third-party dep, not provided). `run_all.sh` still probes for the
slice and auto-skips on checkouts bootstrapped against an older SDK drop.
After re-vendoring, re-run `pod install` in `example/ios` once — the
CocoaPods slice-selection script is generated from the xcframework's
Info.plist at install time.

Staging (simulator apps can read HOST paths — nothing big is copied):
- `elevate_lab: $E2E_ELEVATE_SRC` written into the app-container
  `config.json` before `app.main()` (v3 elevatedir read in place);
- the Expression actor model (`E2E_ACTOR_SRC`, the 1.5 GB
  `expression-engine-1.0-int4.bhx`) **symlinked** into the plugin's
  motionDir (`…/elevate/motion_export/`) — without it `be_essence2_create`
  fails fast with "actor model … not found" on a fresh container.

Asserts: boot under auth bypass → texture → idle mic UI → never `Failed` —
PLUS native-marker truth from the sim's **unified log** (`simctl spawn …
log show`), which the in-process test can't see: `be_essence2_create failed`
⇒ FAIL, missing `first frame` marker ⇒ FAIL. (A `Texture` widget exists
even when engine create fails, so the widget-level pass alone is too weak
on iOS.)

Sim-only runtime scope — the elevate engine runs **idle-only** there:
bundle parse, idle frames on the texture (40 ms cadence) and the m4b
director's CoreML load (CPU — no ANE/GPU on sim) are all REAL; the talking
pipeline is not, because **MLX cannot run on the iOS simulator** — Cmlx is
compiled with the Metal backend, so the global allocator is the
MetalAllocator whose ctor ABORTS inside the sim Metal driver
(`MTLSimDevice newHeapWithDescriptor:` assert — uncatchable; and before
that `metal::Device()` SEGVs on the sim device's nil architecture name).
`HardwareSupport.check()` therefore rejects `targetEnvironment(simulator)`
with an explicit sim reason BEFORE any MLX symbol is touched, so warm-up
fails the GRACEFUL way (`runtime warm-up FAILED … engine stays idle-only`
in the unified log — expected on sim) instead of crashing the app ~2 s
after boot. Voice/talking coverage on iOS stays with Tier 1 + the macOS
flow (same Darwin plugin) + Tier 3 hardware.

Audio scope on the iOS sim: VP-IO/AEC does NOT exist there
— audio **route** tests stay on-device (Tier 3); audio **logic** is covered
by Tier 1 + the injected-PCM engine smoke.

### Android emulator — `e2e_boot_smoke_test.dart` / `engine_smoke_test.dart`
### — **VALIDATED 2026-06-11 on the arm64 `bench-arm64` AVD (API 29)**

arm64 AVD (Apple-Silicon hosts run arm64 images natively — le_core's
arm64-v8a JNI loads in-emulator, proven). Two profiles:

- **full engine (`E2E_ANDROID_BUNDLE=<le-bundle dir>`)** — what was run:
  push the bundle to `/data/local/tmp/e2e/bundle` + `chmod -R a+rX`
  (app-readable on the API-29 google_apis image; if a newer image
  SELinux-denies shell_data_file reads, stage inside
  `/data/data/ai.bithuman.bithuman_example/files/` via `adb root` + `cp` +
  `chown` + `restorecon` — both mechanisms validated). Then:
  1. `engine_smoke_test.dart` — le_core JNI loads, bundle parses
     (`motion_ranges: … of 778 drive frames`), frame size reported,
     `setSpeaking(true/false)` round-trips;
  2. `e2e_boot_smoke_test.dart` — FULL app boot: auth bypass → elevate
     engine from the staged bundle (`config.json: elevate_lab`) → texture
     renders → idle mic UI;
  3. logcat asserts the **mouth-gate flip**: `mode -> TALKING [245,446]` /
     `mode -> IDLE [0,244]` from the Kotlin plugin.
  Gotcha: `flutter test` wipes app data when dart-defines change between
  runs (uninstall+reinstall) — staging under `/data/local/tmp` survives;
  app-data staging does not.
- **default (hermetic, no bundle):** `ELEVATE_CATALOG_URL` pointed at an
  unroutable address + `E2E_EXPECT_FAILURE=true` asserts the graceful
  `Failed … + Retry` state — the UI contract that replaced the endless
  spinner. NOTE: that error UI ships with the in-flight Android-finisher
  change; this profile passes once it lands on main.

Voice flow on Android/iOS is NOT mockable yet — the WebRTC transport
hard-codes the OpenAI URL inside a hot file (see TODOs).

## Tier 3 — device smoke (thin; documented, not automated here)

Reuse the SAME integration tests on hardware for what physically needs it:

1. audio ROUTE (VP-IO/AEC on iPhone/Mac speakers+mic, speakerphone routing
   on Android): run the app with a REAL session once per release candidate.
2. mock-backed session on-device when the cloud is suspect: run
   `dart run e2e/mock_realtime/bin/serve.dart --port 8765` on the host and
   launch the app with
   `--dart-define=BITHUMAN_REALTIME_WS_URL=ws://<host-ip>:8765` (macOS WS
   path) — same scripted greeting/barge scenario, zero OpenAI dependency.
3. `flutter test integration_test/e2e_boot_smoke_test.dart -d <device-id>`
   works unchanged on devices.

## Mock backend design (`e2e/mock_realtime`)

- Pure-Dart `HttpServer` + `WebSocketTransformer` on `127.0.0.1` (ephemeral
  port). Speaks the exact GA event subset the app's client consumes.
- **Unscripted core, scripted by the test:** every client→server event is
  recorded (`received`, `nextEvent()`, `eventsOfType()`); the test drives
  the conversation (`sendResponse`, `sendSpeechStarted`, …) so scenario
  logic lives next to the UI assertions. `bin/serve.dart` wraps it with an
  auto-driving scenario for out-of-process runs.
- Audio fixtures are **synthesized** (`synthPcm`: amplitude-modulated
  speech-band tone) — no binaries in the repo, deterministic, and obviously
  secret-free. The Bearer header is recorded for assertions, never validated.
- `sendResponseCancelled()` halts any in-flight delta stream (generation
  guard), mirroring the real server's cancel semantics.

## Staging reference

| target | engine asset | how it gets there |
|---|---|---|
| macOS | `…/ai.bithuman.app/elevate/A63GVG1577.elevatedir` (v3, 274 MB) | already-delivered app cache (or `--dart-define=ELEVATE_LAB=<host path>`) |
| iOS sim | host `A63GVG1577_v3.elevatedir` | `E2E_ELEVATE_SRC` → test writes `config.json: elevate_lab` (sim reads host fs) |
| iOS sim | host `expression-engine-1.0-int4.bhx` (actor, 1.5 GB) | `E2E_ACTOR_SRC` → test symlinks it into `…/elevate/motion_export/` (sim resolves host symlink targets) |
| Android emu | le-bundle dir (`~/bithuman/_elevate_runtime_lab/A63GVG1577.lebundle`) | `E2E_ANDROID_BUNDLE` → adb push `/data/local/tmp/e2e/bundle` |

A SMALLER test bundle (e.g. ~60 drive frames) can be assembled with
`bithuman-sdk/engine/elevate/runtime-cpu/tools/make_bundle.py` (slice the
per-frame arrays + drive protocol and rewrite `NT` in the manifest) when the
full bundles get too heavy for repeated emulator pushes — not needed on this
machine (sims read the host assets in place; nothing is copied).

## TODOs — hooks owned by in-flight hot files (do NOT edit here)

- **`openai_webrtc_session.dart` (iOS/Android voice):** needs an endpoint
  override (mirror of `BithumanRealtimeSession.debugEndpointOverride` /
  `BITHUMAN_REALTIME_WS_URL`) so the WebRTC dial — or a WS fallback mode —
  can target the mock; until then, mobile Tier 2 voice = Tier 1 logic +
  engine smoke, and `e2e_session_flow_test.dart` skips off-macOS.
- **Voice-policy alignment:** the WebRTC transport already enforces "no
  proactive speech" (greeting is opt-in via `BITHUMAN_DEV_GREETING`); the
  macOS WS session still ALWAYS greets on connect (it doubles as the
  connection-validation watchdog probe). When the WS path aligns, flip the
  one-greeting expectations in `realtime_session_mock_test.dart` and
  `e2e_session_flow_test.dart` to zero.
- **Native frame counter:** no Dart-visible perf/test channel exists; tests
  assert texture presence + frame size, and `run_all.sh` greps native
  `[elevate-av]` log lines. A tiny `framesComposed` getter on the plugin
  channel would let tests assert frame ADVANCE in-process.

## Validation record (2026-06-11, harness bring-up)

Run against committed HEAD `16c7d9a` + this harness (clean worktree; the
finishers' uncommitted native edits were mid-flight in the main checkout):

| leg | result | notes |
|---|---|---|
| Tier 1 (23 tests: 16 new + 7 canvas-fit) | **pass** | ~5 s on host |
| Tier 2 macOS session flow (elevate, mock voice) | **pass** | 13 s test time, warm engine; boot→texture→warm-up gate→mic tap→handshake→captions transcript→barge `response.cancel`→recovery→clean hang-up |
| Tier 2 Android engine smoke (emulator, le-bundle) | **pass** | le_core JNI in arm64 AVD; mouth gate TALKING/IDLE flips in logcat |
| Tier 2 Android full-app boot smoke (elevate staged) | **pass** | 8 s; texture + idle mic UI |
| Tier 2 iOS Simulator boot smoke (elevate staged, 2026-06-11 sim slices) | **pass** | iPhone 17 Pro sim; texture 720x1280 + idle mic UI + native `first frame` marker, no `be_essence2_create failed` (unified-log asserts) |

## Known constraints

- The Clerk SDK still initializes at launch (one network touch to
  clerk.bithuman.ai; nothing secret sent). Full offline runs would need a
  bypass in `main.dart` — hot file at harness-build time, not pursued.
- macOS mic: `audioStart` brings up VP-IO; the app bundle
  (`ai.bithuman.app`) needs TCC mic approval once per machine, else the mic
  stream is silent (tests don't depend on real mic input).
- `flutter test integration_test -d macos` runs the app windowed on the
  host desktop for the duration of the test (~1–2 min after build).
