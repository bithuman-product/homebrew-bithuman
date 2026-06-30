#!/usr/bin/env python3
"""stress-webrtc-metrics.py — self-interruption metrics from a stress-run log.

Companion to stress-webrtc-iphone.sh (task #56). Parses a captured console
log (devicectl --console / flutter run, timestamped by the runner) from a
BITHUMAN_DEV_STRESS session — continuous agent speech, ZERO user input — so
every server-VAD speech event in the log is by construction a SPURIOUS
barge-in (speaker echo / room noise tripping OpenAI's server_vad).

Counted signals (Dart-side `[webrtc]` prints + native NSLog lines):
  spurious barge-ins   `[webrtc] speech_started (agentAudioOut=…)`  (WebRTC arm)
                       `[RealtimeAudioIO] barge: cancelling`        (WS arm —
                       fired by avatar.interrupt on server-VAD speech_started;
                       with zero user input every one is spurious)
  response cancels     `← response.cancelled`, `← output_audio_buffer.cleared`
  completed turns      `← response.done`
  stress turns issued  `[stress] turn N requested`
  data-channel errors  `← error` / `[webrtc] error event`
  echo leakage         `[AEC-PROBE] user-mic transcript … "<non-empty>"`
  gate health (WS/gated paths only)   `utterance start: holding speaker` vs
                       `speaker START after N ms (firstFrame=yes|TIMEOUT…)`
                       — hold-time stats + TIMEOUT count reported
  A/V skew (WS arm)    `[elevate-av] behind=N` — video frames behind the
                       speaker clock (40 ms each); max reported

Verdict: PASS iff spurious barge-ins == 0 AND cancels == 0 over the window.

Usage:
  stress-webrtc-metrics.py <log> [--label ARM]
  Exit 0 = PASS, 1 = FAIL, 2 = log unusable (no session evidence).
"""

import argparse
import re
import sys
from datetime import datetime, timedelta

# Timestamps: runner's awk stamp "[HH:MM:SS]" (stdout lines), NSLog's
# "YYYY-MM-DD HH:MM:SS.mmm" prefix, or idevicesyslog's "Jun 11 15:20:00"
# (the runner's fallback capture). Any of them anchors the rate window.
TS_AWK = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\]")
TS_NSLOG = re.compile(r"^(?:\[\d{2}:\d{2}:\d{2}\]\s*)?\d{4}-\d{2}-\d{2} (\d{2}):(\d{2}):(\d{2})")
TS_SYSLOG = re.compile(r"^[A-Z][a-z]{2} +\d+ (\d{2}):(\d{2}):(\d{2})")


def line_ts(line):
    m = TS_NSLOG.match(line) or TS_AWK.match(line) or TS_SYSLOG.match(line)
    if not m:
        return None
    h, mnt, s = (int(g) for g in m.groups())
    return timedelta(hours=h, minutes=mnt, seconds=s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--label", default="?")
    args = ap.parse_args()

    n = dict(
        spurious=0, spurious_bot_audible=0, ws_barges=0, cancels=0, cleared=0,
        done=0, stress_turns=0, errors=0, probe_leaks=0, gate_holds=0,
        gate_starts=0, gate_timeouts=0, gate_watchdog=0,
    )
    gate_hold_ms = []   # "speaker START after N ms" — per-utterance hold time
    max_behind = 0      # "[elevate-av] behind=N" — video lag in 40 ms frames
    first = last = None
    session_opened = False

    with open(args.log, errors="replace") as f:
        for line in f:
            ts = line_ts(line)
            if ts is not None:
                if first is None:
                    first = ts
                last = ts
            if ("[webrtc] pc state" in line or "session.created" in line
                    or "[RealtimeAudioIO] up" in line):
                session_opened = True
            if "[webrtc] speech_started" in line:
                n["spurious"] += 1
                if "agentAudioOut=true" in line:
                    n["spurious_bot_audible"] += 1
            # WS arm: avatar.interrupt() (server-VAD speech_started) lands as
            # the native barge line. Zero user input → every one is spurious.
            if "barge: cancelling agent playback" in line:
                n["ws_barges"] += 1
            if "response.cancelled" in line:
                n["cancels"] += 1
            if "output_audio_buffer.cleared" in line:
                n["cleared"] += 1
            if "response.done" in line:
                n["done"] += 1
            if "[stress] turn" in line:
                n["stress_turns"] += 1
            if "[webrtc] error event" in line or re.search(r"←\s*error", line):
                n["errors"] += 1
            m = re.search(r"\[AEC-PROBE\] user-mic transcript[^\"]*\"(.*)\"", line)
            if m and m.group(1).strip():
                n["probe_leaks"] += 1
            if "utterance start: holding speaker" in line:
                n["gate_holds"] += 1
            m = re.search(r"speaker START after (\d+) ms \(firstFrame=(\w+)", line)
            if m:
                n["gate_starts"] += 1
                gate_hold_ms.append(int(m.group(1)))
                if m.group(2) == "TIMEOUT":
                    n["gate_timeouts"] += 1
            elif "speaker START after" in line:
                n["gate_starts"] += 1
            if "gate WATCHDOG release" in line:
                n["gate_watchdog"] += 1
            m = re.search(r"\[elevate-av\] behind=(\d+)", line)
            if m:
                max_behind = max(max_behind, int(m.group(1)))

    if first is None or not session_opened and n["done"] == 0 and n["stress_turns"] == 0:
        print(f"[metrics] {args.log}: no usable session evidence (no timestamps "
              f"or no webrtc/stress events) — wrong log or capture failed")
        return 2

    minutes = max((last - first).total_seconds(), 1.0) / 60.0
    spurious_total = n["spurious"] + n["ws_barges"]
    barge_rate = spurious_total / minutes
    cancel_rate = (n["cancels"] + n["cleared"]) / minutes
    stuck_gate = n["gate_holds"] - n["gate_starts"] - n["gate_watchdog"]

    verdict = "PASS" if spurious_total == 0 and (n["cancels"] + n["cleared"]) == 0 else "FAIL"

    print(f"── stress metrics · arm={args.label} · {args.log}")
    print(f"   window               {minutes:6.1f} min")
    print(f"   spurious barge-ins   {spurious_total:4d}  ({barge_rate:.2f}/min; "
          f"webrtc={n['spurious']} [{n['spurious_bot_audible']} bot-audible], "
          f"ws-native={n['ws_barges']})")
    print(f"   response cancels     {n['cancels']:4d}  (+{n['cleared']} buffer-cleared; {cancel_rate:.2f}/min)")
    print(f"   responses completed  {n['done']:4d}  (stress turns issued: {n['stress_turns']})")
    print(f"   AEC-probe leaks      {n['probe_leaks']:4d}  (non-empty mic transcripts)")
    print(f"   errors               {n['errors']:4d}")
    print(f"   gate health          holds={n['gate_holds']} starts={n['gate_starts']} "
          f"timeouts={n['gate_timeouts']} watchdog={n['gate_watchdog']} "
          f"(unreleased: {max(stuck_gate, 0)})")
    if gate_hold_ms:
        gate_hold_ms.sort()
        med = gate_hold_ms[len(gate_hold_ms) // 2]
        print(f"   gate hold time       median {med} ms · max {gate_hold_ms[-1]} ms "
              f"(n={len(gate_hold_ms)})")
    print(f"   A/V skew (behind)    max {max_behind} frames = {max_behind * 40} ms "
          f"(speaker-clock lag; <150 ms target)")
    print(f"   VERDICT              {verdict}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
