#!/usr/bin/env python3
"""Re-create, one at a time, the four defects check_voice_render_edge.sh exists to catch.

Used ONLY by the negative-control step of .github/workflows/plugin-platform-guards.yml,
which restores the files after each one. A check that cannot fail is decoration; a
mutation that changes nothing is worse, because it reports a partition it never drew —
so every mutation here ASSERTS its target exists and that the text actually changed.
"""
import sys, pathlib

C = pathlib.Path("packages/flutter-plugin/shared/Classes")
AUDIO, PLUGIN = C / "RealtimeAudioIO.swift", C / "BithumanAvatarPlugin.swift"

MUT = {
    # M1 → R1a + R1b: the voice unit names the concrete render class again.
    "M1": (AUDIO,
           "  weak var lipsyncSink: LipsyncSink?",
           "  weak var lipsyncSink: AvatarTexture?"),
    # M2 → R2 audioStart: the cut guard clause, put back exactly as it was.
    "M2": (PLUGIN,
           '            let textureId = args["textureId"] as? Int64 else {\n'
           '        result(FlutterError(code: "BAD_ARGS",\n'
           '                            message: "audioStart requires textureId",',
           '            let textureId = args["textureId"] as? Int64,\n'
           '            let texture = textures[textureId] else {\n'
           '        result(FlutterError(code: "BAD_ARGS",\n'
           '                            message: "audioStart requires textureId",'),
    # M3 → R3a: the conformance declaration disappears.
    "M3": (PLUGIN,
           "final class AvatarTexture: NSObject, FlutterTexture, LipsyncSink {",
           "final class AvatarTexture: NSObject, FlutterTexture {"),
    # M4 → R3b: a member the protocol requires vanishes from the texture, so the
    #           conformance would be vacuous.
    "M4": (PLUGIN,
           "  func onTurnEnd() {",
           "  func onTurnEndRENAMED() {"),
}

key = sys.argv[1]
path, old, new = MUT[key]
src = path.read_text(encoding="utf-8")
if old not in src:
    sys.exit("%s: its target is not in %s — the control would be a no-op, which is "
             "not a control. Re-anchor it on the code that is actually there." % (key, path))
out = src.replace(old, new, 1)
if out == src:
    sys.exit("%s: the mutation changed nothing." % key)
path.write_text(out, encoding="utf-8")
print("mutated %s: %s" % (path, key))
