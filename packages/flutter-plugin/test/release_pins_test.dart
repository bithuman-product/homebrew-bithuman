// The engine pins a release of this plugin must carry (2.6.36, security; PR #202 review).
//
// The plugin's own gate (lib/src/door_gate.dart, android EntitlementWindow.kt) is one half of the
// cross-account fix; the engines' stores and the Apple engine floor are the other. A tag must never ship
// the plugin's half on engines that still hand a cached PRIVATE avatar to another account, or with an
// Apple engine built above the pod's floor:
//
//   * essence2-android   >= 0.9.4   (bithuman-models #1827: a cache hit needs the credential's mark)
//   * expression2-android >= 0.6.0  (#1820 + #1828: the same for Expression 2)
//   * libessence2         >= essence2-v1.15.4 (#1826 + #1833: built at iOS 16 / macOS 13, refuses below 26)
//   * Expression2 / UnifiedModelHeader >= v2.20.3 (#1829 via #1830: Expression2Download per credential)
//
// The Apple pins are checked always. The Android pins are checked from the version that ships the gate
// (pubspec 2.6.36) on: until the AARs are on maven.bithuman.ai the branch carries 0.9.3 / 0.5.2, and the
// commit that bumps pubspec to 2.6.36 cannot pass this suite without them. Reads the sources only.
// Apache-2.0; (c) bitHuman.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "0.9.4", "v2.20.3", "essence2-v1.15.4" -> [0, 9, 4] / [2, 20, 3] / [1, 15, 4].
List<int> _ver(String s) {
  final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(s);
  if (m == null) throw StateError('not a version: $s');
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

bool _atLeast(String have, String floor) {
  final a = _ver(have), b = _ver(floor);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return true;
}

String _one(String text, RegExp re, String what) {
  final all = re.allMatches(text).map((m) => m.group(1)!).toSet();
  if (all.length != 1) throw StateError('expected exactly one $what, found $all');
  return all.single;
}

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final gradle = File('android/build.gradle').readAsStringSync();
  final boot = File('scripts/bootstrap.sh').readAsStringSync();

  final version = _one(pubspec, RegExp(r'^version:\s*(\S+)', multiLine: true), 'pubspec version');
  // Only the `NAME="${NAME:-VALUE}"` form is a pin (check-apple-engine-pin.sh reads the same).
  String pin(String name) => _one(boot, RegExp('^$name="\\\$\\{$name:-([^}]*)\\}"', multiLine: true), name);
  String aar(String artifact) =>
      _one(gradle, RegExp("^\\s*implementation 'ai\\.bithuman:$artifact:([^']+)'", multiLine: true), artifact);

  final gated = _atLeast(version, '2.6.36');

  test('Apple: libessence2 is built at the pod\'s floor and Expression 2 opens a cache per credential', () {
    for (final (name, floor) in [
      ('LIBESSENCE2_RELEASE', 'essence2-v1.15.4'),
      ('LIBESSENCE2_RESOURCES_RELEASE', 'essence2-v1.15.4'),
      ('EXPRESSION2_RELEASE', 'v2.20.3'),
      ('UMH_RELEASE', 'v2.20.3'),
    ]) {
      expect(_atLeast(pin(name), floor), isTrue, reason: '$name ${pin(name)} is below $floor');
    }
  });

  test('Android: the engine stores gate a cached avatar per credential (required from 2.6.36)', () {
    for (final (artifact, floor) in [('essence2-android', '0.9.4'), ('expression2-android', '0.6.0')]) {
      expect(_atLeast(aar(artifact), floor), isTrue,
          reason: 'ai.bithuman:$artifact:${aar(artifact)} hands a cached private avatar to another account; '
              'pin $floor or later before tagging $version');
    }
  },
      skip: gated
          ? false
          : 'pubspec $version: checked from 2.6.36 on (today essence2-android ${aar('essence2-android')}, '
              'expression2-android ${aar('expression2-android')})');

  test('the checker reads what it checks', () {
    expect(_atLeast('0.9.4', '0.9.4'), isTrue);
    expect(_atLeast('0.10.0', '0.9.4'), isTrue);
    expect(_atLeast('0.9.3', '0.9.4'), isFalse);
    expect(_atLeast('essence2-v1.15.3', 'essence2-v1.15.4'), isFalse);
    expect(_atLeast('v2.21.0', 'v2.20.3'), isTrue);
    expect(_ver(aar('essence2-android')), hasLength(3));
    expect(_ver(aar('expression2-android')), hasLength(3));
  });
}
