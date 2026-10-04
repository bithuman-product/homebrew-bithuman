// RelayTextBrain against a fake relay (dart:io WebSocket server speaking the ?mode=text wire of
// platform services/realtime-relay/text_brain.py). Locks what the server expects:
//   user.turn {turn, text, replaces?}, response.cancel {turn, heard_chars?}, session.end;
//   the verbatim greeting; a refused handshake maps to its status; a failed reply errors.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRelay {
  late HttpServer server;
  final received = <Map<String, dynamic>>[];
  final headers = <String, String?>{};
  Uri? lastUri;
  int refuseWith = 0;
  String greeting = "Hi, I'm Wise Pup!";
  WebSocket? ws;
  final _got = StreamController<Map<String, dynamic>>.broadcast();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      lastUri = req.uri;
      headers['api-secret'] = req.headers.value('api-secret');
      if (refuseWith != 0) {
        req.response.statusCode = refuseWith;
        req.response.write(jsonEncode({'error': {'code': 'X'}}));
        await req.response.close();
        return;
      }
      final s = await WebSocketTransformer.upgrade(req);
      ws = s;
      void send(Map<String, Object?> m) => s.add(jsonEncode(m));
      send({'type': 'session.created', 'session': 'abc', 'agent': req.uri.queryParameters['agent'], 'mode': 'text',
            'limits': {'max_session_s': 3600, 'max_user_chars': 1000, 'turns_per_min': 30}});
      if (req.uri.queryParameters['greet'] != '0') {
        send({'type': 'response.created', 'turn': 'greeting'});
        send({'type': 'response.text.delta', 'turn': 'greeting', 'delta': greeting});
        send({'type': 'response.done', 'turn': 'greeting', 'status': 'completed'});
      }
      s.listen((d) {
        final ev = jsonDecode(d as String) as Map<String, dynamic>;
        received.add(ev);
        _got.add(ev);
        if (ev['type'] == 'user.turn') {
          final turn = ev['turn'];
          if (ev['text'] == 'fail') {
            send({'type': 'response.created', 'turn': turn});
            send({'type': 'error', 'error': {'type': 'bithuman_relay', 'code': 'UPSTREAM_ERROR', 'message': 'x'}});
            send({'type': 'response.done', 'turn': turn, 'status': 'failed'});
            return;
          }
          if (ev['text'] == 'slow') {
            send({'type': 'response.created', 'turn': turn});
            send({'type': 'response.text.delta', 'turn': turn, 'delta': 'Once '});
            return; // never finishes: the client cancels
          }
          send({'type': 'response.created', 'turn': turn});
          for (final d in ['Woof! ', 'Hello ', 'friend.']) {
            send({'type': 'response.text.delta', 'turn': turn, 'delta': d});
          }
          send({'type': 'response.done', 'turn': turn, 'status': 'completed'});
        }
        if (ev['type'] == 'session.end') s.close();
      });
    });
  }

  Future<Map<String, dynamic>> next(String type) => _got.stream.firstWhere((e) => e['type'] == type);

  Uri get uri => Uri.parse('ws://127.0.0.1:${server.port}/v1/realtime');
}

void main() {
  late _FakeRelay relay;
  setUp(() async {
    relay = _FakeRelay();
    await relay.start();
  });
  tearDown(() async => relay.server.close(force: true));

  test('connect, the verbatim greeting, a turn streamed back, close', () async {
    final brain = await RelayTextBrain.connect(apiSecret: 'k', agentCode: 'A23WJF0199', endpoint: relay.uri);
    expect(relay.lastUri!.queryParameters, {'mode': 'text', 'agent': 'A23WJF0199'});
    expect(relay.headers['api-secret'], 'k');
    expect(brain.session, 'abc');
    expect(await brain.greeting(), "Hi, I'm Wise Pup!");
    final out = await brain.reply(const HostReplyRequest(id: 1, text: 'hello')).toList();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(out.join(), 'Woof! Hello friend.');
    expect(relay.received.first, {'type': 'user.turn', 'turn': 't1', 'text': 'hello'});
    final end = relay.next('session.end');
    await brain.close();
    await end;
    expect(await brain.done.timeout(const Duration(seconds: 2)), isNotNull);
  });

  test('a continuation replaces the previous turn; a barge sends heard_chars', () async {
    final brain = await RelayTextBrain.connect(apiSecret: 'k', agentCode: 'A23WJF0199', greet: false,
        endpoint: relay.uri);
    expect(relay.lastUri!.queryParameters['greet'], '0');
    expect(await brain.greeting(), isNull);
    final first = relay.next('user.turn');
    final sub = brain.reply(const HostReplyRequest(id: 4, text: 'slow')).listen((_) {});
    await first;
    // the brain heard 3 characters of it, then the stream is dropped: ONE cancel, with the count
    final cancel = relay.next('response.cancel');
    brain.cancelled(4, heardChars: 3);
    await sub.cancel();
    expect(await cancel, {'type': 'response.cancel', 'turn': 't4', 'heard_chars': 3});
    final turn = relay.next('user.turn');
    final bareF = relay.next('response.cancel');
    await brain.reply(const HostReplyRequest(id: 5, text: 'slow and more', continuation: true)).listen((_) {}).cancel();
    expect(await turn, {'type': 'user.turn', 'turn': 't5', 'text': 'slow and more', 'replaces': 't4'});
    // dropped without cancelled() (a stop): a cancel with no count, so the server keeps what streamed
    expect(await bareF, {'type': 'response.cancel', 'turn': 't5'});
    expect(relay.received.where((e) => e['type'] == 'response.cancel'), hasLength(2));
    // after the stream is over, a late barge still reports what was heard
    await brain.reply(const HostReplyRequest(id: 6, text: 'hi')).toList();
    final late = relay.next('response.cancel');
    brain.cancelled(6, heardChars: 9);
    expect(await late, {'type': 'response.cancel', 'turn': 't6', 'heard_chars': 9});
    await brain.close();
  });

  test('a failed reply is a stream error; a refused handshake names its status', () async {
    final brain = await RelayTextBrain.connect(apiSecret: 'k', agentCode: 'A23WJF0199', greet: false,
        endpoint: relay.uri);
    final errors = <String>[];
    brain.errors.listen((e) => errors.add(e.code));
    await expectLater(brain.reply(const HostReplyRequest(id: 1, text: 'fail')).toList(), throwsStateError);
    expect(errors, ['UPSTREAM_ERROR']);
    await brain.close();

    relay.refuseWith = 402;
    await expectLater(
        RelayTextBrain.connect(apiSecret: 'k', agentCode: 'A23WJF0199', endpoint: relay.uri),
        throwsA(isA<RelayTextBrainRefused>()
            .having((e) => e.status, 'status', 402)
            .having((e) => e.code, 'code', 'X')));   // the relay's own code, from the body
  });
}
