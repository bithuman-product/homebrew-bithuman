// mock_realtime — hermetic stand-in for the OpenAI Realtime WebSocket API.
//
// Speaks exactly the event subset `BithumanRealtimeSession`
// (flutter/bithuman/lib/bithuman_realtime.dart) consumes:
//
//   server → client : session.created, response.created,
//                     response.output_audio.delta (base64 PCM16 @ 24 kHz),
//                     response.output_audio_transcript.delta,
//                     response.done, response.cancelled,
//                     input_audio_buffer.speech_started / speech_stopped,
//                     error
//   client → server : session.update, response.create, response.cancel,
//                     input_audio_buffer.append / commit
//
// Design: the server itself is UNSCRIPTED — every received client event is
// recorded and exposed (`received`, `nextEvent()`), and the test drives the
// conversation by calling the send helpers (`sendResponse`, `barge`, …).
// That keeps scenario logic in the test where it can interleave UI
// assertions, while this file owns the wire format.
//
// Audio fixtures are SYNTHESIZED (amplitude-modulated sine, speech-band) so
// the repo carries no audio binaries and nothing here is or contains a
// secret. The Bearer token the client connects with is recorded for
// assertions but never validated — any value is accepted.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Synthesize [ms] milliseconds of mono PCM16 @ [sampleRate]: a 180 Hz tone
/// with a 4 Hz amplitude envelope — crudely speech-shaped, deterministic,
/// and loud enough to drive level meters / lipsync queues.
Uint8List synthPcm(int ms, {int sampleRate = 24000, double gain = 0.4}) {
  final n = (sampleRate * ms / 1000).round();
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final env = 0.5 * (1 - math.cos(2 * math.pi * 4 * t)); // 4 Hz pulse
    out[i] = (32767 * gain * env * math.sin(2 * math.pi * 180 * t)).round();
  }
  return out.buffer.asUint8List();
}

/// One recorded client→server event.
class ClientEvent {
  ClientEvent(this.type, this.json);
  final String type;
  final Map<String, dynamic> json;
  @override
  String toString() => 'ClientEvent($type)';
}

/// A single live client connection (the harness expects one at a time, but
/// reconnects produce a fresh [MockConnection] via [MockRealtimeServer.connections]).
class MockConnection {
  MockConnection(this._ws, {this.authorization, this.uri});

  final WebSocket _ws;

  /// Raw `Authorization` header the client dialed with (assert-only).
  final String? authorization;

  /// Request URI of the upgrade (carries ?model=… in the real protocol).
  final Uri? uri;

  /// Every event received from the client, in order.
  final List<ClientEvent> received = [];

  final _eventWaiters = <Completer<ClientEvent>>[];
  final _closed = Completer<void>();
  int _consumed = 0; // nextEvent() read cursor

  bool get isClosed => _closed.isCompleted;

  /// Completes when the client closes the socket (or the server does).
  Future<void> get done => _closed.future;

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ev = ClientEvent((json['type'] as String?) ?? '?', json);
    received.add(ev);
    // Wake exactly one nextEvent() waiter per event, oldest first.
    if (_eventWaiters.isNotEmpty) {
      _eventWaiters.removeAt(0).complete(ev);
    }
  }

  void _onDone() {
    if (!_closed.isCompleted) _closed.complete();
    for (final w in _eventWaiters) {
      if (!w.isCompleted) {
        w.completeError(StateError('connection closed while waiting'));
      }
    }
    _eventWaiters.clear();
  }

  /// Pull the next unconsumed client event (FIFO over [received]), waiting
  /// up to [timeout] for one to arrive. Use [nextEventOfType] to skip noise
  /// (e.g. a stream of input_audio_buffer.append).
  Future<ClientEvent> nextEvent(
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (_consumed < received.length) {
      return received[_consumed++];
    }
    final c = Completer<ClientEvent>();
    _eventWaiters.add(c);
    final ev = await c.future.timeout(timeout, onTimeout: () {
      _eventWaiters.remove(c);
      throw TimeoutException('no client event within $timeout '
          '(received so far: ${received.map((e) => e.type).toList()})');
    });
    _consumed++;
    return ev;
  }

  /// Pull events until one of [type] arrives (consuming the ones skipped).
  Future<ClientEvent> nextEventOfType(String type,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) {
        throw TimeoutException('no "$type" event within $timeout '
            '(received: ${received.map((e) => e.type).toList()})');
      }
      final ev = await nextEvent(timeout: left);
      if (ev.type == type) return ev;
    }
  }

  /// All recorded events of [type] (whether consumed or not).
  List<ClientEvent> eventsOfType(String type) =>
      received.where((e) => e.type == type).toList();

  // ── server → client helpers ──────────────────────────────────────────

  void send(Map<String, dynamic> event) {
    if (isClosed) return;
    _ws.add(jsonEncode(event));
  }

  void sendSessionCreated() =>
      send({'type': 'session.created', 'session': {'id': 'mock_sess_1'}});

  void sendResponseCreated() =>
      send({'type': 'response.created', 'response': {'id': 'mock_resp'}});

  void sendAudioDelta(Uint8List pcm24k) => send({
        'type': 'response.output_audio.delta',
        'delta': base64Encode(pcm24k),
      });

  void sendTranscriptDelta(String text) => send({
        'type': 'response.output_audio_transcript.delta',
        'delta': text,
      });

  void sendResponseDone() => send({'type': 'response.done'});

  // Generation guard: cancelling (or starting a new scripted response)
  // halts any in-flight sendResponse stream — mirrors the real server,
  // which stops emitting deltas for a cancelled response.
  int _streamGen = 0;

  void sendResponseCancelled() {
    _streamGen++;
    send({'type': 'response.cancelled'});
  }

  void sendSpeechStarted() => send({'type': 'input_audio_buffer.speech_started'});

  void sendSpeechStopped() => send({'type': 'input_audio_buffer.speech_stopped'});

  void sendUserTranscript(String text) => send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': text,
      });

  void sendError(String code, String message) => send({
        'type': 'error',
        'error': {'code': code, 'message': message},
      });

  /// Stream a full scripted response: response.created, [chunks] audio
  /// deltas of [chunkMs] each (synthesized PCM), one transcript delta per
  /// audio delta, then response.done (unless [done] is false — e.g. when
  /// the test intends to barge mid-stream). [interDelta] simulates network
  /// pacing; zero = burst (exercises the client's lipsync pacing governor).
  Future<void> sendResponse({
    String transcript = 'Hello from the mock realtime server.',
    int chunks = 5,
    int chunkMs = 100,
    Duration interDelta = Duration.zero,
    bool done = true,
  }) async {
    final gen = ++_streamGen;
    sendResponseCreated();
    final words = transcript.split(' ');
    for (var i = 0; i < chunks; i++) {
      if (isClosed || gen != _streamGen) return; // cancelled / superseded
      sendAudioDelta(synthPcm(chunkMs));
      if (i < words.length) {
        sendTranscriptDelta(i == 0 ? words[i] : ' ${words[i]}');
      }
      if (interDelta > Duration.zero) {
        await Future<void>.delayed(interDelta);
      }
    }
    if (done && !isClosed && gen == _streamGen) sendResponseDone();
  }

  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    await _ws.close(code);
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// The mock server: accepts WebSocket upgrades on 127.0.0.1:[port] and
/// surfaces each client as a [MockConnection].
class MockRealtimeServer {
  MockRealtimeServer._(this._http);

  final HttpServer _http;
  final List<MockConnection> connections = [];
  final _connWaiters = <Completer<MockConnection>>[];

  int get port => _http.port;

  /// ws:// URL a client should dial.
  String get url => 'ws://127.0.0.1:$port';

  /// Bind on 127.0.0.1:[port] (0 = ephemeral).
  static Future<MockRealtimeServer> start({int port = 0}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final server = MockRealtimeServer._(http);
    http.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..statusCode = HttpStatus.ok
          ..write('mock_realtime up')
          ..close();
        return;
      }
      final auth = req.headers.value('authorization');
      final ws = await WebSocketTransformer.upgrade(req);
      final conn = MockConnection(ws, authorization: auth, uri: req.uri);
      ws.listen(conn._onMessage,
          onDone: conn._onDone, onError: (_) => conn._onDone());
      server.connections.add(conn);
      if (server._connWaiters.isNotEmpty) {
        server._connWaiters.removeAt(0).complete(conn);
      }
    });
    return server;
  }

  /// Wait for the next client connection ([index] into [connections]; by
  /// default the next one not yet returned by this method).
  int _connConsumed = 0;
  Future<MockConnection> nextConnection(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (_connConsumed < connections.length) {
      return connections[_connConsumed++];
    }
    final c = Completer<MockConnection>();
    _connWaiters.add(c);
    final conn = await c.future.timeout(timeout, onTimeout: () {
      _connWaiters.remove(c);
      throw TimeoutException('no client connected within $timeout');
    });
    _connConsumed++;
    return conn;
  }

  Future<void> close() async {
    for (final c in List.of(connections)) {
      try {
        await c.close();
      } catch (_) {}
    }
    await _http.close(force: true);
  }
}
