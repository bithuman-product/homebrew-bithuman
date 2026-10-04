// The hybrid brain's Dart surface, one for iOS and Android: LocalConverseTransport bridges the
// native brain's events to a HostReplySource. Hermetic: a RecordingVoiceHost (no channel) and a
// scripted source. Locks the wire the relay text brain needs (platform #1328):
//   * reply_request → reply(text, continuation): the native `text`, else the last user message;
//   * reply_cancel {heardChars} → cancelled(id, heardChars) BEFORE the stream is dropped, also for
//     a reply whose stream already finished (the voice was still speaking it);
//   * the greeting is the source's line spoken verbatim (localSpeakText) — never a user turn;
//   * stop() closes the source.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';

import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_voice_host.dart';

class _Source extends HostReplySource {
  _Source({this.line});
  final String? line;
  final requests = <HostReplyRequest>[];
  final cancels = <String>[];
  final streams = <int, StreamController<String>>{};
  final dropped = <int>[];
  var closed = 0;

  @override
  Stream<String> reply(HostReplyRequest request) {
    requests.add(request);
    final c = StreamController<String>(onCancel: () => dropped.add(request.id));
    streams[request.id] = c;
    return c.stream;
  }

  @override
  void cancelled(int id, {int? heardChars}) => cancels.add('$id:$heardChars:${dropped.contains(id)}');

  @override
  Future<String?> greeting() async => line;

  @override
  Future<void> close() async => closed++;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a reply_request becomes reply(); pieces and the end go back to the brain', () async {
    final host = RecordingVoiceHost();
    final src = _Source();
    final t = LocalConverseTransport(avatar: host, replySource: src, greet: false);
    await t.start();
    expect(host.calls.first, startsWith('localAudioStart'));

    // An older native side: no `text` — the last user message is the turn.
    host.emitConverse({
      'kind': 'reply_request',
      'id': 1,
      'maxTokens': 220,
      'messages': [
        {'role': 'system', 'content': 'You are Wise Pup.'},
        {'role': 'user', 'content': 'Hi Wise Pup!'},
      ],
    });
    await _settle();
    expect(src.requests.single.text, 'Hi Wise Pup!');
    expect(src.requests.single.continuation, isFalse);
    expect(src.requests.single.messages.first['role'], 'system');
    expect(src.requests.single.maxTokens, 220);
    src.streams[1]!
      ..add('Woof! ')
      ..add('Hello there.');
    await src.streams[1]!.close();
    await _settle();
    expect(host.calls.where((c) => c.startsWith('localReplyText:1')),
        ['localReplyText:1:Woof! ', 'localReplyText:1:Hello there.', 'localReplyText:1:done:0']);
  });

  test('a continuation carries the whole utterance and says it replaces the last turn', () async {
    final host = RecordingVoiceHost();
    final src = _Source();
    final t = LocalConverseTransport(avatar: host, replySource: src, greet: false);
    await t.start();
    host.emitConverse({'kind': 'reply_request', 'id': 1, 'text': 'Hi Wise Pup!', 'messages': const []});
    await _settle();
    // The recognizer split the utterance: the brain cancels the first reply (nothing heard yet)
    // and re-asks with the whole turn.
    host.emitConverse({'kind': 'reply_cancel', 'id': 1, 'heardChars': 0});
    host.emitConverse({
      'kind': 'reply_request',
      'id': 2,
      'text': 'Hi Wise Pup! How are you?',
      'continuation': true,
      'messages': const [],
    });
    await _settle();
    expect(src.cancels, ['1:0:false'], reason: 'cancelled() comes before the stream is dropped');
    expect(src.dropped, [1]);
    expect(src.requests.last.text, 'Hi Wise Pup! How are you?');
    expect(src.requests.last.continuation, isTrue);
  });

  test('a barge after the stream finished still reports what was heard', () async {
    final host = RecordingVoiceHost();
    final src = _Source();
    final t = LocalConverseTransport(avatar: host, replySource: src, greet: false);
    await t.start();
    host.emitConverse({'kind': 'reply_request', 'id': 7, 'text': 'tell me a story', 'messages': const []});
    await _settle();
    src.streams[7]!.add('Once upon a time there was a pup.');
    await src.streams[7]!.close();
    await _settle();
    // The text is done; the voice is 12 characters in when the person cuts in.
    host.emitConverse({'kind': 'reply_cancel', 'id': 7, 'heardChars': 12});
    await _settle();
    expect(src.cancels, ['7:12:false']);
    // An older native side sends no count: null, not 0 (0 would erase the reply).
    host.emitConverse({'kind': 'reply_cancel', 'id': 7});
    await _settle();
    expect(src.cancels.last, '7:null:false');
  });

  test('a stream error ends the reply with result 3 (the brain says its fallback line)', () async {
    final host = RecordingVoiceHost();
    final src = _Source();
    final t = LocalConverseTransport(avatar: host, replySource: src, greet: false);
    await t.start();
    host.emitConverse({'kind': 'reply_request', 'id': 3, 'text': 'hi', 'messages': const []});
    await _settle();
    src.streams[3]!.addError(StateError('relay closed'));
    await _settle();
    expect(host.calls.last, 'localReplyText:3:done:3');
  });

  test("the hybrid greeting is the source's line spoken verbatim, never a user turn", () async {
    final host = RecordingVoiceHost();
    final src = _Source(line: "Hi, I'm Wise Pup!");
    final t = LocalConverseTransport(avatar: host, replySource: src);
    await t.start();
    host.emitConverse({'kind': 'ready'});
    await _settle();
    await _settle();
    expect(host.calls, contains("localSpeakText:Hi, I'm Wise Pup!"));
    expect(host.calls, isNot(contains('localPushText')));
    host.emitConverse({'kind': 'ready'}); // once per session
    await _settle();
    expect(host.calls.where((c) => c.startsWith('localSpeakText')), hasLength(1));
  });

  test('a source without a greeting says nothing; the on-device model still greets itself', () async {
    final host = RecordingVoiceHost();
    final t = LocalConverseTransport(avatar: host, replySource: _Source());
    await t.start();
    host.emitConverse({'kind': 'ready'});
    await _settle();
    expect(host.calls.where((c) => c.startsWith('localSpeakText') || c == 'localPushText'), isEmpty);

    final host2 = RecordingVoiceHost();
    final t2 = LocalConverseTransport(avatar: host2, ggufPath: '/m.gguf');
    await t2.start();
    host2.emitConverse({'kind': 'ready'});
    await _settle();
    expect(host2.calls, contains('localPushText'));
  });

  test('stop() drops the stream in flight and closes the source', () async {
    final host = RecordingVoiceHost();
    final src = _Source();
    final t = LocalConverseTransport(avatar: host, replySource: src, greet: false);
    await t.start();
    host.emitConverse({'kind': 'reply_request', 'id': 1, 'text': 'hi', 'messages': const []});
    await _settle();
    await t.stop();
    await _settle();
    expect(src.dropped, [1]);
    expect(src.closed, 1);
  });

  test('HostReplySource.fromMessages hands the brain its own prompt', () async {
    final seen = <List<Map<String, String>>>[];
    final src = HostReplySource.fromMessages((m) {
      seen.add(m);
      return Stream.value('ok');
    });
    final out = await src
        .reply(const HostReplyRequest(id: 1, text: 'hi', messages: [
          {'role': 'user', 'content': 'hi'}
        ]))
        .toList();
    expect(out, ['ok']);
    expect(seen.single.single['content'], 'hi');
    expect(await src.greeting(), isNull);
  });
}
