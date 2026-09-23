// The on-device identity installers hand bitHuman's container to the ENGINE.
//
// ★WHY THIS FILE EXISTS (2.6.11). Until 2.6.10 `downloadExpression2Avatar`
// expanded the container with a reader written in Dart, in this PUBLIC package
// — a second implementation of a proprietary format (owner ruling 2026-09-16:
// closed source, private repositories only). The reader is gone; the engine,
// whose compiled code already reads the container, expands it through the
// platform channel (`unpackModelContainer`). These arms pin that shape:
//
//   * a download that is not a zip reaches the native unpacker, and the Dart
//     side never looks past "is it a zip" (the fixture bytes are deliberately
//     NOT a real container — Dart must not care what they are);
//   * the install is only accepted when the per-identity decoder
//     (`dec_p2_v3_all`) is present — the member whose absence made every
//     gallery identity install and then render nothing (2026-09-23);
//   * an earlier install without that decoder is fetched again, not re-used;
//   * a platform whose engine cannot expand a container says so by name;
//   * `downloadAgentImx` asks the engine whether a file is a container instead
//     of comparing magic bytes itself.
//
// No network: dart:io's HttpClient is replaced for the zone, and the platform
// channel is mocked. Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bithuman/bithuman.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('ai.bithuman.avatar');
const _host = 'example.invalid';
const _decoder = 'dec_p2_v3_all.mlpackage/Manifest.json';

/// The members a complete expression-2 identity expands to.
const _complete = <String>[
  'manifest.json',
  'student_v4_forward_frame_cpuAndNE.mlpackage/Manifest.json',
  'audiotokenizer_cpuAndNE.mlpackage/Manifest.json',
  _decoder,
  'canon.f32',
];

void _write(String dir, Iterable<String> members) {
  for (final m in members) {
    final f = File('$dir/$m')..createSync(recursive: true);
    f.writeAsStringSync(m == 'manifest.json'
        ? jsonEncode({'format': 'embody-avatar/1', 'requires_engine_abi': 1})
        : 'x');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late List<MethodCall> calls;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bh_install_');
    calls = <MethodCall>[];
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The engine, mocked: `unpackModelContainer` writes [members] into `dir`.
  void engineUnpacks(List<String> members, {bool? isContainer}) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'unpackModelContainer':
          _write((call.arguments as Map)['dir'] as String, members);
          return members.length;
        case 'isModelContainer':
          return isContainer;
      }
      return null;
    });
  }

  Future<T> withBody<T>(List<int> body, Future<T> Function() fn) =>
      HttpOverrides.runZoned(fn, createHttpClient: (_) => _FakeClient(body));

  // Deliberately not a container: the Dart side must hand over anything that
  // is not a zip without reading it.
  final notAZip = utf8.encode('opaque identity bytes, not a zip');

  group('downloadExpression2Avatar', () {
    test('a non-zip download is expanded by the engine, not parsed in Dart', () async {
      engineUnpacks(_complete);
      final dir = await withBody(notAZip, () => downloadExpression2Avatar(
          'A00EXAMPLE', 'https://$_host/A00EXAMPLE.avatar', tmp.path,
          allowedHosts: const {_host}));
      expect(dir, '${tmp.path}/A00EXAMPLE');
      final unpack = calls.where((c) => c.method == 'unpackModelContainer').toList();
      expect(unpack, hasLength(1));
      final args = unpack.single.arguments as Map;
      expect(args['path'], '${tmp.path}/A00EXAMPLE.avatar.partial');
      expect(args['dir'], '${tmp.path}/A00EXAMPLE.tmp');
      expect(File('$dir/$_decoder').existsSync(), isTrue);
      expect(File('${tmp.path}/A00EXAMPLE.avatar.partial').existsSync(), isFalse,
          reason: 'the download is removed once installed');
    });

    test('an identity without dec_p2_v3_all is refused at install', () async {
      engineUnpacks(_complete.where((m) => m != _decoder).toList());
      await expectLater(
        withBody(notAZip, () => downloadExpression2Avatar(
            'A00EXAMPLE', 'https://$_host/A00EXAMPLE.avatar', tmp.path,
            allowedHosts: const {_host})),
        throwsA(isA<BithumanAvatarException>()
            .having((e) => e.toString(), 'message', contains('dec_p2_v3_all'))),
      );
      expect(Directory('${tmp.path}/A00EXAMPLE').existsSync(), isFalse,
          reason: 'a refused identity is never installed');
    });

    test('an earlier install without the decoder is fetched again', () async {
      _write('${tmp.path}/A00EXAMPLE', _complete.where((m) => m != _decoder));
      engineUnpacks(_complete);
      final dir = await withBody(notAZip, () => downloadExpression2Avatar(
          'A00EXAMPLE', 'https://$_host/A00EXAMPLE.avatar', tmp.path,
          allowedHosts: const {_host}));
      expect(calls.where((c) => c.method == 'unpackModelContainer'), hasLength(1));
      expect(File('$dir/$_decoder').existsSync(), isTrue);
    });

    test('a complete install is re-used with no download', () async {
      _write('${tmp.path}/A00EXAMPLE', _complete);
      engineUnpacks(_complete);
      final dir = await HttpOverrides.runZoned(
          () => downloadExpression2Avatar(
              'A00EXAMPLE', 'https://$_host/A00EXAMPLE.avatar', tmp.path,
              allowedHosts: const {_host}),
          createHttpClient: (_) => throw StateError('must not download'));
      expect(dir, '${tmp.path}/A00EXAMPLE');
      expect(calls, isEmpty);
    });

    test('a platform whose engine cannot expand the container says so', () async {
      // No handler at all: the channel answers MissingPluginException.
      await expectLater(
        withBody(notAZip, () => downloadExpression2Avatar(
            'A00EXAMPLE', 'https://$_host/A00EXAMPLE.avatar', tmp.path,
            allowedHosts: const {_host})),
        throwsA(isA<BithumanAvatarException>()
            .having((e) => e.toString(), 'message', contains('does not expand'))),
      );
    });
  });

  group('downloadAgentImx asks the engine, not the bytes', () {
    const agent = BithumanAgent(
      id: 'A00EXAMPLE',
      name: 'Example',
      description: '',
      category: '',
      imageUrl: '',
      modelUrl: 'https://$_host/A00EXAMPLE.imx',
      systemPrompt: '',
      voiceId: '',
    );
    final big = List<int>.filled((1 << 20) + 64, 7); // passes the size floor

    test('the engine says not a container: refused and removed', () async {
      engineUnpacks(const [], isContainer: false);
      await expectLater(
        withBody(big, () => downloadAgentImx(agent, tmp.path, allowedHosts: const {_host})),
        throwsA(isA<BithumanAvatarException>()),
      );
      expect(File('${tmp.path}/A00EXAMPLE.imx').existsSync(), isFalse);
      expect(calls.single.method, 'isModelContainer');
    });

    test('the engine says container: kept', () async {
      engineUnpacks(const [], isContainer: true);
      final path = await withBody(
          big, () => downloadAgentImx(agent, tmp.path, allowedHosts: const {_host}));
      expect(path, '${tmp.path}/A00EXAMPLE.imx');
      expect(File(path).lengthSync(), big.length);
    });

    test('an engine that cannot tell leaves the verdict to the load', () async {
      final path = await withBody(
          big, () => downloadAgentImx(agent, tmp.path, allowedHosts: const {_host}));
      expect(File(path).existsSync(), isTrue);
    });
  });
}

// ── a dart:io HttpClient that serves one body ────────────────────────────────

class _FakeClient implements HttpClient {
  _FakeClient(this.body);
  final List<int> body;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(body);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.body);
  final List<int> body;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => _FakeResponse(body);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.body);
  final List<int> body;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => body.length;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.fromIterable([body]).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
