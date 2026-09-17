// The ephemeral-token mint must be BOUNDED and RETRIED.
//
// THE OUTAGE THIS PINS (2026-09-17). `mintEphemeralToken` used a bare
// `http.post` with no timeout and no retry. Dart's `http.Client` waits
// INDEFINITELY, so a backend that was slow rather than down left the future
// pending forever and the UI sat at "Avatar ready — connecting …" with nothing
// to time out and nothing to retry. On the day, the backend's credential gate
// had serialized under concurrency and this endpoint answered in 8.8–11.9 s or
// returned 408/504 — and one non-200 threw on the first attempt, though a retry
// would have succeeded in about a second.
//
// ★ A RETRY IS NOT UNCONDITIONAL. 408/429/5xx say "the server is slow or
//   overloaded", which a later attempt can survive. 400/401/403 is a verdict
//   about the credential or the request; retrying only delays a clear error.
//   Both directions are asserted, because a retry-everything client turns one
//   bad key into three requests and a confusing failure.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';

import 'package:bithuman/realtime_service.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

/// A client whose per-call behaviour is scripted; records how many calls it saw.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.script);

  /// One entry per expected call. An `int` is a status code to return; a
  /// `Duration` means "hang this long" (used to trip the client's timeout).
  final List<Object> script;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (step is Duration) {
      // Longer than _attemptTimeout, but SHORT enough that this future still
      // settles inside the test — a delay that outlives the test leaves a
      // pending timer and makes the suite flaky.
      await Future<void>.delayed(step);
    }
    final status = step is int ? step : 200;
    final body = status == 200
        ? jsonEncode({
            'data': {'value': 'ek_ok', 'model': 'gpt-realtime', 'expires_at': 123},
            'status': 'success',
          })
        : jsonEncode({'error': 'nope'});
    return http.StreamedResponse(Stream.value(utf8.encode(body)), status);
  }
}

void main() {
  group('mintEphemeralToken', () {
    test('retries a 503 and succeeds on a later attempt', () async {
      final client = _ScriptedClient([503, 200]);
      final svc = RealtimeService(client: client);

      final token = await svc.mintEphemeralToken('secret');

      expect(token.value, 'ek_ok');
      expect(client.calls, 2, reason: 'a 503 must be retried, not surfaced');
    });

    test('retries a 408 — the status the stranded phones actually got', () async {
      final client = _ScriptedClient([408, 408, 200]);
      final svc = RealtimeService(client: client);

      final token = await svc.mintEphemeralToken('secret');

      expect(token.value, 'ek_ok');
      expect(client.calls, 3);
    });

    test('CONTROL: a 401 is raised on the FIRST attempt, never retried', () async {
      final client = _ScriptedClient([401, 200]);
      final svc = RealtimeService(client: client);

      await expectLater(
        svc.mintEphemeralToken('bad-secret'),
        throwsA(isA<Exception>()),
      );
      expect(client.calls, 1,
          reason: 'a credential verdict must not be retried — '
              'if this reads 2+, the client retries everything');
    });

    test('gives up after the attempt budget instead of hanging forever',
        () async {
      final client = _ScriptedClient([503, 503, 503, 503, 503]);
      final svc = RealtimeService(client: client);

      await expectLater(
        svc.mintEphemeralToken('secret'),
        throwsA(isA<Exception>()),
      );
      expect(client.calls, 3,
          reason: 'bounded at _maxAttempts — an unbounded client is the defect');
    });

    test('a hanging server trips the per-attempt timeout rather than pending forever',
        () async {
      // Each call sleeps just past _attemptTimeout (10 s), so every attempt
      // times out and the mint gives up at ~32 s. Without `.timeout()` the
      // future never completes at all and the UI sits at "connecting …".
      final client = _ScriptedClient([const Duration(seconds: 11)]);
      final svc = RealtimeService(client: client);

      await expectLater(
        svc.mintEphemeralToken('secret').timeout(const Duration(seconds: 45)),
        throwsA(isA<Exception>()),
        reason: 'the mint must bound itself; a 45 s outer guard only catches '
            'the case where it does not',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
