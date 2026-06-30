#!/usr/bin/env python3
"""gate_metrics.py — the e2e gate's log-metrics module (scenario 6 of the
rigorous-simulation gate).

Parses the app's native log vocabulary —
  Darwin  : [elevate-av] / [elevate-perf] / [elevate-mem] / [RealtimeAudioIO] /
            [Barge] NSLog lines (macOS unified log / iOS-sim `simctl log show`)
  Android : BithumanAvatar logcat lines (perf: …, mode -> …, setSpeaking(…),
            governor: …)
— into machine-readable MEASUREMENTS (onset ms, skew ms, slot-rate, cadence,
ramp/flicker counts, flip latency) and asserts the gate's thresholds against
them. One JSON artifact per scenario; `merge` combines them into the run's
gate-metrics.json so numbers can be trend-compared run over run.

Usage:
  gate_metrics.py darwin-idle      --log L [--cadence] [--soak-s 60] [--out J]
  gate_metrics.py darwin-storm     --log L [--sim]                   [--out J]
  gate_metrics.py android-pacing   --log L                           [--out J]
  gate_metrics.py android-mouthgate --log L                          [--out J]
  gate_metrics.py android-governor --log L                           [--out J]
  gate_metrics.py merge            --out gate-metrics.json J1 J2 …

Exit codes: 0 = pass, 1 = fail, 3 = SKIPPED (loudly — e.g. the governor
scenario before the governor build lands; never a silent pass).

Stdlib only; no third-party deps. Apache-2.0; (c) bitHuman.
"""

import argparse
import json
import re
import statistics
import sys
from datetime import datetime

EXIT_PASS, EXIT_FAIL, EXIT_SKIP = 0, 1, 3

# ── timestamp parsing ────────────────────────────────────────────────────
# unified log (`log show --style compact` on macOS / iOS sim):
#   2026-06-11 19:20:01.123456-0500 Df Runner[123:456] …
TS_UNIFIED = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})\.(\d+)")
# logcat -v time:  06-11 19:20:01.123 I/BithumanAvatar( 1234): …
TS_LOGCAT = re.compile(r"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})")


def _ts_of(line):
    m = TS_UNIFIED.match(line)
    if m:
        y, mo, d, h, mi, s, frac = m.groups()
        t = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s))
        return t.timestamp() + float("0." + frac)
    m = TS_LOGCAT.match(line)
    if m:
        mo, d, h, mi, s, ms = m.groups()
        # year is absent in logcat; only deltas matter — pin to 2000 (leap).
        t = datetime(2000, int(mo), int(d), int(h), int(mi), int(s))
        return t.timestamp() + int(ms) / 1000.0
    return None


TEARDOWN_MARKER = "[e2e-marker] teardown-begin"


def read_log(path, cut_at_teardown=False):
    """[(ts_or_None, line)] — lines kept even without a parseable stamp.

    cut_at_teardown drops everything from the test's teardown marker on:
    a clean stop() legitimately fires one avatar.interrupt, which must not
    count against the scenario window."""
    out = []
    with open(path, "r", errors="replace") as f:
        for line in f:
            if cut_at_teardown and TEARDOWN_MARKER in line:
                break
            out.append((_ts_of(line), line.rstrip("\n")))
    return out


def stamps(lines, pattern):
    rx = re.compile(pattern)
    return [ts for ts, l in lines if ts is not None and rx.search(l)]


def count(lines, pattern):
    rx = re.compile(pattern)
    return sum(1 for _, l in lines if rx.search(l))


# ── result accounting ────────────────────────────────────────────────────
class Result:
    def __init__(self, scenario):
        self.scenario = scenario
        self.status = "pass"
        self.reason = ""
        self.measurements = {}
        self.checks = []

    def check(self, name, ok, value, limit):
        self.checks.append(
            {"name": name, "ok": bool(ok), "value": value, "limit": limit})
        if not ok:
            self.status = "FAIL"

    def skip(self, reason):
        self.status = "SKIPPED"
        self.reason = reason

    def to_json(self):
        return {
            "scenario": self.scenario,
            "status": self.status,
            **({"reason": self.reason} if self.reason else {}),
            "measurements": self.measurements,
            "checks": self.checks,
        }

    def finish(self, out_path):
        j = self.to_json()
        if out_path:
            with open(out_path, "w") as f:
                json.dump(j, f, indent=2)
        verdict = self.status
        detail = self.reason or "; ".join(
            f"{c['name']}={c['value']}" for c in self.checks if not c["ok"])
        print(f"[gate-metrics] {self.scenario}: {verdict}"
              + (f" — {detail}" if detail and verdict != "pass" else ""))
        for c in self.checks:
            mark = "ok " if c["ok"] else "FAIL"
            print(f"  {mark} {c['name']}: {c['value']} (limit {c['limit']})")
        if self.status == "pass":
            return EXIT_PASS
        if self.status == "SKIPPED":
            return EXIT_SKIP
        return EXIT_FAIL


# ── darwin-idle: mic-on idle stability (today's iOS flicker) ─────────────
# The avatar must hold a STEADY idle while a session is open with no agent
# speech: zero interrupt-ramps, zero slip clusters, zero utterance/gate
# activity, no display-mode (dims) flapping; on the iOS sim the warming
# heartbeat ([elevate-mem] every 125 ticks ≈ 5 s) doubles as the compose-tick
# cadence truth (steady tick ⇒ monotonic idle frame advance).
PATHOLOGY = [
    ("utterance_lines", r"\[elevate-av\] utterance"),
    ("slip_clusters", r"\[elevate-av\] behind="),
    ("speaker_gate_lines",
     r"speaker START after|holding speaker for first frame"),
    ("interrupt_ramps",
     r"\[Barge\]|barge: cancelling|energy VAD: sustained"),
    ("transition_ramps", r"\[elevate-clock\].*ramp"),
    ("dims_switches", r"frame dims ->"),
    ("idle_hold_flaps", r"idle-hold (engaged|released)"),
    ("engine_create_failures", r"be_essence2_create failed"),
    ("ws_reconnects", r"socket stuck; reconnecting"),
]


def darwin_idle(args):
    lines = read_log(args.log, cut_at_teardown=True)
    r = Result("darwin-idle" + ("-sim" if args.cadence else ""))
    for name, pat in PATHOLOGY:
        n = count(lines, pat)
        r.measurements[name] = n
        r.check(name, n == 0, n, 0)
    if args.cadence:
        beats = stamps(lines, r"\[elevate-mem\] warming")
        r.measurements["cadence_lines"] = len(beats)
        ivals = [b - a for a, b in zip(beats, beats[1:]) if b - a >= 0]
        need = max(4, int(args.soak_s * 0.6 / 5))
        r.check("cadence_line_count>=", len(beats) >= need, len(beats), need)
        if len(ivals) >= 3:
            med = statistics.median(ivals)
            p95 = sorted(ivals)[max(0, int(len(ivals) * 0.95) - 1)]
            r.measurements["cadence_interval_median_s"] = round(med, 2)
            r.measurements["cadence_interval_p95_s"] = round(p95, 2)
            # 125 ticks @40 ms = 5 s nominal; a stalled/slipping compose
            # loop stretches these (the flicker fingerprint).
            r.check("cadence_median_s", 4.0 <= med <= 7.0, round(med, 2),
                    "[4.0,7.0]")
            r.check("cadence_p95_s", p95 <= 9.0, round(p95, 2), "<=9.0")
    else:
        # macOS post-ready idle has no heartbeat log; require life proof.
        alive = count(lines, r"first frame \(bundle idle\)|engine ready")
        r.measurements["life_markers"] = alive
        r.check("life_markers>=1", alive >= 1, alive, ">=1")
    return r.finish(args.out)


# ── darwin-storm: long utterance → barge → recovery (today's iOS killers) ─
def darwin_storm(args):
    lines = read_log(args.log, cut_at_teardown=True)
    r = Result("darwin-storm" + ("-sim" if args.sim else ""))
    crash = count(lines, r"be_essence2_create failed|Fatal error|EXC_BAD")
    r.measurements["crash_markers"] = crash
    r.check("crash_markers", crash == 0, crash, 0)
    if args.sim:
        # iOS sim boundary (honest): the elevate SPEECH path cannot run on
        # the simulator (MLX/Metal), so gate/queue/onset truth is measured on
        # the macOS leg of this same scenario (same Darwin plugin); the sim
        # leg's session-logic asserts live in the Dart test itself.
        r.measurements["engine_truth"] = "SKIPPED-sim (idle-only engine)"
        return r.finish(args.out)

    holding = count(lines, r"holding speaker for first frame")
    starts = [float(m.group(1)) for _, l in lines
              for m in [re.search(r"speaker START after (\d+(?:\.\d+)?) ms",
                                  l)] if m]
    ungated = count(lines, r"speaker plays ungated")
    barges = count(lines, r"barge: cancelling agent playback")
    r.measurements["gate_holds"] = holding
    r.measurements["gate_release_onset_ms"] = starts
    r.measurements["ungated_utterance_starts"] = ungated
    r.measurements["barge_count"] = barges

    # No stuck gate: every hold must have a matching release.
    r.check("gate_holds_all_released", holding == len(starts),
            f"holds={holding} releases={len(starts)}", "equal")
    for i, ms in enumerate(starts):
        r.check(f"gate_release_ms[{i}]", ms <= args.gate_max_ms, ms,
                f"<={args.gate_max_ms}")
    r.check("barge_count>=1", barges >= 1, barges, ">=1")

    # Utterance segmentation over the compose-loop lines.
    segs, cur = [], None
    qmax, bmax = 0, 0
    for _, l in lines:
        if "utterance first frame on texture" in l:
            if cur is not None:
                segs.append(cur)
            cur = {"max_frame": 0}
        m = re.search(r"queue=(\d+)", l)
        if m:
            qmax = max(qmax, int(m.group(1)))
        m = re.search(r"behind=(\d+) queue=(\d+) \(utterance frame (\d+)", l)
        if m and cur is not None:
            bmax = max(bmax, int(m.group(1)))
            cur["max_frame"] = max(cur["max_frame"], int(m.group(3)))
    if cur is not None:
        segs.append(cur)
    r.measurements["utterances_on_texture"] = len(segs)
    r.measurements["max_queue_frames"] = qmax
    r.measurements["max_behind_frames"] = bmax
    r.measurements["max_skew_ms"] = bmax * 40
    r.measurements["utterance_max_frames"] = [s["max_frame"] for s in segs]

    # Both the cancelled long utterance AND the recovery utterance must have
    # reached the texture; the recovery one must SUSTAIN (≥50 of 125 frames).
    r.check("utterances_on_texture>=2", len(segs) >= 2, len(segs), ">=2")
    if segs:
        r.check("second_utterance_sustained_frames",
                segs[-1]["max_frame"] >= 50, segs[-1]["max_frame"], ">=50")
    # Queue bounded = the lipsync/frames backlog drains instead of growing
    # without bound under a 2x-realtime delta storm.
    r.check("max_queue_frames", qmax <= args.queue_max, qmax,
            f"<={args.queue_max}")
    r.check("max_skew_ms", bmax * 40 <= args.skew_max_ms, bmax * 40,
            f"<={args.skew_max_ms}")
    return r.finish(args.out)


# ── android-pacing: slot-rate == wall clock (the slow-motion bug) ────────
# Committed (3805209) format:
#   perf: render R + upload U ms/frame, F fps, S slots skipped over last 100 frames
# Governor (task48) format:
#   perf: paste P + upload U ms/frame, render R ms/f, F fps displayed @
#   stride K (T target), S entries skipped, Z stall ticks over last 100 frames
RX_PERF_HEAD = re.compile(
    r"perf: render ([\d.]+) \+ upload ([\d.]+) ms/frame, ([\d.]+) fps, "
    r"(\d+) slots skipped")
RX_PERF_GOV = re.compile(
    r"perf: paste ([\d.]+) \+ upload ([\d.]+) ms/frame, render ([\d.]+) "
    r"ms/f, ([\d.]+) fps displayed @ stride (\d+) \(([\d.]+) target\), "
    r"(\d+) entries skipped, (\d+) stall ticks")


def _perf_windows(lines):
    wins = []
    for _, l in lines:
        m = RX_PERF_HEAD.search(l)
        if m:
            wins.append({"fps": float(m.group(3)), "skipped": int(m.group(4)),
                         "stride": 1, "render_ms": float(m.group(1)),
                         "upload_ms": float(m.group(2)), "stalls": 0})
            continue
        m = RX_PERF_GOV.search(l)
        if m:
            wins.append({"fps": float(m.group(4)), "skipped": int(m.group(7)),
                         "stride": int(m.group(5)),
                         "render_ms": float(m.group(3)),
                         "upload_ms": float(m.group(2)),
                         "stalls": int(m.group(8))})
    # First window logs fps=0.0 (no winStartMs yet) — startup transient.
    return [w for w in wins if w["fps"] > 0.0]


def android_pacing(args):
    lines = read_log(args.log)
    r = Result("android-pacing")
    wins = _perf_windows(lines)
    r.measurements["perf_windows"] = len(wins)
    if not wins:
        r.check("perf_windows>=1", False, 0, ">=1")
        return r.finish(args.out)
    # Wall-clock identity per window: 100 frames displayed + S skipped, each
    # covering `stride` slots, PLUS the stall ticks the governor build
    # forgives (clock pauses ~1 slot per stalled tick — 0820ae0), over
    # 100/fps seconds ⇒ slot coverage rate must be the 25 slots/s drive
    # clock REGARDLESS of how slow the emulator renders (the slow-motion
    # bug stretched time instead of dropping).
    rates, durs = [], []
    for w in wins:
        dur = 100.0 / w["fps"]
        slots = (100 + w["skipped"]) * w["stride"] + w["stalls"]
        rates.append(slots / dur)
        durs.append(dur)
    agg = sum((100 + w["skipped"]) * w["stride"] + w["stalls"]
              for w in wins) / sum(durs)
    r.measurements["slot_rate_per_window"] = [round(x, 2) for x in rates]
    r.measurements["slot_rate_aggregate"] = round(agg, 3)
    r.measurements["displayed_fps_mean"] = round(
        statistics.mean(w["fps"] for w in wins), 2)
    r.measurements["skipped_per_window"] = [w["skipped"] for w in wins]
    r.measurements["stalls_per_window"] = [w["stalls"] for w in wins]
    r.measurements["strides"] = sorted({w["stride"] for w in wins})
    r.measurements["render_ms_mean"] = round(
        statistics.mean(w["render_ms"] for w in wins), 1)
    tol = 25.0 * args.tolerance_pct / 100.0
    r.check("slot_rate_aggregate≈25/s",
            abs(agg - 25.0) <= tol, round(agg, 3),
            f"25±{args.tolerance_pct}%")
    # Skip counter sanity: skips must account for exactly the slots the
    # displayed rate missed (they already do by construction of the identity
    # above; this records the drop rate for the artifact).
    drop_rate = sum(w["skipped"] * w["stride"] for w in wins) / sum(durs)
    r.measurements["dropped_slots_per_s"] = round(drop_rate, 2)
    return r.finish(args.out)


# ── android-mouthgate: setSpeaking ↔ mode flip latency ───────────────────
def _pair_latencies(triggers, flips):
    out = []
    for t in triggers:
        cands = [f for f in flips if f >= t]
        if cands:
            d = cands[0] - t
            if d < 0:
                d += 86400  # logcat midnight rollover
            out.append(round(d * 1000.0, 1))
    return out


def android_mouthgate(args):
    lines = read_log(args.log)
    r = Result("android-mouthgate")
    st = stamps(lines, r"setSpeaking\(true\)")
    sf = stamps(lines, r"setSpeaking\(false\)")
    ft = stamps(lines, r"mode -> TALKING")
    fi = stamps(lines, r"mode -> IDLE")
    lat_t = _pair_latencies(st, ft)
    lat_i = _pair_latencies(sf, fi)
    r.measurements["talking_flip_latency_ms"] = lat_t
    r.measurements["idle_flip_latency_ms"] = lat_i
    r.measurements["setSpeaking_true"] = len(st)
    r.measurements["setSpeaking_false"] = len(sf)
    r.check("talking_flips>=", len(lat_t) >= args.min_flips, len(lat_t),
            f">={args.min_flips}")
    r.check("idle_flips>=", len(lat_i) >= args.min_flips, len(lat_i),
            f">={args.min_flips}")
    for i, ms in enumerate(lat_t):
        r.check(f"talking_flip_ms[{i}]", ms <= args.flip_max_ms, ms,
                f"<={args.flip_max_ms}")
    for i, ms in enumerate(lat_i):
        r.check(f"idle_flip_ms[{i}]", ms <= args.flip_max_ms, ms,
                f"<={args.flip_max_ms}")
    return r.finish(args.out)


# ── android-governor: cadence decisions present + no oscillation ─────────
def android_governor(args):
    lines = read_log(args.log)
    r = Result("android-governor")
    gov = [(ts, l) for ts, l in lines if "governor:" in l]
    if not gov:
        r.skip("no `governor:` lines — the task48 governor build has not "
               "landed in this binary. Scenario SKIPPED (loudly), not passed.")
        return r.finish(args.out)
    strides = []
    for ts, l in gov:
        m = re.search(r"stride (\d+)", l)
        if m:
            strides.append((ts, int(m.group(1))))
    r.measurements["governor_decisions"] = len(gov)
    r.measurements["stride_sequence"] = [s for _, s in strides]
    changes = sum(1 for a, b in zip(strides, strides[1:]) if a[1] != b[1])
    r.measurements["stride_changes"] = changes
    span_ts = [ts for ts, _ in strides if ts is not None]
    span_min = max((span_ts[-1] - span_ts[0]) / 60.0, 1.0) if len(
        span_ts) >= 2 else 1.0
    rate = changes / span_min
    r.measurements["stride_changes_per_min"] = round(rate, 2)
    r.check("stride_changes_per_min", rate <= args.max_changes_per_min,
            round(rate, 2), f"<={args.max_changes_per_min}")
    bad = [s for _, s in strides if not 1 <= s <= 8]
    r.check("strides_in_range_1..8", not bad, bad or "all", "1..8")
    return r.finish(args.out)


# ── merge ────────────────────────────────────────────────────────────────
def merge(args):
    scenarios = []
    for p in args.inputs:
        try:
            with open(p) as f:
                scenarios.append(json.load(f))
        except FileNotFoundError:
            scenarios.append({"scenario": p, "status": "MISSING"})
    doc = {
        "generated": datetime.now().astimezone().isoformat(timespec="seconds"),
        "scenarios": scenarios,
    }
    if args.git_rev:
        doc["git_rev"] = args.git_rev
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"[gate-metrics] merged {len(scenarios)} scenario artifacts "
          f"-> {args.out}")
    return EXIT_PASS


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--log", required=True)
        p.add_argument("--out", default=None)

    p = sub.add_parser("darwin-idle")
    common(p)
    p.add_argument("--cadence", action="store_true",
                   help="iOS sim: require the warming-heartbeat cadence")
    p.add_argument("--soak-s", type=int, default=60)

    p = sub.add_parser("darwin-storm")
    common(p)
    p.add_argument("--sim", action="store_true",
                   help="iOS sim: engine speech truth is out of scope")
    p.add_argument("--gate-max-ms", type=float, default=4000)
    p.add_argument("--queue-max", type=int, default=50)
    p.add_argument("--skew-max-ms", type=float, default=1500)

    p = sub.add_parser("android-pacing")
    common(p)
    p.add_argument("--tolerance-pct", type=float, default=2.0)

    p = sub.add_parser("android-mouthgate")
    common(p)
    # Design contract (task48 chunked pipeline): a setSpeaking flip preempts
    # the stale prefetched chunk, so worst-case latency ≈ one chunk BUILD =
    # batch (24) × per-frame render ms. The emulator renders ~90-110 ms/f ⇒
    # ~2.2-2.6 s; bound at ~1.5 chunks. Measured values are archived in the
    # artifact either way (bring-up baseline: 994/2108 ms talking, 912/25 idle).
    p.add_argument("--flip-max-ms", type=float, default=3500)
    p.add_argument("--min-flips", type=int, default=2)

    p = sub.add_parser("android-governor")
    common(p)
    p.add_argument("--max-changes-per-min", type=float, default=6)

    p = sub.add_parser("merge")
    p.add_argument("--out", required=True)
    p.add_argument("--git-rev", default="")
    p.add_argument("inputs", nargs="+")

    args = ap.parse_args()
    fn = {
        "darwin-idle": darwin_idle,
        "darwin-storm": darwin_storm,
        "android-pacing": android_pacing,
        "android-mouthgate": android_mouthgate,
        "android-governor": android_governor,
        "merge": merge,
    }[args.cmd]
    sys.exit(fn(args))


if __name__ == "__main__":
    main()
