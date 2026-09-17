// The ephemeral-token mint must be BOUNDED, and must NOT retry a slow server.
//
// THE OUTAGE THIS PINS (2026-09-17). `mintEphemeralToken` used a bare
// `http.post` with no timeout. Dart's `http.Client` waits INDEFINITELY, so a
// backend that was slow rather than down left the future pending forever and the
// UI sat at "Avatar ready — connecting …". Boundedness is the fix.
//
// ★ THE FIRST VERSION OF THIS FIX GOT THE RETRY POLICY BACKWARDS, and that is
//   the lesson worth keeping. It shipped 10 s x 3 attempts retrying 408/429/5xx,
//   sized against a HEALTHY server (resting p50 1.22 s, p90 1.62 s, max 3.15 s).
//   Measured against the SICK one it was meant for — the backend's Postgres pool
//   exhausted — a SUCCESSFUL mint took 20.9 / 27.2 / 33.7 / 35.7 s, and a single
//   request at concurrency ONE took 26.7 s. At those latencies 10 s x 3 cannot
//   succeed at all, and it sends three requests instead of one into a service
//   whose defect is that it collapses under load. The policy produced the exact
//   symptom it was written to prevent.
//
//   So the assertions below are mostly NEGATIVE: they pin what the client must
//   NOT do. A test suite that only proves "it retries" would have passed the
//   version that caused the harm.

import 'dart:async';
import 'dart:convert';

import 'package:bithuman/realtime_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A client whose per-call behaviour is scripted; records how many calls it saw.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.script);

  /// One entry per expected call:
  ///   int       -> return that status
  ///   'hang'    -> never complete (the client's own bound must fire)
  ///   Exception -> throw it (a transport failure)
  final List<Object> script;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (step == 'hang') return Completer<http.StreamedResponse>().future;
    if (step is Exception) throw step;
    final status = step as int;
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
    test('the happy path still returns the token', () async {
      final client = _ScriptedClient([200]);
      final svc = RealtimeService(client: client);

      final token = await svc.mintEphemeralToken('secret');

      expect(token.value, 'ek_ok');
      expect(client.calls, 1);
    });

    test('a hanging server is BOUNDED, not waited on forever', () async {
      // The original defect: this future never completed. The injected 100 ms
      // bound keeps the assertion honest and the suite fast; the production
      // default is asserted separately below.
      final client = _ScriptedClient(['hang']);
      final svc = RealtimeService(
        client: client,
        mintTimeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        svc.mintEphemeralToken('secret'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('the shipped default bound is 50 s, just past the edge proxy 45 s', () {
      // If someone shortens this to a "reasonable" 10 s, the client goes back to
      // failing every request during a backend slowdown. The number is load
      // bearing, so it is asserted.
      expect(RealtimeService.defaultMintTimeout, const Duration(seconds: 50));
    });

    test('CONTROL: a 503 is NOT retried — a slow server must not be amplified',
        () async {
      final client = _ScriptedClient([503, 200]);
      final svc = RealtimeService(client: client);

      await expectLater(
          svc.mintEphemeralToken('secret'), throwsA(isA<Exception>()));
      expect(client.calls, 1,
          reason: 'retrying 5xx is what turned one stuck client into three '
              'requests against an already-collapsing service');
    });

    test('CONTROL: a 408 is NOT retried', () async {
      final client = _ScriptedClient([408, 200]);
      final svc = RealtimeService(client: client);

      await expectLater(
          svc.mintEphemeralToken('secret'), throwsA(isA<Exception>()));
      expect(client.calls, 1);
    });

    test('CONTROL: a timeout is NOT retried', () async {
      final client = _ScriptedClient(['hang', 200]);
      final svc = RealtimeService(
        client: client,
        mintTimeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        svc.mintEphemeralToken('secret'),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.calls, 1,
          reason: 'a timeout means the server is slow; a second attempt only '
              'doubles the load on it');
    });

    test('a 401 is raised on the first attempt', () async {
      final client = _ScriptedClient([401, 200]);
      final svc = RealtimeService(client: client);

      await expectLater(
          svc.mintEphemeralToken('bad-secret'), throwsA(isA<Exception>()));
      expect(client.calls, 1);
    });

    test('a dropped socket IS retried once — it is not a load signal', () async {
      // The one case a retry genuinely fixes: a handover between cellular and
      // wi-fi kills the socket. A shedding server answers with a STATUS, so this
      // retry cannot amplify a server-side stall.
      final client = _ScriptedClient([const SocketishException(), 200]);
      final svc = RealtimeService(client: client);

      final token = await svc.mintEphemeralToken('secret');

      expect(token.value, 'ek_ok');
      expect(client.calls, 2);
    });

    test('a second dropped socket is surfaced, not retried again', () async {
      final client = _ScriptedClient(
          [const SocketishException(), const SocketishException(), 200]);
      final svc = RealtimeService(client: client);

      await expectLater(
          svc.mintEphemeralToken('secret'), throwsA(isA<Exception>()));
      expect(client.calls, 2, reason: 'exactly one transport retry, never a loop');
    });
  });
}

/// Stands in for a dropped-socket transport failure (`SocketException` lives in
/// `dart:io`, which a plugin test should not need to import).
class SocketishException implements Exception {
  const SocketishException();
  @override
  String toString() => 'SocketishException: connection closed';
}
