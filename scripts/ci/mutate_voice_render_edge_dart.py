#!/usr/bin/env python3
"""Re-create, one at a time, the eight defects check_voice_render_edge_dart.sh exists to catch.

Used ONLY by the negative-control step of .github/workflows/plugin-platform-guards.yml,
which restores the files after each one. The partition is EXACT: one mutation per rule,
and the workflow refuses if a mutation reddens more rules than its own or fewer.

A check that cannot fail is decoration; a mutation that changes nothing is worse, because
it reports a partition it never drew — so every mutation here ASSERTS its target exists
and that the text actually changed.
"""
import sys, pathlib

L = pathlib.Path("packages/flutter-plugin/lib")
RT, RS = L / "realtime_transport.dart", L / "bithuman_realtime.dart"
AV, REG = L / "bithuman.dart", L / "src/transport_protocol.dart"

MUT = {
    # M1 → R1a: the import comes back. It compiles, it ships, and the module
    #           boundary is gone again; only this rule notices.
    "M1": [(RT, "import 'openai_webrtc_session.dart';",
                "import 'package:bithuman/bithuman.dart';\nimport 'openai_webrtc_session.dart';")],
    # M2 → R1b: one constructor is re-typed to the concrete render class.
    "M2": [(RT, "  WebRTCTransport({\n    required String apiKey,\n    required this.avatar,",
                "  WebRTCTransport({\n    required String apiKey,\n    required BithumanAvatar this.avatar,")],
    # M3 → R2a: the conformance declaration disappears, so nothing ties the
    #           protocol to the class that is supposed to satisfy it.
    "M3": [(AV, "class BithumanAvatar implements VoiceHost {",
                "class BithumanAvatar {")],
    # M4 → R2b: a member the protocol requires vanishes from the avatar, so the
    #           conformance would be vacuous.
    "M4": [(AV, "  Future<void> notifyTurnEnd() async {",
                "  Future<void> notifyTurnEndRENAMED() async {")],
    # M5 → R3: the voice module invokes a RENDER verb. The protocol is the
    #          measured surface; a call outside it is the dependency growing back
    #          through the hole the type no longer plugs.
    "M5": [(RS, "await avatar.notifyTurnEnd();", "await avatar.setIdleHold(true);")],
    # M6 → R4a: the routing rule stops reading the capability record and goes
    #           back to literals — the registry becomes decoration.
    "M6": [(RT, "      kLocalConverseTransport.runsOn(operatingSystem)) {",
                "      (operatingSystem == 'macos' || operatingSystem == 'ios')) {"),
           (RT, "      !named.requiresLocalBrain &&\n      named.runsOn(operatingSystem)) {",
                "      named.id != 'local') {")],
    # M7 → R4b: one transport hard-codes a capability instead of reading its row,
    #           so the instance and the registry can disagree.
    "M7": [(RT, "  bool get canMute => descriptor.canMute;\n  @override\n  TransportDescriptor get descriptor => kWebRtcTransport;",
                "  bool get canMute => true;\n  @override\n  TransportDescriptor get descriptor => kWebRtcTransport;")],
    # M8 → R4c: a registered id loses the branch that builds it — the row
    #           advertises a transport the factory silently falls back from.
    "M8": [(RT, "    case 'webrtc':", "    case 'webrtcX':")],
}

key = sys.argv[1]
for path, old, new in MUT[key]:
    src = path.read_text(encoding="utf-8")
    if old not in src:
        sys.exit("%s: its target is not in %s — the control would be a no-op, which is "
                 "not a control. Re-anchor it on the code that is actually there."
                 % (key, path))
    out = src.replace(old, new, 1)
    if out == src:
        sys.exit("%s: the mutation changed nothing." % key)
    path.write_text(out, encoding="utf-8")
    print("mutated %s: %s" % (path, key))
