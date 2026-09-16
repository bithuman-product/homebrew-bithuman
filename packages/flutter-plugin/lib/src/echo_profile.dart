import 'dart:io' show Platform;

/// ONE TABLE for echo: the server-VAD threshold and the uplink gain policy, per
/// DEVICE CLASS, each row carrying the measurement it was set from.
///
/// Before 2026-09-16 this was three constants in three files citing each other —
/// `server_vad 0.5` in the WebSocket session, `0.5` again in the WebRTC session,
/// `0.7` as a `Platform.isMacOS` ternary, and `isVoiceProcessingAGCEnabled = false`
/// under `#if os(macOS)` in Swift with the number that justified it in a comment.
/// The threshold is per DEVICE, not per platform: the iMac's canceller leaves
/// −46..−56 dBFS of the agent's own voice on the uplink and VP-IO's AGC re-amplifies
/// it into a self-interruption; the iPhone's leaves −70..−90 and never needed any of
/// it. So every row here states the residual it was measured against, when, and the
/// falsifier — self-interruptions over ≥ 3 × 60 s of the agent talking with nobody
/// in the room — and a row without those numbers does not compile: the `const`
/// asserts below are evaluated by the compiler for every `const` row.
///
/// `scripts/check_dev_levers.sh` also refuses any other numeric `'threshold':` in
/// `lib/`, so this table is the only writer.
enum EchoDeviceClass { iphone, android, mac }

class EchoProfile {
  const EchoProfile({
    required this.device,
    required this.serverVadThreshold,
    required this.vpioAgc,
    required this.residualDbfsMax,
    required this.residualDbfsMedian,
    required this.measuredOn,
    required this.measuredUtc,
    required this.falsifierSelfInterruptions,
    required this.falsifierSeconds,
    required this.falsifierTurns,
    required this.source,
  })  : assert(serverVadThreshold > 0.0 && serverVadThreshold < 1.0,
            'server_vad threshold is a fraction'),
        assert(residualDbfsMax < 0 && residualDbfsMax > -91,
            'a row without a measured residual (dBFS, worst 1 s) is refused'),
        assert(residualDbfsMedian <= residualDbfsMax,
            'the median residual cannot exceed the worst second'),
        assert(measuredUtc.length == 10, 'measuredUtc is YYYY-MM-DD'),
        assert(falsifierSelfInterruptions == 0,
            'the falsifier is ZERO self-interruptions at this threshold'),
        assert(falsifierSeconds >= 180,
            'the falsifier is at least 3 x 60 s of the agent talking, nobody in the room');

  final EchoDeviceClass device;

  /// OpenAI `turn_detection.server_vad.threshold` (0..1) sent by BOTH transports.
  ///
  /// ★ RETRACTED, SAME DAY, BY ITS OWN CONFIRMATION ARM. This comment claimed for a
  /// few hours that the threshold moves the interrupt LATENCY and not only the
  /// sensitivity, from a 3-point sweep at n = 4 per arm that read 139 / 192 / 261 ms
  /// for 0.3 / 0.5 / 0.7. Re-run at n = 8 on the arm that actually matters — 0.5 vs
  /// 0.7, the choice this row faces — there is NO effect:
  ///
  ///     threshold   onset -> speech_started   fired   per-trial (ms)
  ///        0.5           152.2 ms median       8/8    146.5 148.4 149.4 151.8
  ///                                                   152.5 246.2 254.0 3393.1
  ///        0.7           146.6 ms median       8/8    143.3 144.5 145.4 146.3
  ///                                                   146.8 149.1 241.4 242.7
  ///
  /// 5.6 ms apart, and the WRONG WAY. Both arms are the same bimodal mixture — a tight
  /// cluster near 147 ms and a second near 245 ms — so the n = 4 "monotone" reading was
  /// that mixture being sampled differently by chance, nothing more. The back-dating
  /// bias, which had looked like an independent control when it moved -256/-232/-216
  /// at n = 4, reads -244 vs -240 here: it was sampling noise too. Even the one huge
  /// outlier is not a threshold property — 2587 ms at 0.7 in the first run, 3393 ms at
  /// 0.5 in this one.
  ///
  /// So homebrew-bithuman #58 was RIGHT: "threshold tuning cannot touch it; it moves
  /// the sensitivity, not the latency", for the 0.5/0.7 decision. 0.3 is still untested
  /// at n = 8 and is the only part that stayed suggestive (4 trials, 138.4-139.1, no
  /// bimodality at all) — untested is not a finding, and nothing should be spent on it
  /// until someone runs it.
  ///
  /// ★ WHAT THE EPISODE IS WORTH KEEPING FOR: a 4-sample median of a BIMODAL
  /// distribution is not a measurement, and it read as a clean monotone result across
  /// three arms with a control that appeared to agree. The confirmation arm was already
  /// running when the claim was merged. Run it first.
  ///
  /// The mac row's trade is therefore two-sided as it always was — 0.7 buys quiet and
  /// costs barge-in sensitivity — and `0.5 + AGC off` in an empty room is still the
  /// missing cell, on the sensitivity question alone.
  final double serverVadThreshold;

  /// Apple VP-IO automatic gain on the uplink. `false` ⇒ the plugin sends what the
  /// canceller produced, unamplified. Android has no such control (its canceller is
  /// the platform's communication path); the value is ignored there.
  final bool vpioAgc;

  /// Uplink residual while the agent talks (post-canceller, as sent to the server):
  /// the WORST 1 s RMS in dBFS, and the median, at the config in this row.
  final int residualDbfsMax;
  final int residualDbfsMedian;

  /// What it was measured on, and the date (UTC) of the record.
  final String measuredOn;
  final String measuredUtc;

  /// The falsifier at this row's config: `speech_started` events the server reported
  /// while the agent was audible and nobody spoke, over [falsifierSeconds] of agent
  /// speech across [falsifierTurns] monologues.
  final int falsifierSelfInterruptions;
  final int falsifierSeconds;
  final int falsifierTurns;

  /// Where the log lives (a PR, a path on echelon, or both).
  final String source;

  /// The row for the device this build runs on.
  static EchoProfile get current {
    if (Platform.isMacOS) return mac;
    if (Platform.isAndroid) return android;
    return iphone;
  }

  static const iphone = EchoProfile(
    device: EchoDeviceClass.iphone,
    serverVadThreshold: 0.5,
    vpioAgc: true,
    residualDbfsMax: -31,
    residualDbfsMedian: -71,
    measuredOn: 'iPhone 15, built-in speaker, expression-2, VP-IO on, AGC default',
    measuredUtc: '2026-09-16',
    falsifierSelfInterruptions: 0,
    falsifierSeconds: 410,
    falsifierTurns: 21,
    source: 'homebrew-bithuman #47 (04:58Z comment): "VP-IO cancels a -18 dBFS far end '
        'to -70…-90 dBFS steady uplink; only the onset transient before it converges '
        'reaches -35 dBFS, and even that never tripped server_vad over 410 s"; log '
        'conv_contract/run_afterfix.log (04:45-04:52Z)',
  );

  static const android = EchoProfile(
    device: EchoDeviceClass.android,
    serverVadThreshold: 0.5,
    vpioAgc: false, // n/a: MODE_IN_COMMUNICATION + the platform AEC (MicCapture.kt)
    residualDbfsMax: -31,
    residualDbfsMedian: -90,
    measuredOn: 'Galaxy S25+, speaker 11/15, essence-2; pure-echo seconds read exact '
        'digital zero (333/401 s at the -90.3 dBFS floor), the rest <= -31 dBFS peak',
    measuredUtc: '2026-09-16',
    falsifierSelfInterruptions: 0,
    falsifierSeconds: 217,
    falsifierTurns: 10,
    source: 'homebrew-bithuman #49 clause-11 record, e2and conversation_android.normalized.log '
        '(08:43:46-08:50:27Z): 0 over the last 217 s; the first 88 s are VOID (another '
        'lane audible on the shared desk) and are not counted. #44 (03:45-03:59Z): '
        'uplink during pure echo reads exact digital zero, 0 of 21 cut-ins carried the '
        "agent's words; no clean 3 x 60 s arm that night (the owner was using the phone)",
  );

  static const mac = EchoProfile(
    device: EchoDeviceClass.mac,
    serverVadThreshold: 0.7,
    vpioAgc: false,
    residualDbfsMax: -54,
    residualDbfsMedian: -70,
    measuredOn: 'iMac M4 (echelon), macOS 26.6.2, built-in speakers at 40 %, expression-2 '
        'and essence-2, VP-IO on, AGC OFF',
    measuredUtc: '2026-09-16',
    falsifierSelfInterruptions: 0,
    falsifierSeconds: 354,
    falsifierTurns: 35,
    source: 'homebrew-bithuman #51: "echo self-interruptions, nobody in the room: 3 / 357 s, '
        '3 / 370 s (server_vad 0.5) -> 0 / 354 s (macOS: VP-IO AGC off + 0.7)"; residual max '
        '-46 -> -54 dBFS; logs macos_lane/logs/mac_run_e2final1.log (07:57-08:04Z) and '
        'mac_run_ssfinal1.log (0 / 356 s, 41 turns). Sweep: 0.5 -> 6/727 s, 0.7 alone -> '
        '2/960 s, 0.7 + AGC off -> 0/710 s',
  );

  static const List<EchoProfile> all = [iphone, android, mac];
}
