// BithumanCredential: an API secret never moves; a session-token provider is asked for
// its current token, and once for a NEW one after a refusal. A provider that hangs,
// throws or answers blank counts as "no credential" and never raises.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';

import 'package:bithuman/bithuman.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an API secret is the credential, and it has no fresh one', () async {
    final c = BithumanCredential.apiSecret('  sk_secret  ');
    expect(c.rotates, isFalse);
    expect(await c.current(), 'sk_secret');
    expect(await c.fresh('sk_secret'), isNull, reason: 'a secret never moves: its 401 is final');
  });

  test('a provider is asked for its current token, then once with forceRefresh', () async {
    final asks = <bool>[];
    final c = BithumanCredential.provider(({required forceRefresh}) async {
      asks.add(forceRefresh);
      return forceRefresh ? 'tok-2' : 'tok-1';
    });
    expect(c.rotates, isTrue);
    expect(await c.current(), 'tok-1');
    expect(await c.fresh('tok-1'), 'tok-2');
    expect(asks, [false, true]);
  });

  test('a "fresh" token equal to the refused one is no fresh token', () async {
    final c = BithumanCredential.provider(({required forceRefresh}) async => 'tok-1');
    expect(await c.fresh('tok-1'), isNull);
  });

  test('blank, throwing and late providers count as none and never raise', () async {
    final blank = BithumanCredential.provider(({required forceRefresh}) async => '   ');
    expect(await blank.current(), isNull);

    final throwing = BithumanCredential.provider(
        ({required forceRefresh}) async => throw StateError('backend down'));
    expect(await throwing.current(), isNull);
    expect(await throwing.fresh('tok-1'), isNull);

    final late = BithumanCredential.provider(
        ({required forceRefresh}) => Completer<String?>().future,
        timeout: const Duration(milliseconds: 50));
    final sw = Stopwatch()..start();
    expect(await late.current(), isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: 'the wait is bounded');
  });
}
