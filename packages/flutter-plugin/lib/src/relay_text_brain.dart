// RelayTextBrain: the hybrid brain's words from bitHuman's relay — `wss://api.bithuman.ai/v1/realtime
// ?mode=text&agent=<code>` (platform services/realtime-relay/text_brain.py, TEXT_BRAIN.md).
//
// The phone hears and speaks (LocalConverseTransport, replyMode 'host'); only text crosses the
// network. The relay holds the persona (a house character's, or the caller's own agent's) and the
// memory, runs a cheap text model on bitHuman's key, and bills the session like a realtime voice
// session (the chat line, 10 credits a minute, the same beat as /v1/realtime).
//
//   reply(request)      → {"type":"user.turn","turn":"t<id>","text":..., "replaces":"t<prev>"?}
//                       ← response.created / response.text.delta... / response.done {status}
//   cancelled(id, n)    → {"type":"response.cancel","turn":"t<id>","heard_chars":n}
//   greeting()          ← the house opening line, verbatim (turn "greeting"; no model call)
//   close()             → {"type":"session.end"} and the socket closes (the final beat goes out)
//
// The credential is the account's api-secret (as for /v1/realtime), never a token — the relay
// refuses a token-shaped credential before any beat.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_reply.dart';

/// The relay refused the session at the handshake: [status] 401 (key), 402
/// INSUFFICIENT_BALANCE (show the paywall), 403 PERSONA_FORBIDDEN (not your agent),
/// 503 (capacity; retry), 400 (a bad request or the mode is off on this relay).
class RelayTextBrainRefused implements Exception {
  RelayTextBrainRefused(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => 'RelayTextBrainRefused($status, $code)';
}

/// A relay error during the session (`error` frames). A [terminal] one
/// (INSUFFICIENT_BALANCE, SESSION_DURATION_LIMIT, FORBIDDEN) is followed by the socket closing.
class RelayTextBrainError {
  const RelayTextBrainError(this.code, this.message);
  final String code;
  final String message;
  bool get terminal => const {'INSUFFICIENT_BALANCE', 'SESSION_DURATION_LIMIT', 'FORBIDDEN'}.contains(code);
  @override
  String toString() => 'RelayTextBrainError($code: $message)';
}

class RelayTextBrain extends HostReplySource {
  RelayTextBrain._(this._ws, this.session, this.agent, this.maxSessionS, this._frames, this._greet);

  static final Uri defaultEndpoint = Uri.parse('wss://api.bithuman.ai/v1/realtime');

  final WebSocket _ws;

  /// The relay's session id, the agent code and the session's length cap (seconds).
  final String session;
  final String agent;
  final double maxSessionS;

  final StreamIterator<Map<String, dynamic>>? _frames; // only for the handshake
  final bool _greet;
  final _errors = StreamController<RelayTextBrainError>.broadcast();
  final _closed = Completer<int?>();
  final _greeting = Completer<String?>();
  final _greetingText = StringBuffer();
  final Map<String, _Turn> _turns = {};
  String? _lastTurn;

  /// Relay errors as they arrive (a terminal one ends the session: see [done]).
  Stream<RelayTextBrainError> get errors => _errors.stream;

  /// Completes with the close code when the relay closes the session.
  Future<int?> get done => _closed.future;

  /// Opens a text-brain session for [agentCode]: a bitHuman Live house character (any paying
  /// key), or the caller's own agent. Billing starts here and stops at [close]. [greet] false
  /// skips the house opening line (e.g. a reconnect). Throws [RelayTextBrainRefused].
  static Future<RelayTextBrain> connect({
    required String apiSecret,
    required String agentCode,
    bool greet = true,
    Uri? endpoint,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final base = endpoint ?? defaultEndpoint;
    final uri = base.replace(queryParameters: {
      ...base.queryParameters,
      'mode': 'text',
      'agent': agentCode,
      if (!greet) 'greet': '0',
    });
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(uri.toString(), headers: {'api-secret': apiSecret}).timeout(timeout);
    } on WebSocketException catch (e) {
      // dart:io reports a refused upgrade as "... HTTP status code: 402"; map the status.
      final m = RegExp(r'status code: (\d{3})').firstMatch(e.message);
      final status = m == null ? 0 : int.parse(m.group(1)!);
      throw RelayTextBrainRefused(
          status,
          const {
                400: 'VALIDATION_ERROR',
                401: 'UNAUTHORIZED',
                402: 'INSUFFICIENT_BALANCE',
                403: 'FORBIDDEN',
                503: 'SERVICE_UNAVAILABLE',
              }[status] ??
              'UPSTREAM_ERROR');
    }
    ws.pingInterval = const Duration(seconds: 20);
    final frames = StreamIterator(ws
        .where((d) => d is String)
        .map((d) {
          try {
            final v = jsonDecode(d as String);
            return v is Map<String, dynamic> ? v : const <String, dynamic>{};
          } on FormatException {
            return const <String, dynamic>{};
          }
        }));
    // The first frame is session.created (or an error and a close).
    Map<String, dynamic>? created;
    try {
      while (await frames.moveNext().timeout(timeout)) {
        final ev = frames.current;
        if (ev['type'] == 'session.created') {
          created = ev;
          break;
        }
        if (ev['type'] == 'error') {
          final err = ev['error'] as Map<String, dynamic>? ?? const {};
          await ws.close();
          throw RelayTextBrainRefused(0, err['code'] as String? ?? 'UPSTREAM_ERROR');
        }
      }
    } on TimeoutException {
      await ws.close();
      throw RelayTextBrainRefused(0, 'TIMEOUT');
    }
    if (created == null) {
      throw RelayTextBrainRefused(0, 'CLOSED');
    }
    final limits = created['limits'] as Map<String, dynamic>? ?? const {};
    final brain = RelayTextBrain._(ws, created['session'] as String? ?? '', created['agent'] as String? ?? agentCode,
        (limits['max_session_s'] as num?)?.toDouble() ?? 3600, frames, greet);
    brain._pump();
    return brain;
  }

  Future<void> _pump() async {
    final frames = _frames!;
    try {
      while (await frames.moveNext()) {
        _onFrame(frames.current);
      }
    } catch (_) {
      // the socket failed: treated as closed below
    }
    final code = _ws.closeCode;
    for (final t in _turns.values) {
      t.fail('the relay closed the session ($code)');
    }
    _turns.clear();
    if (!_greeting.isCompleted) _greeting.complete(null);
    if (!_closed.isCompleted) _closed.complete(code);
    await _errors.close();
  }

  void _onFrame(Map<String, dynamic> ev) {
    final turn = ev['turn'] as String? ?? '';
    switch (ev['type']) {
      case 'response.text.delta':
        final d = ev['delta'] as String? ?? '';
        if (turn == 'greeting') {
          _greetingText.write(d);
        } else {
          _turns[turn]?.add(d);
        }
      case 'response.done':
        if (turn == 'greeting') {
          if (!_greeting.isCompleted) {
            final s = _greetingText.toString().trim();
            _greeting.complete(s.isEmpty ? null : s);
          }
        } else {
          final t = _turns.remove(turn);
          final status = ev['status'] as String? ?? 'completed';
          if (t != null) {
            if (status == 'failed' && !t.any) {
              t.fail('the character could not answer');
            } else {
              t.finish();
            }
          }
        }
      case 'error':
        final err = ev['error'] as Map<String, dynamic>? ?? const {};
        final e = RelayTextBrainError(err['code'] as String? ?? 'UPSTREAM_ERROR', err['message'] as String? ?? '');
        if (!_errors.isClosed) _errors.add(e);
        // A refused turn (rate limit, size) gets no response.done: end it here.
        if (e.code == 'RATE_LIMITED' || e.code == 'VALIDATION_ERROR') {
          final pending = _turns.values.where((t) => !t.started).toList();
          for (final t in pending) {
            _turns.remove(t.id);
            t.fail(e.toString());
          }
        }
      case 'response.created':
        _turns[turn]?.started = true;
      default:
        break; // forward compatible
    }
  }

  void _send(Map<String, Object?> msg) {
    if (_ws.readyState == WebSocket.open) _ws.add(jsonEncode(msg));
  }

  @override
  Future<String?> greeting() {
    if (!_greet) return Future.value(null);
    // A non-house agent has no opening line: nothing arrives, so do not wait long.
    return _greeting.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
  }

  @override
  Stream<String> reply(HostReplyRequest request) {
    final id = 't${request.id}';
    final replaces = request.continuation ? _lastTurn : null;
    _lastTurn = id;
    late final _Turn turn;
    final ctl = StreamController<String>(onCancel: () {
      // Dropped without cancelled() (a stop, a new turn): stop the server's stream too.
      if (_turns.remove(id) != null && !turn.cancelSent) {
        turn.cancelSent = true;
        _send({'type': 'response.cancel', 'turn': id});
      }
    });
    turn = _Turn(id, ctl);
    _turns[id] = turn;
    _send({
      'type': 'user.turn',
      'turn': id,
      'text': request.text,
      if (replaces != null) 'replaces': replaces,
    });
    if (_ws.readyState != WebSocket.open) {
      _turns.remove(id);
      turn.fail('the relay session is closed');
    }
    return ctl.stream;
  }

  @override
  void cancelled(int id, {int? heardChars}) {
    final tid = 't$id';
    final t = _turns[tid];
    if (t != null) t.cancelSent = true;
    _send({'type': 'response.cancel', 'turn': tid, 'heard_chars': ?heardChars});
  }

  @override
  Future<void> close() async {
    _send({'type': 'session.end'});
    try {
      await _ws.close(WebSocketStatus.normalClosure);
    } catch (_) {}
  }
}

class _Turn {
  _Turn(this.id, this._ctl);
  final String id;
  final StreamController<String> _ctl;
  bool started = false;
  bool any = false;
  bool cancelSent = false;

  void add(String d) {
    if (d.isEmpty || _ctl.isClosed) return;
    any = true;
    _ctl.add(d);
  }

  void finish() {
    if (!_ctl.isClosed) _ctl.close();
  }

  void fail(String why) {
    if (_ctl.isClosed) return;
    _ctl.addError(StateError(why));
    _ctl.close();
  }
}
