// Channel parity (2.6.36): every method the Dart side calls on a platform channel is answered by BOTH
// native halves (Android: android/src/main/kotlin; iOS and macOS: shared/Classes and macos/Classes), or is
// listed below as unsupported on one of them, with the reason and how the Dart side copes.
//
// Until 2.6.36 nothing checked this: `pushAudio`, the call the docs taught for bring-your-own audio,
// had no Android branch and threw MissingPluginException there. This test reads the sources (no device,
// no engine): a new Dart call without a branch on each platform, or an entry below that has gone stale,
// fails it.
//
// Apache-2.0; (c) bitHuman.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Calls a platform does not answer, on purpose. Key: '<channel> <method>'.
const Map<String, Map<String, String>> unsupported = {
  'android': {
    // macOS window chrome (borderless window, floating bubble). Every Dart call is wrapped in a catch.
    'ai.bithuman.window configure': 'macOS window chrome only; the Dart call ignores the error',
    'ai.bithuman.window startDrag': 'macOS window chrome only; the Dart call ignores the error',
    'ai.bithuman.window enterBubble': 'macOS window chrome only; the Dart call ignores the error',
    'ai.bithuman.window exitBubble': 'macOS window chrome only; the Dart call ignores the error',
  },
  'apple': {
    // Load progress is an Android channel; iOS and macOS send no load events yet.
    'ai.bithuman.avatar/load cancel':
        'no load events on iOS / macOS; BithumanAvatar.cancelLoad answers false on MissingPluginException',
  },
};

/// Which source files carry each channel's Dart calls and each platform's handler.
class _Channel {
  const _Channel(this.dart, this.android, this.apple);
  final String Function() dart;
  final String Function() android;
  final String Function() apple;
}

String _read(String path) => File(path).readAsStringSync();

/// The part of [text] from [start] up to [end] (both must be present; read before any test runs, so a
/// missing marker is a StateError that fails the whole file).
String _slice(String text, String start, String end) {
  final a = text.indexOf(start);
  if (a < 0) throw StateError('marker not found: $start');
  final b = text.indexOf(end, a + start.length);
  if (b < 0) throw StateError('marker not found after "$start": $end');
  return text.substring(a, b);
}

final _bithumanDart = _read('lib/bithuman.dart');
const _loadEventsClass = 'class _LoadEvents {';

final Map<String, _Channel> _channels = {
  'ai.bithuman.avatar': _Channel(
    () => _bithumanDart.substring(0, _bithumanDart.indexOf(_loadEventsClass)),
    () => _slice(_read('android/src/main/kotlin/ai/bithuman/flutter/BithumanPlugin.kt'),
        'override fun onMethodCall(', 'private fun session('),
    () => _slice(_read('shared/Classes/BithumanAvatarPlugin.swift'),
        'public func handle(_ call: FlutterMethodCall', 'result(FlutterMethodNotImplemented)\n    }\n  }'),
  ),
  'ai.bithuman.avatar/load': _Channel(
    () => _bithumanDart.substring(_bithumanDart.indexOf(_loadEventsClass)),
    () => _slice(_read('android/src/main/kotlin/ai/bithuman/flutter/LoadEvents.kt'),
        'setMethodCallHandler', 'else -> result.notImplemented()'),
    () => '', // no handler on iOS / macOS
  ),
  'ai.bithuman.window': _Channel(
    () => _slice(_read('lib/ui_kit.dart'), "MethodChannel('ai.bithuman.window')", '\n}\n'),
    () => '', // no handler on Android
    () => _slice(_read('macos/Classes/WindowChrome.swift'), 'switch call.method {', 'default:'),
  ),
};

/// Dart → native calls: `invokeMethod('x'`, `invokeMethod<T>('x'`, `invokeMapMethod<K, V>(\n 'x'`.
Set<String> _dartCalls(String src) => RegExp(r"invoke(?:Map|List)?Method(?:<[^(]*>)?\(\s*'(\w+)'")
    .allMatches(src)
    .map((m) => m.group(1)!)
    .toSet();

/// Kotlin `when (call.method)` branches: `"a" ->`, `"a", "b" ->`, over one or more lines.
Set<String> _kotlinBranches(String src) => RegExp(r'^\s*((?:"\w+",\s*)*"\w+")\s*->', multiLine: true)
    .allMatches(src)
    .expand((m) => RegExp(r'"(\w+)"').allMatches(m.group(1)!).map((n) => n.group(1)!))
    .toSet();

/// Swift `switch call.method` cases: `case "a":`, `case "a", "b":`.
Set<String> _swiftCases(String src) => RegExp(r'^\s*case\s+((?:"\w+",\s*)*"\w+")\s*:', multiLine: true)
    .allMatches(src)
    .expand((m) => RegExp(r'"(\w+)"').allMatches(m.group(1)!).map((n) => n.group(1)!))
    .toSet();

void main() {
  final calls = {for (final e in _channels.entries) e.key: _dartCalls(e.value.dart())};
  final answered = {
    'android': {for (final e in _channels.entries) e.key: _kotlinBranches(e.value.android())},
    'apple': {for (final e in _channels.entries) e.key: _swiftCases(e.value.apple())},
  };

  test('the source slices are what this test thinks they are', () {
    // A refactor that moves a handler must move this test with it, not empty it.
    expect(calls['ai.bithuman.avatar'], containsAll(['load', 'playSpeakerPCM', 'pushAudio', 'dispose']));
    expect(calls['ai.bithuman.avatar/load'], {'cancel'});
    expect(calls['ai.bithuman.window'], isNotEmpty);
    expect(answered['android']!['ai.bithuman.avatar'], containsAll(['load', 'playSpeakerPCM', 'dispose']));
    expect(answered['apple']!['ai.bithuman.avatar'], containsAll(['load', 'playSpeakerPCM', 'dispose']));
    expect(answered['android']!['ai.bithuman.avatar/load'], {'cancel'});
    expect(answered['apple']!['ai.bithuman.window'], isNotEmpty);
  });

  for (final platform in ['android', 'apple']) {
    test('every Dart call is answered on $platform, or listed as unsupported there', () {
      final missing = <String>[];
      for (final channel in _channels.keys) {
        for (final method in calls[channel]!) {
          final key = '$channel $method';
          if (!answered[platform]![channel]!.contains(method) && !unsupported[platform]!.containsKey(key)) {
            missing.add(key);
          }
        }
      }
      expect(missing, isEmpty,
          reason: 'the Dart side calls these, and $platform has no handler branch for them. Add one '
              '(an explicit `unsupported` error is fine), or list the call in `unsupported` with the reason');
    });

    test('the $platform unsupported list is current', () {
      for (final key in unsupported[platform]!.keys) {
        final channel = key.substring(0, key.lastIndexOf(' '));
        final method = key.substring(key.lastIndexOf(' ') + 1);
        expect(_channels.containsKey(channel), isTrue, reason: '$key: unknown channel');
        expect(calls[channel], contains(method), reason: '$key: the Dart side no longer calls it; remove the entry');
        expect(answered[platform]![channel], isNot(contains(method)),
            reason: '$key: $platform answers it now; remove the entry');
      }
    });
  }

  test('pushAudio is answered on Android (the bring-your-own-audio call, 2.6.36)', () {
    expect(answered['android']!['ai.bithuman.avatar'], contains('pushAudio'));
    expect(answered['apple']!['ai.bithuman.avatar'], contains('pushAudio'));
  });
}
