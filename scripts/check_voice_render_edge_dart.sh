#!/bin/bash
# check_voice_render_edge_dart.sh — THE DART VOICE MODULE MAY NOT IMPORT THE DART
# RENDER MODULE, AND THE PROTOCOL BETWEEN THEM MUST STAY THE MEASURED SURFACE.
#
# ★WHY. This is the twin of check_voice_render_edge.sh one layer up. The Swift
# voice unit stopped naming `AvatarTexture` on 2026-09-16; the Dart voice module
# was still opening with `import 'bithuman.dart'` and typing four constructors
# `required BithumanAvatar avatar`. Same defect, same shape, same cost: "a voice
# session with no avatar" was not a thing the type system could say, so the only
# way to test voice was through the render class, and every unification of the
# voice layer had to drag render along.
#
# The edge is TURNED rather than cut — `BithumanAvatar implements VoiceHost`, so
# the arrow runs render → voice. Nothing about that is visible at runtime: put
# the import back and the package still compiles and still ships. This is what
# notices.
#
# ★AND WHY A SOURCE CHECK BESIDE A COMPILED ONE. The compiled arm is
# test/e2e/headless_voice_host_test.dart, where a real BithumanRealtimeSession
# runs against a VoiceHost that has no render in it at all — re-type one
# constructor and that file stops compiling. This script grades the two things a
# compile cannot: that the IMPORT is gone (a file can import render and never use
# it), and that the protocol still names every member the voice module actually
# invokes (a protocol that has drifted wider than its callers is decoration).
set -uo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$PWD" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
L = root / "packages/flutter-plugin/lib"
VOICE = {
    "bithuman_realtime.dart": (L / "bithuman_realtime.dart").read_text(encoding="utf-8"),
    "realtime_transport.dart": (L / "realtime_transport.dart").read_text(encoding="utf-8"),
}
render = (L / "bithuman.dart").read_text(encoding="utf-8")
proto  = (L / "src/voice_host.dart").read_text(encoding="utf-8")
reg    = (L / "src/transport_protocol.dart").read_text(encoding="utf-8")
fails, graded = [], 0

def rule(name, ok, msg):
    global graded
    graded += 1
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else " — " + msg))
    if not ok: fails.append(name)

def code(src):
    """Source with whole-line comments dropped. Prose may name the render class —
    naming it is how a reader learns who conforms — but an expression may not."""
    return "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("//"))

# ── R1: voice does not import render, and does not name the render class ──────
bad = [f for f, s in VOICE.items()
       if re.search(r"^import\s+'(?:package:bithuman/)?bithuman\.dart';", s, re.M)]
rule("R1a the voice files do not import the render library", not bad,
     "bithuman.dart is imported by: " + ", ".join(bad))
bad = [f for f, s in VOICE.items() if "BithumanAvatar" in code(s)]
rule("R1b the voice files name no render class in code", not bad,
     "BithumanAvatar appears in: " + ", ".join(bad))

# ── R2: the conformance is real, not decorative ───────────────────────────────
rule("R2a BithumanAvatar declares the conformance",
     re.search(r"^class BithumanAvatar implements VoiceHost \{", render, re.M) is not None,
     "bithuman.dart must declare 'class BithumanAvatar implements VoiceHost'")
members = re.findall(r"^  (?:Future<void>|Stream<[^>]*(?:>)?>)\s+(?:get\s+)?(\w+)", proto, re.M)
missing = [m for m in members
           if not re.search(r"\b(?:get\s+)?%s\s*[({]" % re.escape(m), render)]
rule("R2b every one of the %d protocol members exists on the avatar" % len(members),
     len(members) >= 14 and not missing,
     "declared in the protocol but absent from bithuman.dart: "
     + ", ".join(missing or ["<the protocol has too few members to be the real surface>"]))

# ── R3: the protocol IS the measured surface — no member the voice files call
#        may be missing from it, and none of them may be a render verb ─────────
called = set()
for s in VOICE.values():
    called |= set(re.findall(r"\bavatar\.(\w+)", code(s)))
unnamed = sorted(called - set(members))
rule("R3 every member the voice files invoke is in the protocol", not unnamed,
     "invoked on the host but not declared in VoiceHost: " + ", ".join(unnamed)
     + " — either it is a voice verb and belongs in src/voice_host.dart, or it is "
       "a RENDER verb and the voice module has grown the dependency back")

# ── R4: the transport registry is read, not decoration ────────────────────────
t = VOICE["realtime_transport.dart"]
rule("R4a the routing rule reads the capability record",
     ("requiresLocalBrain" in code(t)) and ("runsOn(" in code(t)),
     "pickTransportDescriptor must decide from the descriptor's fields, not from literals")
n = len(re.findall(r"bool get canMute => descriptor\.canMute;", t))
rule("R4b every transport's canMute IS its registry row (%d/3)" % n, n == 3,
     "a transport hard-codes canMute instead of reading its descriptor")
ids = re.findall(r"^  id: '(\w+)'", reg, re.M)
cases = set(re.findall(r"^    case '(\w+)':", t, re.M))
missing = [i for i in ids if i not in cases and i != "websocket"]
rule("R4c every registered transport id has a branch in the factory", not missing,
     "registered with no way to build it: " + ", ".join(missing))

print("dart voice/render edge: %d rules graded, %d failed" % (graded, len(fails)))
sys.exit(1 if fails else 0)
PY
