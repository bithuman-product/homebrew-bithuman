#!/bin/bash
# check_voice_render_edge.sh — THE VOICE UNIT MAY NOT NAME THE RENDER CLASS,
# AND THE TWO VOICE ENTRY POINTS MAY NOT REQUIRE A TEXTURE.
#
# ★WHY. `RealtimeAudioIO` is the Apple voice unit: one AVAudioEngine that owns the
# mic, the speaker and VP-IO echo cancellation. It needs eleven things from the
# render side and nothing else, and every one of its references to them was already
# `?.`-guarded — `playSpeakerPCM24k` has carried a no-avatar branch ("cloud/no-avatar
# path") for as long as it has existed. That branch was nevertheless UNREACHABLE,
# for two reasons and only two:
#   1. the sink was declared as the concrete `AvatarTexture`, so "a voice session
#      with no avatar" was not a thing the type system could say; and
#   2. `audioStart` and `localAudioStart` BOUND `textures[textureId]` in their guard
#      and refused BAD_ARGS without one, so no caller could ever construct the audio
#      unit with a nil sink.
# Both are cut. This check is what stops them growing back, because the code will
# keep compiling and shipping when they do — an unreachable branch is silent.
#
# ★AND WHY A SOURCE CHECK AND NOT A BUILD. Nothing in this repository's CI compiles
# packages/flutter-plugin's Swift at all (measured 2026-09-16: swift-package.yml
# builds a DIFFERENT package; prove_dev_levers_release.sh compiles ONE file). The
# only compiled arm on this boundary is prove_lipsync_sink_headless.sh, which builds
# the protocol plus a non-render conformer. Everything else here is read, not built,
# and says so.
set -uo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$PWD" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
C = root / "packages/flutter-plugin/shared/Classes"
audio  = (C / "RealtimeAudioIO.swift").read_text(encoding="utf-8")
plugin = (C / "BithumanAvatarPlugin.swift").read_text(encoding="utf-8")
brain  = (C / "LocalConverseController.swift").read_text(encoding="utf-8")
proto  = (C / "Protocol/LipsyncSink.swift").read_text(encoding="utf-8")
fails, graded = [], 0
def rule(name, ok, msg):
    global graded
    graded += 1
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else " — " + msg))
    if not ok: fails.append(name)

# ── R1: the voice unit holds a PROTOCOL, and names no render class ────────────
bad = [f for f, s in (("RealtimeAudioIO.swift", audio),
                      ("LocalConverseController.swift", brain)) if "AvatarTexture" in s]
rule("R1a the voice sources name no render class", not bad,
     "AvatarTexture appears in: " + ", ".join(bad))
rule("R1b the sink is declared as the protocol", 
     re.search(r"^\s*weak var lipsyncSink: LipsyncSink\?\s*$", audio, re.M) is not None,
     "RealtimeAudioIO must declare exactly 'weak var lipsyncSink: LipsyncSink?'")

# ── R2: neither voice entry point requires a texture in its guard ─────────────
def first_guard(verb):
    i = plugin.index('case "%s":' % verb)
    j = plugin.index("guard ", i)
    return plugin[j:plugin.index(" else {", j)]
for verb in ("audioStart", "localAudioStart"):
    g = first_guard(verb)
    rule("R2 %s does not require a texture" % verb, "textures[" not in g,
         "its guard binds textures[...] again — the headless voice path is unreachable")

# ── R3: the conformance is real, not decorative ───────────────────────────────
members = re.findall(r"^  (?:var|func) (\w+)", proto, re.M)
rule("R3a AvatarTexture declares the conformance",
     re.search(r"^final class AvatarTexture:.*\bLipsyncSink\b", plugin, re.M) is not None,
     "AvatarTexture must conform to LipsyncSink")
missing = [m for m in members
           if not re.search(r"\b(?:var|func|let)\s+%s\b" % re.escape(m), plugin)]
rule("R3b every one of the %d protocol members exists on the texture" % len(members),
     len(members) >= 12 and not missing,
     "declared in the protocol but absent from the plugin: " + ", ".join(missing or ["<protocol has too few members to be the real surface>"]))

# ── R4: the DART voice layer does not import the DART render layer ───────────
# The Swift rules above hold the native half of this boundary. The Dart half was
# open until 2026-09-16: `bithuman_realtime.dart` and `realtime_transport.dart`
# imported `package:bithuman/bithuman.dart` for exactly one reason — four
# constructors took `required BithumanAvatar avatar` — so "test the conversation"
# meant "build an avatar first". The port (`lib/src/voice_protocol.dart`) turned
# that edge around. These rules are what stop it growing back, and unlike the
# Swift rules they ARE also compiled: `flutter test` builds every one of these
# libraries on the ubuntu runner in *flutter plugin tests*.
L = root / "packages/flutter-plugin/lib"
VOICE = ("bithuman_realtime.dart", "realtime_transport.dart",
         "openai_webrtc_session.dart", "src/voice_protocol.dart")

def render_imports(text):
    out = []
    for line in text.splitlines():
        t = line.strip()
        if not (t.startswith("import ") or t.startswith("export ")):
            continue  # a COMMENT naming the file is not an edge
        if "'package:bithuman/bithuman.dart'" in t or "'bithuman.dart'" in t:
            out.append(t)
    return out

offenders = []
for name in VOICE:
    offenders += ["%s: %s" % (name, i) for i in render_imports((L / name).read_text(encoding="utf-8"))]
rule("R4a the dart voice layer imports no render library", not offenders,
     "; ".join(offenders))

avatar_src = (L / "bithuman.dart").read_text(encoding="utf-8")
rule("R4b the render class serves the voice port",
     re.search(r"^class BithumanAvatar implements VoiceAudioPort \{", avatar_src, re.M) is not None,
     "bithuman.dart must declare 'class BithumanAvatar implements VoiceAudioPort {' — "
     "without it the edge is merely absent, and every caller passing an avatar breaks")

# Every place the voice layer names the thing it drives must name the PORT. Five
# sites: three transport constructors, pickTransport, and the session field.
# ★COUNT CODE, NOT PROSE. The first draft of this rule counted the whole file and
# went red on its own explanatory comment ("the four constructors took
# `required BithumanAvatar avatar`"), which is a header, not an edge. A guard that
# grades documentation is the defect this boundary already has a history of.
def code_lines(name):
    out = []
    for line in (L / name).read_text(encoding="utf-8").splitlines():
        t = line.strip()
        if t.startswith("//") or t.startswith("///"):
            continue
        out.append(line)
    return "\n".join(out)

DECL = ("realtime_transport.dart", "bithuman_realtime.dart")
ports = sum(code_lines(n).count("VoiceAudioPort avatar") for n in DECL)
stale = sum(code_lines(n).count("BithumanAvatar avatar") for n in DECL)
rule("R4c all 5 voice-side avatar declarations are the port, none the render class",
     ports == 5 and stale == 0,
     "found %d port declarations (want 5) and %d render-class declarations (want 0)" % (ports, stale))

print("voice/render edge: %d rules graded, %d failed" % (graded, len(fails)))
sys.exit(1 if fails else 0)
PY
