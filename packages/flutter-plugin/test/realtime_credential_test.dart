// A realtime session on a short-lived session token: a refusal the token may cause gets
// ONE fresh token from the app's provider, and the session dials again with it. An API
// secret's refusal is final, as it always was, and so is an account's answer (402).
//
// The REAL WebSocket client dials a REAL loopback relay stand-in that refuses or accepts
// each dial per a script and records the Authorization header it was dialed with. The
// voice host is a recording double. No network beyond loopback, no secrets.
//
// Apache-2.0; (c) bitHuman.

import 'dart:convert';
import 'dart:io';

import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e/recording_voice_host.dart';

/// One scripted answer per dial: an int refuses the handshake with that HTTP status;
/// 'accept' upgrades and sends `session.created`; 'accept-then-forbid' also ends the
/// session the way the relay does when its billing beat is refused (an `error` event
/// FORBIDDEN, then close 1008 FORBIDDEN).
class _Relay {
  _Relay(this.script);
  final List<Object> script;
  final List<String?> bearers = [];
  final List<WebSocket> _sockets = [];
  late HttpServer _server;

  String get url => 'ws://127.0.0.1:${_server.port}/v1/realtime';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final i = bearers.length;
      bearers.add(req.headers.value('authorization'));
      final step = script[i < script.length ? i : script.length - 1];
      if (step is int) {
        req.response.statusCode = step;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'error': {'code': 'REFUSED_$step', 'message': 'the bitHuman session could not start'}
        }));
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _sockets.add(ws);
      ws.listen((_) {}, onError: (_) {});
      ws.add(jsonEncode({'type': 'session.created'}));
      if (step == 'accept-then-forbid') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        ws.add(jsonEncode({
          'type': 'error',
          'error': {'type': 'bithuman_relay', 'code': 'FORBIDDEN', 'message': 'This session was stopped by bitHuman.'}
        }));
        await ws.close(1008, 'FORBIDDEN');
      }
    });
  }

  Future<void> close() async {
    for (final s in _sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

Future<void> _until(bool Function() ok, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $within');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Relay relay;
  late RecordingVoiceHost host;
  BithumanRealtimeSession? session;
  late List<bool> asks;

  BithumanCredential provider(String Function(bool forceRefresh, int n) answer) {
    return BithumanCredential.provider(({required forceRefresh}) async {
      asks.add(forceRefresh);
      return answer(forceRefresh, asks.where((a) => a).length);
    });
  }

  Future<BithumanRealtimeSession> open({String apiKey = '', BithumanCredential? credential}) async {
    BithumanRealtimeSession.debugEndpointOverride = relay.url;
    final s = BithumanRealtimeSession(
        apiKey: apiKey, credential: credential, avatar: host, model: 'gpt-realtime', vadThreshold: 0);
    session = s;
    await s.start(enableMic: false);
    return s;
  }

  setUp(() {
    host = RecordingVoiceHost();
    asks = [];
  });

  tearDown(() async {
    try {
      await session?.stop();
    } catch (_) {}
    session = null;
    BithumanRealtimeSession.debugEndpointOverride = null;
    await relay.close();
    await host.close();
  });

  test('an expired token (401 at the handshake) is replaced once and the session opens', () async {
    relay = _Relay([401, 'accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => f ? 'tok-2' : 'tok-1'));
    await _until(() => relay.bearers.length == 2);
    expect(relay.bearers, ['Bearer tok-1', 'Bearer tok-2']);
    expect(asks, [false, true]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(s.lastError, isNull, reason: 'the fresh token cured the refusal');
  });

  test('a token the relay stops mid-session (FORBIDDEN) is replaced once', () async {
    relay = _Relay(['accept-then-forbid', 'accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => f ? 'tok-2' : 'tok-1'));
    await _until(() => relay.bearers.length == 2);
    expect(relay.bearers, ['Bearer tok-1', 'Bearer tok-2']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(s.lastError, isNull);
  });

  test('a second refusal in a row is final: one fresh try, not a loop', () async {
    relay = _Relay([401, 401, 'accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => f ? 'tok-${n + 1}' : 'tok-1'));
    await _until(() => s.lastError != null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.bearers, ['Bearer tok-1', 'Bearer tok-2']);
    expect(asks, [false, true]);
    expect(s.lastError!.code, 'UNAUTHORIZED');
  });

  test('a provider with nothing new leaves the refusal final', () async {
    relay = _Relay([401, 'accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => 'tok-1'));
    await _until(() => s.lastError != null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.bearers, ['Bearer tok-1']);
    expect(s.lastError!.code, 'UNAUTHORIZED');
  });

  test("the account's answer (402) is final at once: no fresh ask", () async {
    relay = _Relay([402, 'accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => f ? 'tok-2' : 'tok-1'));
    await _until(() => s.lastError != null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.bearers, ['Bearer tok-1']);
    expect(asks, [false]);
    expect(s.lastError!.code, 'INSUFFICIENT_BALANCE');
  });

  test("an API secret's 401 is final, exactly as before", () async {
    relay = _Relay([401, 'accept']);
    await relay.start();
    final s = await open(apiKey: 'sk_live_secret_but_not_openai'.replaceFirst('sk_', 'bh_'));
    await _until(() => s.lastError != null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.bearers, ['Bearer bh_live_secret_but_not_openai']);
    expect(s.lastError!.code, 'UNAUTHORIZED');
  });

  test('a provider with no token refuses before dialing', () async {
    relay = _Relay(['accept']);
    await relay.start();
    final s = await open(credential: provider((f, n) => ''));
    expect(s.lastError?.code, 'UNAUTHORIZED');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(relay.bearers, isEmpty, reason: 'nothing to bill to, so nothing is dialed');
  });
}
