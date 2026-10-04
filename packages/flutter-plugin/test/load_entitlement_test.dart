// BithumanAvatar.load and the entitlement gate (2.6.36, security; PR #202 review).
//
// * A path one of this package's installers returned (`<cacheDir>/<id>.imx`, `<cacheDir>/<code>/`,
//   `<cacheDir>/<id>.elevatedir`) opens only as the installer would open it, for THIS load's credential:
//   an app that saved the path and hands it to `load` later never skips the gate. An app's own file
//   (no `.door-auth/` beside it) is not gated, and an Android code is the native store's to gate.
// * Android's entitlement window answers `entitlement_refused` / `entitlement_unconfirmed`: both are the
//   installers' BithumanEntitlementException.
// * `clearCredentials` reaches the native side (sign-out).
//
// A loopback server stands in for bitHuman's owner-scoped door; a mock channel for the engines.
// Apache-2.0; (c) bitHuman.

import 'dart:io';

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/src/door_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'sk_test_owner';
const _other = 'sk_test_other';
const _private = 'A99LTC2401';
const _notFound = '{"error": {"code": "NOT_FOUND", "message": "Agent not found for code: A99LTC2401", '
    '"httpStatus": 404}, "status": "error", "status_code": 404}';

const _avatar = MethodChannel('ai.bithuman.avatar');
TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

Matcher _refused(bool refused) =>
    throwsA(isA<BithumanEntitlementException>().having((e) => e.refused, 'refused', refused));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer door;
  late Directory tmp;
  late DoorGate saved;
  late int dead;
  final calls = <MethodCall>[];
  final asked = <String?>[];
  var now = DateTime.utc(2026, 10, 3, 12);
  Object? loadFails;

  setUpAll(() => HttpOverrides.global = null); // real loopback sockets (the test binding mocks HttpClient)

  setUp(() async {
    now = DateTime.utc(2026, 10, 3, 12);
    calls.clear();
    asked.clear();
    loadFails = null;
    tmp = await Directory.systemTemp.createTemp('load_entitlement_test');
    door = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    door.listen((req) async {
      final key = req.headers.value('api-secret');
      asked.add(key);
      req.response.headers.contentType = ContentType.json;
      if (key == _owner) {
        req.response.write('{"success": true, "data": {"url": "https://example.invalid/x"}}');
      } else {
        req.response.statusCode = key == null ? 401 : 404;
        req.response.write(key == null ? '{"error": {"code": "MISSING_AUTH"}}' : _notFound);
      }
      await req.response.close();
    });
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    dead = s.port;
    await s.close();
    saved = entitlementGate;
    _messenger.setMockMethodCallHandler(_avatar, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'load':
          final f = loadFails;
          if (f != null) throw f;
          return 7;
        case 'frameSize':
          return {'width': 416, 'height': 720};
        case 'isReady':
          return true;
      }
      return null;
    });
  });

  tearDown(() async {
    entitlementGate = saved;
    await BithumanAvatar.setExpression2AgentDir(null);
    _messenger.setMockMethodCallHandler(_avatar, null);
    await door.close(force: true);
    await tmp.delete(recursive: true);
  });

  void useGate({bool up = true}) => entitlementGate = DoorGate(
      clock: () => now,
      allowInsecure: true,
      door: (code, model) => Uri.parse('http://127.0.0.1:${up ? door.port : dead}/v1/agent/$code/model/download')
          .replace(queryParameters: {if (model.isNotEmpty) 'model': model, 'redirect': 'false'}));

  /// A kept install as an installer leaves it: the file or directory, and the owner's mark beside it.
  Future<String> kept(String name, {bool dir = false}) async {
    final path = '${tmp.path}/$name';
    if (dir) {
      Directory(path).createSync();
    } else {
      File(path).writeAsBytesSync([1, 2, 3]);
    }
    await entitlementGate.noteGranted(tmp.path, name, _owner);
    return path;
  }

  bool loaded() => calls.any((c) => c.method == 'load');

  test('a saved installer path opens for another account only after the door\'s yes: never here', () async {
    useGate();
    final imx = await kept('$_private.imx');
    await expectLater(BithumanAvatar.load(imx, engine: 'essence2', apiSecret: _other), _refused(true));
    await expectLater(BithumanAvatar.load(imx, engine: 'essence2'), _refused(true));
    expect(loaded(), isFalse, reason: 'refused before the engine is asked to load anything');
    expect(asked, [_other, null]);
    useGate(up: false);
    await expectLater(BithumanAvatar.load(imx, engine: 'essence2', apiSecret: _other), _refused(false));
    expect(loaded(), isFalse);
    // The owner, door down, inside 24 h of the door's yes: loads, with no network first.
    final a = await BithumanAvatar.load(imx, engine: 'essence2', apiSecret: _owner);
    expect(a.textureId, 7);
    expect(asked, [_other, null]);
    await a.dispose();
    // 25 h later, door down: the owner fails closed too.
    now = now.add(const Duration(hours: 25));
    await expectLater(BithumanAvatar.load(imx, engine: 'essence2', apiSecret: _owner), _refused(false));
  });

  test('every installer\'s path shape is gated (.imx, .elevatedir, an Expression 2 dir and agent dir)', () async {
    useGate();
    final bundle = await kept('$_private.elevatedir', dir: true);
    final x2 = await kept(_private, dir: true);
    await expectLater(BithumanAvatar.load(bundle, engine: 'essence2', apiSecret: _other), _refused(true));
    await expectLater(BithumanAvatar.load('$x2/', engine: 'expression2', apiSecret: _other), _refused(true));
    // The agent dir set for the next Expression 2 load is gated like the path.
    await BithumanAvatar.setExpression2AgentDir(x2);
    await expectLater(BithumanAvatar.load('${tmp.path}/../elsewhere.imx', apiSecret: _other), _refused(true));
    expect(loaded(), isFalse);
    final a = await BithumanAvatar.load(x2, apiSecret: _owner);
    await a.dispose();
  });

  test('an app\'s own file and an Android code are not gated here', () async {
    useGate(up: false);
    final own = Directory('${tmp.path}/app_store')..createSync();
    final f = File('${own.path}/$_private.imx')..writeAsBytesSync([1]);
    final a = await BithumanAvatar.load(f.path, engine: 'essence2', apiSecret: _other);
    final b = await BithumanAvatar.load(_private, engine: 'essence2', apiSecret: _other);
    expect(asked, isEmpty);
    expect(calls.where((c) => c.method == 'load').length, 2);
    await a.dispose();
    await b.dispose();
  });

  test('Android\'s entitlement window: entitlement_refused / entitlement_unconfirmed are BithumanEntitlementException', () async {
    useGate();
    loadFails = PlatformException(code: 'entitlement_refused', message: 'essence-2:$_private: refused', details: 404);
    await expectLater(
        BithumanAvatar.load(_private, engine: 'essence2', apiSecret: _other),
        throwsA(isA<BithumanEntitlementException>()
            .having((e) => e.refused, 'refused', isTrue)
            .having((e) => e.status, 'status', 404)));
    loadFails = PlatformException(code: 'entitlement_unconfirmed', message: 'offline');
    await expectLater(BithumanAvatar.load(_private, engine: 'essence2', apiSecret: _owner), _refused(false));
  });

  test('clearCredentials reaches the native side', () async {
    await BithumanAvatar.clearCredentials();
    expect(calls.map((c) => c.method), ['clearCredentials']);
  });

  // ── PR #202 round 3 ────────────────────────────────────────────────────────────────────────────────────
  Map<Object?, Object?> lastLoad() => calls.lastWhere((c) => c.method == 'load').arguments as Map<Object?, Object?>;

  test('round 3: no other spelling of a kept install escapes the gate (dot segments, //, sub/.., a symlink, '
      'a file inside one)', () async {
    useGate();
    final x2 = await kept(_private, dir: true);
    Directory('$x2/sub').createSync();
    final bundle = await kept('$_private.elevatedir', dir: true);
    File('$bundle/meta.json').writeAsStringSync('{}');
    final imx = await kept('A11IMX0001.imx');
    final outside = await Directory.systemTemp.createTemp('load_alias');
    addTearDown(() => outside.delete(recursive: true));
    final link = Link('${outside.path}/my_avatar')..createSync(x2);
    final imxLink = Link('${outside.path}/my.imx')..createSync(imx);
    final name = tmp.path.split('/').last;
    for (final p in [
      '$x2/.',
      '$x2/./',
      '$x2/sub/..',
      '$x2/no_such_dir/..',
      '$x2//.',
      '${tmp.path}//$_private',
      '${tmp.path}/./$_private',
      '${tmp.path}/../$name/$_private',
      '$bundle/.',
      '$bundle/meta.json',
      link.path,
      '${link.path}/.',
      '${link.path}/sub/..',
      imxLink.path,
    ]) {
      await expectLater(BithumanAvatar.load(p, engine: 'essence2', apiSecret: _other), _refused(true), reason: p);
    }
    // The agent dir Expression 2 renders on iOS / macOS, under another spelling.
    await BithumanAvatar.setExpression2AgentDir('$x2/.');
    await expectLater(BithumanAvatar.load('${outside.path}/app.imx', apiSecret: _other), _refused(true));
    await BithumanAvatar.setExpression2AgentDir(link.path);
    await expectLater(BithumanAvatar.load('${outside.path}/app.imx', apiSecret: _other), _refused(true));
    expect(loaded(), isFalse, reason: 'every spelling refused before the engine is asked to load anything');
    // The package's own marks are never a path to load.
    await expectLater(BithumanAvatar.load('${tmp.path}/.door-auth', engine: 'essence2', apiSecret: _owner), _refused(false));
    // The owner opens through any spelling (its fresh mark), with the door down.
    useGate(up: false);
    await BithumanAvatar.setExpression2AgentDir(null);
    final a = await BithumanAvatar.load('${link.path}/./', apiSecret: _owner);
    await a.dispose();
    final b = await BithumanAvatar.load('$bundle/.', engine: 'essence2', apiSecret: _owner);
    await b.dispose();
  });

  test('round 3: the canonical path folds what the file system folds', () async {
    final x = Directory('${tmp.path}/x/y')..createSync(recursive: true);
    final real = x.resolveSymbolicLinksSync();
    expect(DoorGate.canonicalPath('${x.path}/.'), real);
    expect(DoorGate.canonicalPath('${x.path}/../y/./'), real);
    expect(DoorGate.canonicalPath('${x.path}//'), real);
    expect(DoorGate.canonicalPath('${x.path}/nothing/../'), real, reason: 'a missing component is folded lexically');
    expect(DoorGate.canonicalPath('${x.path}/nothing/file.imx'), '$real/nothing/file.imx');
  });

  test('round 3: Expression 2 sends the agent dir Dart gated with the load; clearCredentials forgets it', () async {
    useGate();
    final x2 = await kept(_private, dir: true);
    await BithumanAvatar.setExpression2AgentDir(x2);
    final a = await BithumanAvatar.load('bundled', apiSecret: _owner);
    expect(lastLoad()['agentDir'], x2, reason: 'the native side renders the dir that was gated, not its own copy');
    await a.dispose();
    await BithumanAvatar.clearCredentials();
    final b = await BithumanAvatar.load('bundled', engine: 'expression-2', apiSecret: _other);
    expect(lastLoad()['agentDir'], '',
        reason: 'after sign-out the bundled default: the signed-out account\'s dir is never rendered');
    await b.dispose();
    final e = await BithumanAvatar.load(_private, engine: 'essence2', apiSecret: _other);
    expect(lastLoad().containsKey('agentDir'), isFalse, reason: 'Essence 2 renders its own path only');
    await e.dispose();
    expect(asked, isEmpty, reason: 'the owner\'s fresh mark opened its agent dir with no door ask');
  });

  test('round 3: a kept .imx is the container door\'s alone (no member-door ask)', () async {
    final memberAsked = <String>[];
    entitlementGate = DoorGate(
        clock: () => now,
        allowInsecure: true,
        door: (code, model) => Uri.parse('http://127.0.0.1:${door.port}/v1/agent/$code/model/download')
            .replace(queryParameters: {if (model.isNotEmpty) 'model': model, 'redirect': 'false'}),
        publicDoor: (code, family) {
          memberAsked.add(family);
          return Uri.parse('http://127.0.0.1:${door.port}/v1/agent/$code/model/download?member=x');
        });
    final imx = await kept('$_private.imx');
    await expectLater(BithumanAvatar.load(imx, engine: 'essence2', apiSecret: _other), _refused(true));
    expect(memberAsked, isEmpty);
    expect(asked, [_other], reason: 'one ask: the container door');
    final x2 = await kept(_private, dir: true);
    await expectLater(BithumanAvatar.load(x2, apiSecret: _other), _refused(true));
    expect(memberAsked, ['expression-2']);
    expect(asked, [_other, _other, _other], reason: 'an Expression 2 install: the container door, then the member door');
  });
}
