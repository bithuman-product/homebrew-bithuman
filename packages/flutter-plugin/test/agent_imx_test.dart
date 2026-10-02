// downloadAgentImx (lib/src/agent_imx.dart, 2.6.30): redirects to trusted hosts only, the API key to
// the door only, a cached file opens at once with the published check in the background, and a kept
// Essence 2 file from before the 2026-10-01 re-publish is fetched again once.
//
// Two loopback servers stand in for the door and the storage it redirects to (plain http, which only
// a test's AgentImxDownloader(allowInsecure: true) accepts). No real network.
//
// Apache-2.0; (c) bitHuman.

import 'dart:io';
import 'dart:typed_data';

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/src/agent_imx.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loopback server: [handler] answers; every request is recorded.
class _Srv {
  _Srv(this.server, this.handler) {
    server.listen((req) async {
      hits.add(req);
      keys.add(req.headers.value('api-secret'));
      await handler(req);
    });
  }
  final HttpServer server;
  Future<void> Function(HttpRequest req) handler;
  final hits = <HttpRequest>[];
  final keys = <String?>[];
  Uri url(String host, String path) => Uri.parse('http://$host:${server.port}$path');
  static Future<_Srv> start(Future<void> Function(HttpRequest) h) async =>
      _Srv(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), h);
}

Uint8List _imx(int size, int fill) {
  final b = Uint8List(size)..fillRange(0, size, fill);
  b.setRange(0, 3, 'IMX'.codeUnits);
  return b;
}

BithumanAgent _agent(String id, String modelUrl, {String modelType = 'essence-2'}) => BithumanAgent(
    id: id, name: id, description: '', category: '', imageUrl: '', modelUrl: modelUrl,
    systemPrompt: '', voiceId: '', modelType: modelType);

void main() {
  late Directory tmp;
  late _Srv door, storage;
  late Uint8List published;
  final cutoff = DateTime.utc(2026, 10, 2);
  final after = DateTime.utc(2026, 10, 3, 12);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('agent_imx_test');
    published = _imx(1200000, 7);
    storage = await _Srv.start((req) async {
      req.response.headers.contentLength = published.length;
      req.response.add(published);
      await req.response.close();
    });
    door = await _Srv.start((req) async {
      // The door redirects to the storage host ('localhost' — a different host from the door's).
      await req.response.redirect(storage.url('localhost', '/signed/A52DHS2219.imx?token=x'), status: 302);
    });
  });

  tearDown(() async {
    await door.server.close(force: true);
    await storage.server.close(force: true);
    await tmp.delete(recursive: true);
  });

  // The loopback door (127.0.0.1) stands in for bitHuman's doors: its redirects are followed.
  AgentImxDownloader dl({DateTime? now, Set<String> doorHosts = const {'127.0.0.1'}}) => AgentImxDownloader(
      allowInsecure: true, clock: () => now ?? after, staleBefore: cutoff, doorHosts: doorHosts,
      door: (code) => door.url('127.0.0.1', '/v1/agent/$code/model/download'));
  const trustedLoopback = {'127.0.0.1', 'localhost'};

  test('follows the door\'s redirect to a trusted host; the API key goes to the door only', () async {
    // No allowedHosts: a door's redirect is trusted on its own.
    final p = await dl().download(_agent('A52DHS2219', 'unused'), tmp.path, apiSecret: 'sk_test');
    expect(await File(p).readAsBytes(), published);
    expect(door.keys, ['sk_test'], reason: 'the key is sent to the door');
    expect(storage.keys, [null], reason: 'never to the storage host it redirects to');
  });

  test('without a key, the catalog\'s own door is asked anonymously', () async {
    final a = _agent('A52DHS2219', door.url('127.0.0.1', '/api/agents/A52DHS2219/model/download').toString());
    final p = await dl().download(a, tmp.path, allowedHosts: trustedLoopback);
    expect(await File(p).length(), published.length);
    expect(door.keys, [null]);
  });

  test('a redirect from a host that is not a door, to a host not allowed, is refused; nothing is written', () async {
    final a = _agent('A52DHS2219', door.url('127.0.0.1', '/x').toString());
    await expectLater(dl(doorHosts: const {}).download(a, tmp.path, allowedHosts: {'127.0.0.1'}),
        throwsA(isA<BithumanAvatarException>().having((e) => e.message, 'message', contains('untrusted host: localhost'))));
    expect(storage.hits, isEmpty);
    expect(tmp.listSync(), isEmpty);
  });

  test('401 says what it can download: pass the owner\'s apiSecret', () async {
    door.handler = (req) async { req.response.statusCode = 401; await req.response.close(); };
    final a = _agent('A48YMB2679', door.url('127.0.0.1', '/x').toString(), modelType: 'essence-1');
    await expectLater(dl().download(a, tmp.path, allowedHosts: trustedLoopback),
        throwsA(isA<BithumanAvatarException>().having((e) => e.message, 'message', contains('apiSecret'))));
    expect(tmp.listSync(), isEmpty);
  });

  test('a non-https model_url is refused (outside a test)', () async {
    await expectLater(downloadAgentImx(_agent('A1', 'http://example.com/a.imx'), tmp.path),
        throwsA(isA<BithumanAvatarException>()));
  });

  test('a kept file opens at once; the published check runs afterwards, in the background', () async {
    final kept = File('${tmp.path}/A52DHS2219.imx')..writeAsBytesSync(published);
    final d = dl();
    final p = await d.download(_agent('A52DHS2219', door.url('127.0.0.1', '/x').toString()), tmp.path,
        allowedHosts: trustedLoopback);
    expect(p, kept.path);
    expect(door.hits, isEmpty, reason: 'no network before the open');
    await d.refreshing('A52DHS2219');
    expect(door.hits.length, 1, reason: 'asked after the open');
    expect(await kept.readAsBytes(), published, reason: 'same length: kept as is');
  });

  test('a published file of another length is downloaded in the background, for the next open', () async {
    final kept = File('${tmp.path}/A52DHS2219.imx')..writeAsBytesSync(_imx(1100000, 3));
    final d = dl();
    await d.download(_agent('A52DHS2219', door.url('127.0.0.1', '/x').toString()), tmp.path, allowedHosts: trustedLoopback);
    expect(await kept.length(), 1100000, reason: 'this open got the kept file');
    await d.refreshing('A52DHS2219');
    expect(await kept.readAsBytes(), published, reason: 'the next open gets the published one');
  });

  test('a kept Essence 2 file from before the re-publish is fetched again ONCE, stamped now', () async {
    final kept = File('${tmp.path}/A52DHS2219.imx')..writeAsBytesSync(_imx(1100000, 3));
    await kept.setLastModified(DateTime.utc(2026, 9, 30));
    final d = dl();
    final a = _agent('A52DHS2219', door.url('127.0.0.1', '/x').toString());
    await d.download(a, tmp.path, allowedHosts: trustedLoopback);
    expect(await kept.readAsBytes(), published, reason: 'downloaded again before it opened');
    expect((await kept.lastModified()).isBefore(cutoff), isFalse, reason: 'stamped with the current time');
    final hits = storage.hits.length;
    await d.download(a, tmp.path, allowedHosts: trustedLoopback);
    await d.refreshing('A52DHS2219');
    expect(storage.hits.length, hits + 1, reason: 'the next open only checks (one request), no second download');
    expect(await kept.readAsBytes(), published);
  });

  test('the one-time download fails: the kept file opens, untouched', () async {
    final old = _imx(1100000, 3);
    final kept = File('${tmp.path}/A52DHS2219.imx')..writeAsBytesSync(old);
    await kept.setLastModified(DateTime.utc(2026, 9, 30));
    storage.handler = (req) async { req.response.statusCode = 500; await req.response.close(); };
    final p = await dl().download(_agent('A52DHS2219', door.url('127.0.0.1', '/x').toString()), tmp.path,
        allowedHosts: trustedLoopback);
    expect(p, kept.path);
    expect(await kept.readAsBytes(), old);
    expect(File('${kept.path}.partial').existsSync(), isFalse);
  });

  test('no one-time download for a clock before the cutoff, or a family other than Essence 2', () async {
    for (final (now, type) in [(DateTime.utc(2026, 9, 1), 'essence-2'), (after, 'expression-1')]) {
      final old = _imx(1100000, 3);
      final kept = File('${tmp.path}/A1.imx')..writeAsBytesSync(old);
      await kept.setLastModified(DateTime.utc(2026, 9, 30));
      final d = dl(now: now);
      await d.download(_agent('A1', door.url('127.0.0.1', '/x').toString(), modelType: type), tmp.path,
          allowedHosts: trustedLoopback);
      expect(await kept.readAsBytes(), old, reason: 'returned the kept file without downloading ($type, clock $now)');
      await d.refreshing('A1');   // (the background check then sees another length and refreshes it)
      await kept.delete();
    }
  });
}
