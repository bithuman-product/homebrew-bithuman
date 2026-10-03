// The entitlement gate on this package's own avatar caches (2.6.36, security).
//
// THE GAP (found 2026-10-03). A cache directory belongs to the APP, not to an account. Through 2.6.35
// every installer here returned a kept avatar AT ONCE to whoever called next: `downloadAgentImx` its
// `<cacheDir>/<id>.imx`, `downloadExpression2Avatar` / `downloadExpression2Agent` their
// `<cacheDir>/<code>/`, `downloadEssence2Bundle` its `<cacheDir>/<id>.elevatedir/`. So after account A
// opened its PRIVATE avatar, account B on the same device (a sign-out and sign-in, as bitHuman Live
// allows) was handed A's files. bitHuman's door is owner-scoped (it answers B 404 "Agent not found") but
// was never asked before a kept file opened, and the session meter checks the key, not the avatar.
//
// THE GATE: the same model as the native stores' fix (essence2-android 0.9.4, expression2-android 0.6.0,
// Essence2Kit and Expression2Download in Swift 2.20.2):
//  * A kept avatar opens only for a credential that holds an ENTITLEMENT MARK for it:
//    `<cacheDir>/.door-auth/<entry>/<tag>`, where <tag> is the native stores' credential tag (32 hex
//    of SHA-256 over "bithuman.door.auth.v1\0" + the credential, "" without one; the Swift stores hash
//    the credential itself, as here, the Android stores their canonical request headers). The marks
//    live in this package's own cache directory, never in a native store's. The credential itself is
//    never written.
//  * The door's yes (2xx, or the 3xx to the signed file URL) to a request that carried exactly that
//    credential writes the mark. The door's no drops it: 401, 403, or 404 with error.code NOT_FOUND,
//    answered by the host that was asked. NOT a no: 404 MODEL_ARTIFACT_NOT_READY (the owner's re-bake or
//    publish window), any 5xx, a storage host's answer behind the door's redirect, an outage.
//  * No mark (or a stale, tampered or foreign one): the door is asked FIRST, and the call fails unless
//    it says yes, both on a refusal and on a door that cannot be asked (fail closed). The kept files
//    stay (they may be another account's), and nothing is downloaded again when the door says yes.
//  * A mark opens AT ONCE, with no network before the open (the Live rule), and the door is asked
//    in the background. Its refusal drops the mark: the open under way finishes, the next one is refused.
//
// OFFLINE (owner rules, 2026-10-03). Stricter than the native marks, which do not expire:
//  * an account reopens ITS OWN avatar with the door down for up to 24 h after the door last said
//    yes to its credential;
//  * a PUBLIC avatar (one the door served to a request with NO credential) opens for any credential
//    for up to 7 days after that yes: anyone can download it again. The door's 404 NOT_FOUND to ANY
//    credential drops it at once (the door serves a public avatar to every credential, so the avatar
//    was made private or deleted): the open under way finishes, the next one asks the door;
//  * past that, the door is asked, and a door that cannot be asked fails the call.
//
// TAMPER. A mark holds the time of the door's yes and whether it was public, sealed with an HMAC-SHA256
// keyed by the credential (a different salt from the tag's; the credential is never stored). A mark
// copied to another credential's name or another avatar, edited (a later time, "public"), unreadable,
// or dated more than five minutes ahead of the device clock does not verify and counts as no mark: the
// door is asked. A public mark is keyed by the empty credential, so anyone who can write the app's
// cache directory can write one; such a writer can read the avatar's files directly anyway, and the gate
// is about this package never handing them out by itself.
//
// Apache-2.0; (c) bitHuman.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../bithuman.dart' show BithumanAvatarException;

/// A kept (or downloadable) avatar the current credential may not open (2.6.36, security).
///
/// [refused] true: bitHuman's door refused this credential for this avatar (401, 403, or 404
/// `NOT_FOUND`: the avatar is private to another account, or the key is revoked). Do not retry with
/// the same credential.
///
/// [refused] false: the door could not be asked (offline, a timeout, a 5xx, or 404
/// `MODEL_ARTIFACT_NOT_READY`) and this credential holds no entitlement for the kept copy that is
/// recent enough: 24 h after the door last said yes for an account's own avatar, 7 days for a public
/// one. Retry once the device is online.
class BithumanEntitlementException extends BithumanAvatarException {
  const BithumanEntitlementException(super.message, {required this.refused, this.status});

  /// True when the door said no; false when it could not be asked.
  final bool refused;

  /// The door's HTTP status, when it answered.
  final int? status;

  @override
  String toString() => 'BithumanEntitlementException: $message';
}

/// The native stores' credential tag (Essence2Kit / Expression2Download `credentialTag`): 32 hex of
/// SHA-256 over a fixed salt + the credential ("" when there is none). Never the credential.
String credentialTag(String? credential) =>
    sha256.convert(utf8.encode('bithuman.door.auth.v1\u0000${credential ?? ''}')).toString().substring(0, 32);

/// What the door answered ONE request, or that it could not be asked.
class DoorAnswer {
  const DoorAnswer(this.status, {this.code, this.answeredByAskedHost = true, this.withdrawn = false}) : error = null;
  const DoorAnswer.unreachable(Object this.error)
      : status = null,
        code = null,
        answeredByAskedHost = false,
        withdrawn = false;

  /// The HTTP status; null when the door could not be asked.
  final int? status;

  /// `error.code` of the door's body (`NOT_FOUND`, `MODEL_ARTIFACT_NOT_READY`, ...), when it sent one.
  final String? code;

  /// False when the answer came from a host the door redirected to (a storage host's 403/404 is not
  /// the door refusing the credential).
  final bool answeredByAskedHost;

  /// Why the door could not be asked.
  final Object? error;

  /// A public object URL answered 403/404/410: the object was withdrawn, a no for everyone.
  final bool withdrawn;

  /// The door said yes to this credential: 2xx, or its redirect to the signed file URL.
  bool get granted => status != null && answeredByAskedHost && status! >= 200 && status! < 400;

  /// The door said no to this credential: 401/403, or 404 NOT_FOUND ("Agent not found"), from the
  /// host that was asked.
  bool get denied =>
      status != null &&
      answeredByAskedHost &&
      (withdrawn || status == 401 || status == 403 || (status == 404 && code == 'NOT_FOUND'));

  @override
  String toString() =>
      status == null
          ? 'no answer ($error)'
          : 'HTTP $status${code == null ? '' : ' $code'}${withdrawn ? ' (withdrawn)' : ''}'
              '${answeredByAskedHost ? '' : ' (behind a redirect)'}';
}

/// `error.code` of a door error body (`{"error": {"code": "NOT_FOUND", ...}}`), or null.
String? doorErrorCode(String body) => RegExp(r'"code"\s*:\s*"([A-Za-z0-9_]+)"').firstMatch(body)?.group(1);

/// At most [max] bytes of [s] as text (an error body), then the rest is dropped.
Future<String> readHead(Stream<List<int>> s, int max) async {
  final out = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  sub = s.listen((b) {
    out.addAll(b);
    if (out.length >= max) {
      unawaited(sub.cancel());
      finish();
    }
  }, onError: (Object _) => finish(), onDone: finish, cancelOnError: true);
  await done.future;
  return utf8.decode(out.length > max ? out.sublist(0, max) : out, allowMalformed: true);
}

/// What a mark says, once it verifies.
class _Mark {
  const _Mark(this.checked, this.public);
  final DateTime checked;
  final bool public;
}

/// The marks, the door ask, and the open/admit rules every installer here goes through.
class DoorGate {
  DoorGate({
    DateTime Function()? clock,
    Uri Function(String code, String model)? door,
    this.allowInsecure = false,
    this.timeout = const Duration(seconds: 20),
    this.log,
  })  : clock = clock ?? DateTime.now,
        door = door ?? bithumanEntitlementDoor;

  final DateTime Function() clock;

  /// The platform door for an agent code and model family (`?redirect=false`: a JSON grant, no file).
  final Uri Function(String code, String model) door;

  /// Tests only: plain-http loopback doors.
  final bool allowInsecure;

  /// How long one door ask may take.
  final Duration timeout;
  final void Function(String line)? log;

  /// An account's own avatar: how long after the door's last yes it opens with the door down.
  static const Duration ownWindow = Duration(hours: 24);

  /// A public avatar: the same, for any credential.
  static const Duration publicWindow = Duration(days: 7);

  /// A mark dated further ahead of the device clock than this is not believed.
  static const Duration futureSkew = Duration(minutes: 5);

  static const String _dir = '.door-auth';

  final Map<String, Future<void>> _checking = {};

  /// The background door check for ([cacheDir], [entry], [credential]) under way, if any.
  @visibleForTesting
  Future<void>? checking(String cacheDir, String entry, String? credential) =>
      _checking[_key(cacheDir, entry, credential)];

  static String? _norm(String? credential) => (credential == null || credential.isEmpty) ? null : credential;
  String _key(String cacheDir, String entry, String? credential) => '$cacheDir|$entry|${credentialTag(_norm(credential))}';

  /// Where [credential]'s mark for [entry] lives.
  @visibleForTesting
  File markFile(String cacheDir, String entry, String? credential) =>
      File('$cacheDir/$_dir/$entry/${credentialTag(_norm(credential))}');

  static String _seal(String? credential, String entry, String tag, int checkedMs, bool public) => Hmac(
          sha256, utf8.encode('bithuman.door.mark.v1\u0000${credential ?? ''}'))
      .convert(utf8.encode('v1\n$entry\n$tag\n$checkedMs\n${public ? 1 : 0}'))
      .toString();

  /// [credential]'s mark for [entry], if it verifies. Anything else (absent, unreadable, another
  /// credential's or avatar's, edited, dated in the future) is null: no mark.
  Future<_Mark?> _read(String cacheDir, String entry, String? credential) async {
    final c = _norm(credential);
    final tag = credentialTag(c);
    try {
      final f = File('$cacheDir/$_dir/$entry/$tag');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final checked = j['checked'], public = j['public'], mac = j['mac'];
      if (j['v'] != 1 || j['entry'] != entry || j['tag'] != tag || checked is! int || public is! bool || mac is! String) {
        return null;
      }
      final want = _seal(c, entry, tag, checked, public);
      if (!_sameHex(want, mac)) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(checked, isUtc: true);
      if (at.isAfter(clock().toUtc().add(futureSkew))) return null;
      return _Mark(at, public);
    } catch (_) {
      return null;
    }
  }

  static bool _sameHex(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  bool _fresh(_Mark m) => clock().toUtc().difference(m.checked) <= (m.public ? publicWindow : ownWindow);

  /// May [credential] open the kept [entry] now WITHOUT asking the door? Its own mark within its window
  /// (24 h, or 7 days for a public one), or a public mark any request with no credential earned within
  /// 7 days.
  Future<bool> mayOpenWithoutDoor(String cacheDir, String entry, String? credential) async {
    final own = await _read(cacheDir, entry, credential);
    if (own != null && _fresh(own)) return true;
    if (_norm(credential) == null) return false;
    final pub = await _read(cacheDir, entry, null);
    return pub != null && pub.public && _fresh(pub);
  }

  /// The door said yes to [credential] for [entry] just now: write (or refresh) its mark. A yes to a
  /// request with no credential is a PUBLIC mark (7 days, for anyone). Best effort: a mark that cannot be
  /// written means the next open asks.
  Future<void> noteGranted(String cacheDir, String entry, String? credential) async {
    final c = _norm(credential);
    final tag = credentialTag(c);
    final public = c == null;
    final at = clock().toUtc().millisecondsSinceEpoch;
    try {
      final d = Directory('$cacheDir/$_dir/$entry');
      await d.create(recursive: true);
      final tmp = File('${d.path}/$tag.tmp');
      await tmp.writeAsString(jsonEncode({
        'v': 1,
        'entry': entry,
        'tag': tag,
        'checked': at,
        'public': public,
        'mac': _seal(c, entry, tag, at, public),
      }), flush: true);
      await tmp.rename('${d.path}/$tag');
    } catch (e) {
      log?.call('door-auth:$entry could not write the mark ($e); the next open asks the door');
    }
  }

  /// The door said no to [credential] for [entry]: drop its mark (never creates anything).
  Future<void> noteDenied(String cacheDir, String entry, String? credential) async {
    try {
      final f = markFile(cacheDir, entry, credential);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Applies the door's [answer] to [credential]'s mark for [entry].
  ///
  /// A 404 `NOT_FOUND` (or a withdrawn object) also drops [entry]'s PUBLIC mark, whoever asked: the door
  /// serves a public avatar to any credential (a credentialed non-owner falls through to its anonymous
  /// arm), so "not found" for one credential means the avatar is not public now (made private, deleted).
  /// Without this a public mark earned before the owner made the avatar private would keep opening the
  /// kept copy for other accounts until its 7 days ran out. A 401 / 403 is about the credential (a revoked
  /// key), not the avatar: the public mark stays.
  Future<void> note(String cacheDir, String entry, String? credential, DoorAnswer answer) async {
    if (answer.granted) {
      await noteGranted(cacheDir, entry, credential);
    } else if (answer.denied) {
      await noteDenied(cacheDir, entry, credential);
      if (_norm(credential) != null && (answer.withdrawn || answer.status == 404)) {
        await noteDenied(cacheDir, entry, null);
      }
    }
  }

  /// One GET of [u] carrying exactly [credential] (the `api-secret` header), redirects NOT followed:
  /// the first host's answer. [objectStore]: [u] is a public object URL, not a door, asked with HEAD; its
  /// 403/404/410 means the object was withdrawn (a no for everyone). Never throws.
  Future<DoorAnswer> ask(Uri u, String? credential, {bool objectStore = false}) async {
    if (!(u.scheme == 'https' || (allowInsecure && u.scheme == 'http'))) {
      return DoorAnswer.unreachable(BithumanAvatarException('refusing a non-https door: $u'));
    }
    final c = _norm(credential);
    HttpClient? client;
    try {
      return await () async {
        client = HttpClient();
        // A public object is asked with HEAD: its status is the answer, and a GET would start the file.
        final req = objectStore ? await client!.headUrl(u) : await client!.getUrl(u);
        req.followRedirects = false;
        if (c != null) req.headers.set('api-secret', c);
        final res = await req.close();
        final status = res.statusCode;
        String? code;
        if (!objectStore && (status == 404 || status == 401 || status == 403)) {
          code = doorErrorCode(await readHead(res, 4096));
        } else {
          await res.listen((_) {}).cancel();   // the status is the answer: never the file
        }
        return DoorAnswer(status,
            code: code, withdrawn: objectStore && (status == 403 || status == 404 || status == 410));
      }()
          .timeout(timeout);
    } catch (e) {
      return DoorAnswer.unreachable(e);
    } finally {
      client?.close(force: true);
    }
  }

  /// The rule for a KEPT copy whose door is a separate request ([doorUrl]): returns when [credential]
  /// may open it, throws [BithumanEntitlementException] when it may not. With a fresh mark the open is
  /// immediate and the door is asked in the background; without one the door is asked first.
  Future<void> openKept(String cacheDir, String entry, Uri doorUrl, String? credential,
      {required String what, bool objectStore = false}) async {
    if (await mayOpenWithoutDoor(cacheDir, entry, credential)) {
      _checkLater(cacheDir, entry, doorUrl, credential, what: what, objectStore: objectStore);
      return;
    }
    final a = await ask(doorUrl, credential, objectStore: objectStore);
    await note(cacheDir, entry, credential, a);
    if (a.granted) return;
    throw refusal(what, a, kept: true);
  }

  /// Before a download whose bytes come from somewhere other than the door: the door says yes to
  /// [credential] first (and its mark is written), or the call fails and nothing is downloaded.
  Future<void> admit(String cacheDir, String entry, Uri doorUrl, String? credential, {required String what}) async {
    final a = await ask(doorUrl, credential);
    await note(cacheDir, entry, credential, a);
    if (!a.granted) throw refusal(what, a, kept: false);
  }

  void _checkLater(String cacheDir, String entry, Uri doorUrl, String? credential,
      {required String what, bool objectStore = false}) {
    final k = _key(cacheDir, entry, credential);
    if (_checking.containsKey(k)) return;
    final run = () async {
      final a = await ask(doorUrl, credential, objectStore: objectStore);
      await note(cacheDir, entry, credential, a);
      if (a.denied) log?.call('door-auth:$what the door refused this credential ($a): the next open is refused');
    }();
    _checking[k] = run;
    unawaited(run.whenComplete(() => _checking.remove(k)));
  }

  /// The exception for a door that did not say yes about [what].
  BithumanEntitlementException refusal(String what, DoorAnswer a, {required bool kept}) {
    if (a.denied) {
      return BithumanEntitlementException(
          '$what: bitHuman refused this credential for this avatar ($a). A private avatar opens only for '
          'the account that owns it; pass that account\'s apiSecret'
          '${kept ? ' (the copy kept on this device was not opened)' : ''}',
          refused: true,
          status: a.status);
    }
    return BithumanEntitlementException(
        '$what: bitHuman could not confirm that this credential may open this avatar ($a), and '
        '${kept ? 'it has not opened the copy kept on this device recently enough (24 h for an account\'s '
            'own avatar, 7 days for a public one)' : 'nothing is downloaded until it does'}. Try again online',
        refused: false,
        status: a.status);
  }
}

/// The platform door for [code] and [model], asked for a JSON grant (`redirect=false`): one request, no
/// file. The door is owner-scoped: it answers another account's key 404 NOT_FOUND.
Uri bithumanEntitlementDoor(String code, String model) => Uri.https('api.bithuman.ai',
    '/v1/agent/${Uri.encodeComponent(code)}/model/download', {'model': model, 'redirect': 'false'});

DoorGate _entitlementGate = DoorGate();

/// The gate the top-level installers use (`downloadExpression2Avatar`, `downloadExpression2Agent`,
/// `downloadEssence2Bundle`).
DoorGate get entitlementGate => _entitlementGate;

/// Tests only: a gate on a loopback door and a test clock.
@visibleForTesting
set entitlementGate(DoorGate gate) => _entitlementGate = gate;
