// The echo table is ONE writer for server_vad + uplink gain, keyed by device class.
// The row invariants (a measured residual, a dated record, a zero-count falsifier over
// >= 180 s) are const asserts in EchoProfile's constructor — the COMPILER refuses a row
// that lacks them, which is the gate. This test grades what a compiler cannot: every
// device class has exactly one row, the rows are the ones the estate measured, and the
// mac row is the only one that turns AGC off (the iPhone's canceller never needed it).
import 'package:bithuman/src/echo_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every device class has exactly one row', () {
    final byDevice = {for (final p in EchoProfile.all) p.device: p};
    expect(byDevice.keys.toSet(), EchoDeviceClass.values.toSet());
    expect(EchoProfile.all.length, EchoDeviceClass.values.length);
  });

  test('each row carries its residual, date, and a clean falsifier', () {
    for (final p in EchoProfile.all) {
      expect(p.residualDbfsMax, lessThan(0), reason: '${p.device}: residual dBFS');
      expect(p.residualDbfsMedian, lessThanOrEqualTo(p.residualDbfsMax));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(p.measuredUtc), isTrue);
      expect(p.falsifierSelfInterruptions, 0, reason: '${p.device}: self-interruptions');
      expect(p.falsifierSeconds, greaterThanOrEqualTo(180), reason: '${p.device}: 3 x 60 s');
      expect(p.source, isNotEmpty);
    }
  });

  test('the threshold is per device: mac 0.7 with AGC off, phones 0.5', () {
    expect(EchoProfile.mac.serverVadThreshold, 0.7);
    expect(EchoProfile.mac.vpioAgc, isFalse);
    expect(EchoProfile.iphone.serverVadThreshold, 0.5);
    expect(EchoProfile.iphone.vpioAgc, isTrue);
    expect(EchoProfile.android.serverVadThreshold, 0.5);
  });
}
