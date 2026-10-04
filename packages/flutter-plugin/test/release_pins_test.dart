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
// Every pin is checked always (round 3: both AARs are published and pinned on main, so the Android check no
// longer waits for the pubspec bump, and a tag cut on a commit still at 2.6.35 cannot skip it). A pre-release
// (`0.9.4-cand1`, `v2.20.3-rc1`) is never at a floor: a release pins final versions only. Reads the sources
// only. Apache-2.0; (c) bitHuman.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _version = RegExp(r'(\d+)\.(\d+)\.(\d+)([-+][0-9A-Za-z.+-]*)?$');

/// "0.9.4", "v2.20.3", "essence2-v1.15.4" -> [0, 9, 4] / [2, 20, 3] / [1, 15, 4] (the version at the END of the
/// string; a tag's prefix is not part of it).
List<int> _ver(String s) {
  final m = _version.firstMatch(s);
  if (m == null) throw StateError('not a version: $s');
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// A pre-release or build suffix (`-cand1`, `-rc.1`, `+local`): not a final release.
bool _preRelease(String s) => (_version.firstMatch(s)?.group(4) ?? '').isNotEmpty;

/// [have] is a FINAL release at or above [floor]. A pre-release is below every floor (even `0.9.5-rc1` against
/// `0.9.4`): a tag never ships a candidate engine.
bool _atLeast(String have, String floor) {
  if (_preRelease(have)) return false;
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

  // The pubspec version is the release being cut: named in the failure messages below.

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
          reason: 'ai.bithuman:$artifact:${aar(artifact)} hands a cached private avatar to another account (or is '
              'a pre-release); pin $floor or a later final release before tagging $version');
    }
  });

  test('the checker reads what it checks', () {
    expect(_atLeast('0.9.4', '0.9.4'), isTrue);
    expect(_atLeast('0.10.0', '0.9.4'), isTrue);
    expect(_atLeast('0.9.3', '0.9.4'), isFalse);
    expect(_atLeast('essence2-v1.15.3', 'essence2-v1.15.4'), isFalse);
    expect(_atLeast('v2.21.0', 'v2.20.3'), isTrue);
    // Pre-releases (round 3): `_ver` read `0.9.4-cand1` as 0.9.4.
    expect(_atLeast('0.9.4-cand1', '0.9.4'), isFalse);
    expect(_atLeast('0.9.5-rc1', '0.9.4'), isFalse);
    expect(_atLeast('essence2-v1.15.4-rc.2', 'essence2-v1.15.4'), isFalse);
    expect(_atLeast('0.6.0+local', '0.6.0'), isFalse);
    expect(_atLeast('essence2-v1.15.4', 'essence2-v1.15.4'), isTrue, reason: 'a tag\'s prefix is not a pre-release');
    expect(_ver('essence2-v1.15.4'), [1, 15, 4]);
    expect(_ver(aar('essence2-android')), hasLength(3));
    expect(_ver(aar('expression2-android')), hasLength(3));
  });
}
