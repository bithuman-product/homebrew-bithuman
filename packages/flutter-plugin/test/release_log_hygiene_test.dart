// A release build never prints what a person said (or what was said to them) into the device
// log. The transcript probes keep the text for debug and profile builds only; a release build
// logs its length. This reads the plugin's own sources: every print that carries a transcript
// or a transcript delta must decide on kReleaseMode in the same statement.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transcript prints are gated on kReleaseMode', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final offenders = <String>[];
    var seen = 0;
    for (final f in files) {
      final src = f.readAsStringSync();
      // A print statement, up to its closing `);` (prints here span at most a few lines).
      for (final m in RegExp(r"print\((.|\n)*?\);").allMatches(src)) {
        final stmt = m.group(0)!;
        final carriesWords = RegExp(r"transcript\b|\$delta|\$txt|\$\{t \?\?").hasMatch(stmt);
        if (!carriesWords) continue;
        seen++;
        if (!stmt.contains('kReleaseMode')) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('${f.path}:$line');
        }
      }
    }
    expect(seen, greaterThanOrEqualTo(3), reason: 'the transcript probes were not found at all');
    expect(offenders, isEmpty, reason: 'ungated transcript prints: ${offenders.join(', ')}');
  });
}
