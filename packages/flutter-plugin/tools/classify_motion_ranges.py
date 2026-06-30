#!/usr/bin/env python3
"""Classify an Elevate le-bundle's canned drive protocol into IDLE vs
TALKING frame ranges, and write a `motion_ranges.json` sidecar next to the
bundle's manifest.

Why: the Android frames path (BithumanPlugin.kt) plays the drive protocol —
keypoints captured from a TALKING person — in a loop, so the avatar's mouth
flaps forever regardless of whether the agent is speaking. Until the real
lip-sync actor (LMDM) lands, the plugin uses this sidecar to keep the mouth
quiet between agent responses: it ping-pongs inside an IDLE range while the
agent is silent and inside a TALKING range while audio is playing.

Method: per-frame mouth openness = ||x_d[19] - x_d[20]|| over the drive
keypoints (drive/xd.f32, [N,21,3] float32). Keypoints 19/20 are the
upper/lower-lip pair of LivePortrait's 21 implicit keypoints (lip set
[6,12,14,17,19,20] — light_avatar motion_stitch.py / elevate-swift
pipeline/keypoints.py); the (19,20) distance is the highest-variance lip
pair and spans ~0.02 (closed) → ~0.12 (open) on A63GVG1577. The signal is
box-smoothed, thresholded at MIN + THRESH_FRAC*(P95-MIN), tiny gaps merged,
and runs shorter than the minimums dropped (a dropped run belongs to no
range — the plugin only navigates listed ranges).

Usage:
    python3 classify_motion_ranges.py <bundle_dir> [-o OUT.json]

Staging (Fold example app): push the sidecar next to the staged bundle —
    adb push motion_ranges.json /data/local/tmp/motion_ranges.json
    adb shell run-as ai.bithuman.bithuman_example \
        cp /data/local/tmp/motion_ranges.json files/elevate/avatar.lab/

Apache-2.0; (c) bitHuman.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

NUM_KP = 21
LIP_UPPER, LIP_LOWER = 19, 20  # highest-variance lip pair (mouth open/close)
SMOOTH = 5          # box-filter width (frames)
THRESH_FRAC = 0.40  # idle threshold = min + frac * (p95 - min) of smoothed signal
MERGE_GAP = 3       # close <=N-frame above-threshold blips inside a quiet run
MIN_IDLE = 25       # 1 s @ 25 fps — shorter quiet runs stay "talking"
MIN_TALK = 50       # 2 s — shorter talking runs are dropped (too short to loop)


def runs(mask):
    """Maximal [start, end] (inclusive) runs of True in a bool array."""
    out, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append([i, j - 1])
            i = j
        else:
            i += 1
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("bundle", help="le-bundle directory (contains manifest.json)")
    ap.add_argument("-o", "--out", help="output path (default <bundle>/motion_ranges.json)")
    args = ap.parse_args()

    bundle = Path(args.bundle)
    manifest = json.loads((bundle / "manifest.json").read_text())
    drive = manifest["drive"]
    frames = int(drive["frames"])
    xd = np.fromfile(bundle / drive["xd"], dtype=np.float32)
    if xd.size != frames * NUM_KP * 3:
        sys.exit(f"xd.f32 size {xd.size} != frames {frames} * 63")
    xd = xd.reshape(frames, NUM_KP, 3)

    openness = np.linalg.norm(xd[:, LIP_UPPER] - xd[:, LIP_LOWER], axis=1)
    sm = np.convolve(openness, np.ones(SMOOTH) / SMOOTH, mode="same")
    lo, hi = float(sm.min()), float(np.percentile(sm, 95))
    thr = lo + THRESH_FRAC * (hi - lo)

    quiet = sm < thr
    # Merge tiny above-threshold blips into the surrounding quiet run, but
    # NEVER a real articulation (a blip whose peak reaches mid-open range).
    blip_cap = lo + 0.6 * (hi - lo)
    for s, e in runs(~quiet):
        if 0 < s and e < frames - 1 and (e - s + 1) <= MERGE_GAP \
                and sm[s:e + 1].max() < blip_cap:
            quiet[s:e + 1] = True

    idle = [r for r in runs(quiet) if r[1] - r[0] + 1 >= MIN_IDLE]
    # Talking = complement of idle, minus runs too short to loop on.
    talk_mask = np.ones(frames, dtype=bool)
    for s, e in idle:
        talk_mask[s:e + 1] = False
    talking = [r for r in runs(talk_mask) if r[1] - r[0] + 1 >= MIN_TALK]

    if not idle or not talking:
        sys.exit(f"degenerate classification (idle={idle}, talking={talking}) "
                 "— tune THRESH_FRAC/MIN_* for this bundle")

    fps = 25
    sidecar = {
        "version": 1,
        "fps": fps,
        "frames": frames,
        "metric": f"||xd[{LIP_UPPER}]-xd[{LIP_LOWER}]|| box{SMOOTH}, thr={thr:.4f}",
        "idle": idle,        # inclusive [start, end] frame ranges, mouth quiet
        "talking": talking,  # inclusive [start, end] frame ranges, mouth moving
    }
    out = Path(args.out) if args.out else bundle / "motion_ranges.json"
    out.write_text(json.dumps(sidecar, indent=1) + "\n")

    idle_f = sum(e - s + 1 for s, e in idle)
    talk_f = sum(e - s + 1 for s, e in talking)
    print(f"wrote {out}")
    print(f"  threshold {thr:.4f} (signal {lo:.4f}..{sm.max():.4f})")
    print(f"  idle    {idle}  = {idle_f} frames ({idle_f / fps:.1f}s)")
    print(f"  talking {talking}  = {talk_f} frames ({talk_f / fps:.1f}s)")


if __name__ == "__main__":
    main()
