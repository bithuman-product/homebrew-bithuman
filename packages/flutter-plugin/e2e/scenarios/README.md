# The RIGOROUS SIMULATION GATE — regression scenarios + measured asserts

`E2E_TARGETS=gate e2e/run_all.sh` is the authoritative simulator pass every
risky app change must clear: tier 1 + the macOS session flow + the exact
regression scenarios that burned us on 2026-06-11, each one **automatically
driven** (injected audio/events, zero human) and **measured** (numbers parsed
from native logs and asserted against thresholds, not eyeballed).

```
e2e/scenarios/
  gate_metrics.py     ← the log-metrics module (scenario 6): parses
                        [elevate-av]/[elevate-perf]/[elevate-mem]/
                        [RealtimeAudioIO]/[Barge] (Darwin) and the
                        BithumanAvatar logcat lines (Android) into JSON
                        measurements + threshold verdicts. Exit 0/1/3 =
                        pass / fail / SKIPPED (loud).
example/integration_test/
  e2e_idle_stability_test.dart   ← scenario 1 driver (macOS + iOS sim)
  e2e_storm_lifecycle_test.dart  ← scenario 2 driver (macOS + iOS sim)
  e2e_drive_soak_test.dart       ← scenarios 3/4/5 driver (Android emu)
```

Per-run artifact: `/tmp/bithuman-e2e-harness/gate-metrics.json` (merged,
machine-readable, with the git rev). `E2E_ARCHIVE_BASELINE=1` snapshots it
into `e2e/baselines/` for run-over-run trend comparison.

## The scenarios (and the bug each one re-catches)

| # | scenario | drives | measured asserts |
|---|---|---|---|
| 1 | **mic-on idle stability** (iOS idle-flicker, the moment the mic opened) | plugin-direct elevate + real `BithumanRealtimeSession` vs the mock WS server; 60 s session, ZERO agent speech | zero interrupt-ramps / slip clusters (`behind=`) / gate lines / `frame dims ->` flaps; exactly 1 connection, 1 greeting `response.create`, 0 `response.cancel`; iOS sim: warming-heartbeat cadence (`[elevate-mem]` every ~5 s, median 4–7 s, p95 ≤ 9 s) proves the compose tick advances monotonically at a steady rate |
| 2 | **storm/silence/stuck-gate lifecycle** (self-interruption storm, inaudible audio, stuck holding) | ≥20 s synthesized utterance streamed 2× realtime → mid-utterance barge (`speech_started`) → recovery utterance → clean stop | 0 cancels before user speech, exactly 1 after, bounded ≤5 s; recovery turn reaches `responseDone` ≤15 s (no stuck state); **macOS engine truth:** every `holding speaker` has a `speaker START after N ms` partner with N ≤ 4000 (onset measured + archived), frames queue ≤ 50 (drains under the delta storm), A/V skew (`behind`×40 ms) ≤ 1500 ms, recovery utterance sustains ≥ 50 frames on the texture |
| 3 | **Android pacing truth** (the 3–10× slow-motion bug) | 80 s drive-loop soak on the emulator | slot coverage rate from the `perf: … fps, … slots skipped` lines (the 3805209 instrumentation) = **25 slots/s ± 2 %** regardless of emulator render speed; drop rate archived |
| 4 | **Android mouth-gate flips** | `setSpeaking(true/false)` ×2 cycles during the soak | logcat-timestamp latency `setSpeaking(x)` → `mode -> TALKING/IDLE` ≤ 3500 ms (= 1.5× the chunked pipeline's designed ~1-chunk preempt: batch 24 × emulator ~90-110 ms/f render); every flip measured + archived |
| 5 | **Android governor sanity** (task48) | same soak capture | feature-detected: no `governor:` lines ⇒ scenario **SKIPPED loudly** (exit 3, shown in the summary — never a silent pass); present ⇒ stride changes ≤ 6/min (no oscillation), strides within 1..8 |
| 6 | **A/V timing extraction** | — | `gate_metrics.py` itself: onset ms, skew ms, slot-rate, cadence, ramp counts → per-scenario JSON + merged `gate-metrics.json` |
| 7 | **gate wiring** | `E2E_TARGETS=gate` | summary table; exit code = gate verdict (skips never fail, FAIL always does) |

## Honest boundaries (what the sim legs do NOT prove)

- **iOS sim forces the WebSocket transport** (via
  `BithumanRealtimeSession.debugEndpointOverride` straight at the session —
  the mock speaks WS). Real iPhones use the WebRTC transport; these legs
  prove **session lifecycle / barge / pacing logic**, NOT WebRTC audio
  behavior (AEC, routing, remote-track playout). WebRTC audio stays Tier-3
  device scope (`scripts/` stress runs + release-candidate device pass).
- **iOS sim engine is idle-only**: the elevate speech runtime is MLX/Metal
  and cannot run on the simulator, so gate-release/queue/skew truth comes
  from the **macOS leg of the same scenarios** (same Darwin plugin source,
  `shared/Classes/`). The sim still measures the thing that actually
  flickered: the idle compose tick under a live audio session.
- **Plugin-direct, not the app UI**: the app's mic button is warm-up-gated,
  which the sim can never satisfy. The full UI loop (button → transport →
  captions → hang-up chrome) is covered by `e2e_session_flow_test.dart`
  (macOS) in the same gate run.
- The greeting expectation (exactly ONE `response.create` on connect)
  tracks the CURRENT WS contract; when the parked #55 voice-policy change
  (silent `session.updated` probe) re-lands, flip the idle/storm scenario
  expectations to zero greetings alongside the tier-1 ones.

## Running pieces by hand

```bash
E2E_TARGETS=macos_scn   e2e/run_all.sh
E2E_TARGETS=ios_scn     e2e/run_all.sh
E2E_TARGETS=android_scn e2e/run_all.sh   # boots bench-arm64 (heavy)

# re-judge an existing log without re-running anything:
python3 e2e/scenarios/gate_metrics.py android-pacing \
    --log /tmp/bithuman-e2e-harness/android-soak-logcat.log
```

Thresholds are flags on `gate_metrics.py` (defaults above) — tune them in
ONE place; the Dart drivers stay threshold-free on purpose.

## Operational notes (learned during bring-up, 2026-06-11)

- **GUI legs are opt-in** (`E2E_ALLOW_GUI=1`, c4135ad): the user asked that
  app windows / fixture audio never pop unattended. The macOS legs run the
  app windowed and the storm scenario plays ~30 s of synthesized tone on
  the speakers — coordinate with the user before running. Closing the
  window mid-run shows up as `did not complete` + a `willTerminate` line
  in the native log (that burned three bring-up runs).
- Waits are **wall-clock** (`Future.delayed`), never `tester.pump` loops:
  with a fullyLive binding, pump awaits a real vsync and macOS throttles
  occluded windows — a pump loop can stall for minutes.
- `avatar.dispose()` after real speech can hit the long-standing macOS
  elevate join-teardown hang (the app's quit path uses `_exit` — 33fc4e6);
  the scenario tests bound it with a 20 s timeout AFTER the verdict.
- NSLog truth is captured via dup2(2) (`native_log_capture.dart`): the
  macOS unified log redacts NSLog bodies as `<private>` and the flutter
  tool swallows the app's stderr. The iOS sim leg writes the same capture
  to a host path (sim apps can write host files), with `simctl log show`
  as fallback.
- Baseline artifacts live in `e2e/baselines/gate-metrics-<date>-<rev>.json`
  — compare run-over-run before trusting a "pass" that moved a number.
