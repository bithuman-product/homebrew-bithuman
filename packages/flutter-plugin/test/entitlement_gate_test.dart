// The entitlement gate on this package's own avatar caches (2.6.36, security; lib/src/door_gate.dart).
//
// The gap these arms pin shut: a cache directory belongs to the app, not to an account, and through 2.6.35
// every installer here handed a kept avatar to whoever called next, so account B, signed in where
// account A had opened its PRIVATE avatar, got A's files. The door is owner-scoped: these doors answer
// another account's key with the body bitHuman's door answered on 2026-10-03, byte for byte.
//
// Every cache path is covered: `downloadAgentImx` (the `.imx`), `downloadExpression2Avatar` and
// `downloadExpression2Agent` (the Expression 2 directory), `downloadEssence2Bundle` (the `.elevatedir`).
// Per path: another account is refused after asking the door; the same account opens with the door down
// for 24 h after the door's last yes; a public avatar opens for 7 days; another account with the door
// down is refused (fail closed); a tampered or missing mark makes the door be asked again.
//
// Loopback servers stand in for the door and for storage (plain http, which only a test gate accepts).
// No real network. Apache-2.0; (c) bitHuman.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/src/agent_imx.dart';
import 'package:bithuman/src/door_gate.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'sk_test_owner';
const _other = 'sk_test_other';
const _private = 'A99LTC2401'; // owned by _owner
const _public = 'A52DHS2219'; // the gallery's: served to anyone

// What bitHuman's door answered another account's key for A99LTC2401 on 2026-10-03.
const _notFound = '{"error": {"code": "NOT_FOUND", "message": "Agent not found for code: A99LTC2401", '
    '"httpStatus": 404}, "status": "error", "status_code": 404}';
const _missingAuth = '{"error": {"code": "MISSING_AUTH", "message": "This agent\'s model requires a credential: '
    'send the api-secret header or Authorization: Bearer <api-secret | runtime token>", "httpStatus": 401}, '
    '"status": "error", "status_code": 401}';
const _notReady = '{"error": {"code": "MODEL_ARTIFACT_NOT_READY", "message": "not downloadable yet", '
    '"httpStatus": 404}, "status": "error", "status_code": 404}';

/// A loopback server: [handler] answers; every request's path and key are recorded.
class _Srv {
  _Srv(this.server, this.handler) {
    server.listen((req) async {
      paths.add(req.uri.path);
      keys.add(req.headers.value('api-secret'));
      await handler(req);
    });
  }
  final HttpServer server;
  Future<void> Function(HttpRequest req) handler;
  final paths = <String>[];
  final keys = <String?>[];
  Uri url(String host, String path) => Uri.parse('http://$host:${server.port}$path');
  static Future<_Srv> start(Future<void> Function(HttpRequest) h) async =>
      _Srv(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), h);
}

Future<void> _answer(HttpRequest req, int status, [String body = '']) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(body);
  await req.response.close();
}

/// A port nothing listens on: the door is down.
Future<int> _deadPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Uint8List _imx(int size, int fill) {
  final b = Uint8List(size)..fillRange(0, size, fill);
  b.setRange(0, 3, 'IMX'.codeUnits);
  return b;
}

BithumanAgent _agent(String id, String modelUrl) => BithumanAgent(
    id: id, name: id, description: '', category: '', imageUrl: '', modelUrl: modelUrl,
    systemPrompt: '', voiceId: '', modelType: 'essence-2');

Matcher _refused(bool refused) => throwsA(isA<BithumanEntitlementException>()
    .having((e) => e.refused, 'refused', refused)
    .having((e) => e, 'is a BithumanAvatarException', isA<BithumanAvatarException>()));

/// Every byte under [dir], to prove a credential never reaches the disk.
String _allBytes(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => latin1.decode(f.readAsBytesSync(), allowInvalid: true) + f.path)
    .join('\n');

void main() {
  late Directory tmp;
  late _Srv door, storage;
  late Uint8List published;
  late int dead;
  // The test clock; 2026-10-03 12:00Z unless an arm moves it.
  var now = DateTime.utc(2026, 10, 3, 12);

  /// The owner-scoped door: the owner's key (and anyone, for the public avatar) gets the grant; another
  /// key gets production's 404 NOT_FOUND, no key the 401. [grant] is the yes ('302' or '200').
  late Future<void> Function(HttpRequest, String grant) doorRule;
  Future<void> ownerScoped(HttpRequest req, String grant) async {
    final key = req.headers.value('api-secret');
    final isPublic = req.uri.path.contains('/$_public/');
    if (isPublic || key == _owner) {
      if (grant == '302') {
        await req.response.redirect(storage.url('localhost', '/signed/${req.uri.pathSegments[2]}.imx?t=x'), status: 302);
      } else {
        await _answer(req, 200, jsonEncode({'success': true, 'data': {'url': 'https://example.invalid/x'}}));
      }
      return;
    }
    if (key == null) return _answer(req, 401, _missingAuth);
    return _answer(req, 404, _notFound);
  }

  setUp(() async {
    now = DateTime.utc(2026, 10, 3, 12);
    tmp = await Directory.systemTemp.createTemp('entitlement_gate_test');
    published = _imx(1200000, 7);
    dead = await _deadPort();
    storage = await _Srv.start((req) async {
      req.response.headers.contentLength = published.length;
      req.response.add(published);
      await req.response.close();
    });
    doorRule = ownerScoped;
    door = await _Srv.start((req) => doorRule(req, req.uri.queryParameters['redirect'] == 'false' ? '200' : '302'));
  });

  tearDown(() async {
    await door.server.close(force: true);
    await storage.server.close(force: true);
    await tmp.delete(recursive: true);
  });

  // ───────────────────────────────────────────────── downloadAgentImx (the `.imx`)
  group('downloadAgentImx', () {
    // [up]: the door answers; false: nothing listens where the door should be.
    AgentImxDownloader dl({bool up = true}) => AgentImxDownloader(
        allowInsecure: true,
        clock: () => now,
        doorHosts: const {'127.0.0.1'},
        door: (code) => up
            ? door.url('127.0.0.1', '/v1/agent/$code/model/download')
            : Uri.parse('http://127.0.0.1:$dead/v1/agent/$code/model/download'));
    const allowed = {'127.0.0.1', 'localhost'};
    File kept(String id) => File('${tmp.path}/$id.imx');
    BithumanAgent publicAgent({bool up = true}) => _agent(
        _public,
        up
            ? door.url('127.0.0.1', '/v1/agent/$_public/model/download').toString()
            : 'http://127.0.0.1:$dead/v1/agent/$_public/model/download');

    Future<void> ownerDownloads() async {
      final d = dl();
      await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner);
      expect(await kept(_private).readAsBytes(), published);
    }

    test('another account is refused after ONE door ask; the owner\'s kept file is untouched', () async {
      await ownerDownloads();
      final storageHits = storage.paths.length;
      final d = dl();
      await expectLater(d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(true));
      expect(door.keys, [_owner, _other], reason: 'the owner\'s download, then exactly one ask with the other key');
      expect(storage.paths.length, storageHits, reason: 'nothing fetched for the other account');
      expect(await kept(_private).readAsBytes(), published);
      expect(d.gate.markFile(tmp.path, AgentImxDownloader.markEntry(_private), _other).existsSync(), isFalse);
    });

    test('the owner reopens with the door down for 24 h after the door\'s yes, then fails closed', () async {
      await ownerDownloads();
      now = now.add(const Duration(hours: 23));
      final d = dl(up: false);
      expect(await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path);
      await d.refreshing(_private);
      now = now.add(const Duration(hours: 2)); // 25 h
      await expectLater(d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(false));
      expect(await kept(_private).readAsBytes(), published, reason: 'a refusal never deletes the kept file');
    });

    test('with the door up, a marked owner opens at once and the door\'s yes renews the 24 h', () async {
      await ownerDownloads();
      now = now.add(const Duration(hours: 20));
      final d = dl();
      final asked = door.keys.length;
      await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner);
      await d.refreshing(_private);
      expect(door.keys.length, asked + 1, reason: 'one background ask, after the open');
      now = now.add(const Duration(hours: 20)); // 40 h after the download, 20 h after the renewal
      expect(await dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path);
    });

    test('a public file (served with no credential) opens for ANY credential for 7 days with the door down', () async {
      final p = await dl().download(publicAgent(), tmp.path, allowedHosts: allowed);
      expect(await File(p).readAsBytes(), published);
      expect(door.keys, [null], reason: 'asked with no credential: a yes to that is public');
      now = now.add(const Duration(days: 6));
      final d = dl(up: false);
      expect(await d.download(publicAgent(up: false), tmp.path, allowedHosts: allowed, apiSecret: _other), p);
      await d.refreshing(_public);
      expect(await d.download(publicAgent(up: false), tmp.path, allowedHosts: allowed), p);
      await d.refreshing(_public);
      now = now.add(const Duration(days: 2)); // 8 days
      await expectLater(d.download(publicAgent(up: false), tmp.path, allowedHosts: allowed, apiSecret: _other),
          _refused(false));
    });

    test('door down + another account + a private file: refused, nothing written for it', () async {
      await ownerDownloads();
      final d = dl(up: false);
      await expectLater(d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(false));
      expect(await kept(_private).readAsBytes(), published);
      expect(d.gate.markFile(tmp.path, AgentImxDownloader.markEntry(_private), _other).existsSync(), isFalse);
      // ...and with no credential at all (the owner signed out):
      await expectLater(d.download(_agent(_private, 'http://127.0.0.1:$dead/x'), tmp.path), _refused(false));
    });

    test('a cache from before 2.6.36 (no mark): one door ask, no download; then it is marked', () async {
      kept(_private).writeAsBytesSync(published);
      final d = dl();
      expect(await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path);
      expect(door.keys, [_owner]);
      expect(storage.paths.length, 1, reason: 'the published-length check follows the redirect: headers only');
      expect(await kept(_private).readAsBytes(), published);
      expect(await d.gate.mayOpenWithoutDoor(tmp.path, AgentImxDownloader.markEntry(_private), _owner), isTrue);
      // ...and with the door down instead, the same unmarked cache fails closed for the owner too.
      kept(_public).writeAsBytesSync(published);
      await expectLater(dl(up: false).download(publicAgent(up: false), tmp.path, allowedHosts: allowed, apiSecret: _owner),
          _refused(false));
    });

    test('a tampered, copied, unreadable or future-dated mark counts as none: the door is asked', () async {
      await ownerDownloads();
      final gate = dl().gate;
      final entry = AgentImxDownloader.markEntry(_private);
      final ownerMark = gate.markFile(tmp.path, entry, _owner);
      final original = ownerMark.readAsStringSync();

      // 1. The owner's mark, re-dated to look fresh 25 h later: the seal breaks.
      now = now.add(const Duration(hours: 25));
      final j = jsonDecode(original) as Map<String, dynamic>;
      ownerMark.writeAsStringSync(jsonEncode({...j, 'checked': now.millisecondsSinceEpoch}));
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(false));
      // ...flipped to "public" (7 days): the seal breaks too.
      ownerMark.writeAsStringSync(jsonEncode({...j, 'public': true}));
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(false));
      now = now.subtract(const Duration(hours: 25));

      // 2. The owner's mark copied under the other credential's name: does not verify for it.
      ownerMark.writeAsStringSync(original);
      final copied = gate.markFile(tmp.path, entry, _other)..writeAsStringSync(original);
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(false));
      final asked = door.keys.length;
      await expectLater(dl().download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(true));
      expect(door.keys.sublist(asked), [_other], reason: 'with the door up it was asked, and refused');
      expect(copied.existsSync(), isFalse, reason: 'the refusal dropped what was under the other name');

      // 3. Unreadable.
      ownerMark.writeAsStringSync('not a mark');
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(false));

      // 4. Sealed correctly, but dated a day ahead of the device clock.
      final ahead = DoorGate(clock: () => now.add(const Duration(days: 1)));
      await ahead.noteGranted(tmp.path, entry, _owner);
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(false));

      // 5. Gone: the door is asked, its yes opens, the mark is back.
      ownerMark.deleteSync();
      expect(await dl().download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path);
      expect(ownerMark.existsSync(), isTrue);
    });

    test('a kept file is asked about at the platform door for ITS code, never at the row\'s model_url', () async {
      await ownerDownloads();
      // A catalog row (stale, or tampered in transit) naming the private avatar's code with another,
      // public avatar's door as its model_url, opened with no credential (the owner signed out).
      final crafted = _agent(_private, door.url('127.0.0.1', '/v1/agent/$_public/model/download').toString());
      final asked = door.paths.length;
      await expectLater(dl().download(crafted, tmp.path, allowedHosts: allowed), _refused(true));
      expect(door.paths.sublist(asked), ['/v1/agent/$_private/model/download'],
          reason: 'one ask, at the private avatar\'s own door, with no credential: 401');
      expect(door.keys.last, isNull);
      expect(await kept(_private).readAsBytes(), published, reason: 'kept, not opened, not replaced');
    });

    test('the door refusing the owner later (a revoked key): this open finishes, the next is refused', () async {
      await ownerDownloads();
      doorRule = (req, _) => _answer(req, 401, _missingAuth);
      final d = dl();
      expect(await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path);
      await d.refreshing(_private);
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(false));
      await expectLater(dl().download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), _refused(true));
    });

    test('404 MODEL_ARTIFACT_NOT_READY (the owner\'s re-bake) and a storage 404 behind the redirect are not a no', () async {
      await ownerDownloads();
      doorRule = (req, _) => _answer(req, 404, _notReady);
      final d = dl();
      await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner);
      await d.refreshing(_private);
      doorRule = ownerScoped;
      storage.handler = (req) => _answer(req, 404, '<Error><Code>NoSuchKey</Code></Error>');
      await d.download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner);
      await d.refreshing(_private);
      now = now.add(const Duration(hours: 1));
      expect(await dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _owner), kept(_private).path,
          reason: 'the owner\'s mark survived both');
    });

    test('a kept file from before the re-publish: another account\'s re-download is refused, the kept file not opened', () async {
      await ownerDownloads();
      await kept(_private).setLastModified(DateTime.utc(2026, 9, 30));
      await expectLater(dl().download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(true));
      await expectLater(dl(up: false).download(_agent(_private, 'unused'), tmp.path, apiSecret: _other), _refused(false));
      expect(await kept(_private).readAsBytes(), published);
    });

    test('the mark is a salted hash of the credential (the native stores\' name); the credential is never written', () async {
      await ownerDownloads();
      final mark = dl().gate.markFile(tmp.path, AgentImxDownloader.markEntry(_private), _owner);
      // sha256("bithuman.door.auth.v1\0sk_test_owner")[:32], as essence2-android / expression2-android / Swift compute it.
      expect(credentialTag(_owner), '6aa0c9c2b25dc45d3ab28b9b311939b2');
      expect(credentialTag(null), credentialTag(''));
      expect(mark.path.endsWith('/.door-auth/$_private.imx/${credentialTag(_owner)}'), isTrue);
      expect(_allBytes(tmp).contains(_owner), isFalse);
    });
  });

  // ───────────────────────────────── downloadExpression2Avatar / downloadExpression2Agent (the directory)
  group('Expression 2 installs', () {
    late DoorGate saved;
    setUp(() => saved = entitlementGate);
    tearDown(() => entitlementGate = saved);

    void useGate({bool up = true}) => entitlementGate = DoorGate(
        clock: () => now,
        allowInsecure: true,
        door: (code, model) => up
            ? door.url('127.0.0.1', '/v1/agent/$code/model/download').replace(queryParameters: {'model': model, 'redirect': 'false'})
            : Uri.parse('http://127.0.0.1:$dead/v1/agent/$code/model/download?model=$model&redirect=false'));

    // A complete install, as either installer leaves it.
    String install(String code) {
      for (final m in const [
        'manifest.json',
        'student_v4_forward_frame_cpuAndNE.mlpackage/Manifest.json',
        'audiotokenizer_cpuAndNE.mlpackage/Manifest.json',
        'dec_p2_v3_all.mlpackage/Manifest.json',
        'canon.f32',
      ]) {
        File('${tmp.path}/$code/$m')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      return '${tmp.path}/$code';
    }

    Future<String> avatar(String code, {String? key}) =>
        downloadExpression2Avatar(code, 'https://example.invalid/$code.avatar', tmp.path, apiSecret: key);
    Future<String> legacy(String code, {String? key}) =>
        downloadExpression2Agent(code, 'https://example.invalid/$code.tar.gz', tmp.path, apiSecret: key);

    for (final (name, open) in [('downloadExpression2Avatar', avatar), ('downloadExpression2Agent', legacy)]) {
      group(name, () {
        test('another account is refused after ONE door ask; the owner opens', () async {
          final dir = install(_private);
          useGate();
          await expectLater(open(_private, key: _other), _refused(true));
          expect(door.keys, [_other]);
          expect(door.paths.single, '/v1/agent/$_private/model/download');
          expect(await open(_private, key: _owner), dir);
          expect(Directory(dir).existsSync(), isTrue, reason: 'a refusal never deletes the install');
        });

        test('the owner reopens with the door down for 24 h after the door\'s yes, then fails closed', () async {
          final dir = install(_private);
          useGate();
          expect(await open(_private, key: _owner), dir);
          now = now.add(const Duration(hours: 23));
          useGate(up: false);
          expect(await open(_private, key: _owner), dir);
          await entitlementGate.checking(tmp.path, _private, _owner);
          now = now.add(const Duration(hours: 2));
          await expectLater(open(_private, key: _owner), _refused(false));
        });

        test('a public avatar (a yes with no credential) opens for any account for 7 days with the door down', () async {
          final dir = install(_public);
          useGate();
          expect(await open(_public), dir);
          now = now.add(const Duration(days: 6));
          useGate(up: false);
          expect(await open(_public, key: _other), dir);
          await entitlementGate.checking(tmp.path, _public, _other);
          now = now.add(const Duration(days: 2));
          await expectLater(open(_public, key: _other), _refused(false));
        });

        test('door down + another account + a private install: refused', () async {
          install(_private);
          useGate();
          await open(_private, key: _owner);
          useGate(up: false);
          await expectLater(open(_private, key: _other), _refused(false));
          await expectLater(open(_private), _refused(false));
        });

        test('a tampered or missing mark: the door is asked again', () async {
          final dir = install(_private);
          useGate();
          await open(_private, key: _owner);
          final mark = entitlementGate.markFile(tmp.path, _private, _owner);
          final j = jsonDecode(mark.readAsStringSync()) as Map<String, dynamic>;
          mark.writeAsStringSync(jsonEncode({...j, 'public': true}));
          now = now.add(const Duration(days: 2));
          useGate(up: false);
          await expectLater(open(_private, key: _other), _refused(false), reason: 'not a public mark any more');
          await expectLater(open(_private, key: _owner), _refused(false), reason: 'not the owner\'s either');
          useGate();
          final asked = door.keys.length;
          expect(await open(_private, key: _owner), dir);
          expect(door.keys.length, asked + 1, reason: 'asked before the open');
          mark.deleteSync();
          expect(await open(_private, key: _owner), dir);
          expect(door.keys.length, asked + 2);
        });

        test('nothing is downloaded for a credential the door refuses', () async {
          useGate();
          // The download URL cannot be reached at all: a door refusal is the only way to get THIS exception.
          await expectLater(open(_private, key: _other), _refused(true));
          expect(Directory('${tmp.path}/$_private').existsSync(), isFalse);
          expect(tmp.listSync().where((e) => e.path.endsWith('.partial')), isEmpty);
        });
      });
    }
  });

  // ─────────────────────────────────────────────────────── downloadEssence2Bundle (the `.elevatedir`)
  group('downloadEssence2Bundle', () {
    late DoorGate saved;
    setUp(() => saved = entitlementGate);
    tearDown(() => entitlementGate = saved);

    // The delivery catalog is public: a kept bundle is a public avatar, asked again at its own URL. An
    // https URL on a dead port: the URL cannot be reached.
    Essence2CatalogEntry entry() => Essence2CatalogEntry(
        agentId: 'A23KSG5258', url: 'https://127.0.0.1:$dead/elevate/A23KSG5258.tar.gz', sha256: '', size: 0,
        formatVersion: 'elevatedir-v2');

    test('a kept bundle opens for 7 days after its URL last answered, then fails closed; never without a mark', () async {
      final dir = Directory('${tmp.path}/A23KSG5258.elevatedir')..createSync();
      File('${dir.path}/meta.json').writeAsStringSync('{}');
      entitlementGate = DoorGate(clock: () => now);
      await expectLater(downloadEssence2Bundle(entry(), tmp.path), _refused(false), reason: 'no mark: the URL is asked');
      await entitlementGate.noteGranted(tmp.path, 'A23KSG5258.elevatedir', null);
      now = now.add(const Duration(days: 6));
      expect(await downloadEssence2Bundle(entry(), tmp.path), dir.path);
      await entitlementGate.checking(tmp.path, 'A23KSG5258.elevatedir', null);
      now = now.add(const Duration(days: 2));
      await expectLater(downloadEssence2Bundle(entry(), tmp.path), _refused(false));
    });
  });

  // ─────────────────────────────────────────────────────────────── the door's answers, classified
  group('DoorAnswer', () {
    test('a no is 401, 403, or 404 NOT_FOUND from the host that was asked; nothing else', () async {
      expect(const DoorAnswer(401).denied, isTrue);
      expect(const DoorAnswer(403).denied, isTrue);
      expect(DoorAnswer(404, code: doorErrorCode(_notFound)).denied, isTrue);
      expect(DoorAnswer(404, code: doorErrorCode(_notReady)).denied, isFalse);
      expect(const DoorAnswer(404).denied, isFalse);
      expect(const DoorAnswer(500).denied, isFalse);
      expect(const DoorAnswer(403, answeredByAskedHost: false).denied, isFalse);
      expect(DoorAnswer.unreachable(const SocketException('down')).denied, isFalse);
      expect(const DoorAnswer(302).granted, isTrue);
      expect(const DoorAnswer(200).granted, isTrue);
      expect(const DoorAnswer(404, withdrawn: true).denied, isTrue);
    });

    test('ask: production\'s bodies, the credential in the api-secret header only, and a withdrawn object', () async {
      final g = DoorGate(allowInsecure: true);
      final u = door.url('127.0.0.1', '/v1/agent/$_private/model/download').replace(queryParameters: {'redirect': 'false'});
      expect((await g.ask(u, _owner)).granted, isTrue);
      final no = await g.ask(u, _other);
      expect([no.status, no.code, no.denied], [404, 'NOT_FOUND', isTrue]);
      final anon = await g.ask(u, null);
      expect([anon.status, anon.code, anon.denied], [401, 'MISSING_AUTH', isTrue]);
      expect(door.keys, [_owner, _other, null]);
      doorRule = (req, _) => _answer(req, 404, '<Error><Code>NoSuchKey</Code></Error>');
      expect((await g.ask(u, null)).denied, isFalse, reason: 'a door\'s 404 without NOT_FOUND is not a no');
      expect((await g.ask(u, null, objectStore: true)).denied, isTrue, reason: 'a public object that is gone is');
      expect((await g.ask(Uri.parse('http://127.0.0.1:$dead/x'), _owner)).status, isNull);
      expect((await DoorGate().ask(u, _owner)).status, isNull, reason: 'a real gate refuses a cleartext door');
    });
  });
}
