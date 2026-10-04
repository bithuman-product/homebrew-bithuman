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
}
