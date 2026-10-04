// downloadAgentImx's engine room (2.6.30): the door, its redirect, the API key, and the cache rule.
//
// Until 2.6.29 `downloadAgentImx` refused every redirect (since 2.4.0) and sent no credential, so
// against today's catalog it could fetch nothing: an Essence 2 character's door answers 302 to a
// signed file URL, and an Essence 1 / Expression 1 character answers 401 to an anonymous caller.
//
// What it can download now:
//  * a GALLERY (showcase) Essence 2 character's `.imx`, anonymously: the door redirects to a signed
//    file URL, which is followed;
//  * any character the caller's API key's account OWNS (`apiSecret:`): the platform door
//    (`GET https://api.bithuman.ai/v1/agent/<code>/model/download`) is asked with the key, which goes
//    to that door only, never to the file host it redirects to.
// What it cannot: another account's Essence 1 / Expression 1 character (most of the community
// catalog `fetchPublicAgents` lists) — 401 anonymously, 404 with a key that does not own it. An
// Expression 2 character is a `.avatar`, not an `.imx`: use `downloadExpression2Avatar`.
//
// Redirects are followed only when TRUSTED, https only, at most five: a redirect issued by bitHuman's
// own door ([kBithumanModelHosts]) — the door mints the signed file URL it points at — or a redirect
// to a host on the caller's `allowedHosts` (or to a bitHuman host). Any other redirect fails the
// download: the bytes feed the engine's model parser.
//
// The cache (the Live app's rule, bithuman-apps #467): a kept file opens AT ONCE, with no network
// before the open — ★for a credential the door has said yes to (2.6.36, security; lib/src/door_gate.dart).
// The cache directory is the app's, not an account's: through 2.6.35 account B was handed account A's
// kept PRIVATE file. Now a kept file opens at once only when the credential of this call (its
// `apiSecret`, or none) holds a fresh entitlement mark for it (24 h after the door's last yes; 7 days
// for a public file, one the door served with no credential); otherwise the door is asked first, and a
// refusal, or a door that cannot be asked, fails the call with [BithumanEntitlementException] (the kept
// file stays). The door asked about a kept file is always the platform door for the agent's code
// (owner-scoped, as the native stores ask it), with this call's credential, never the catalog's
// `model_url`, and only that door's answer writes or drops a mark: a row's model_url on one of
// bitHuman's hosts can redirect for ANY code (the apex to www, a trailing slash, www's /embed/<code>), so
// a download from it marks nothing by itself; the platform door is then asked once, with the same (absent)
// credential. A door's yes is its redirect OFF bitHuman's door hosts (the signed file URL); a redirect
// from one door host to another is followed and is no answer. Whether the kept file is still the published one is asked in the background afterwards
// (its published length; the same request renews or drops the mark), and a different file is
// downloaded then, for the NEXT open. Every Essence 2 character was re-published on 2026-10-01 (the
// mouth-corner fix) and the pinned engine refuses the old files, so a kept Essence 2 file older than
// [kImxStaleBefore] is fetched again ONCE before it opens — the old file stays in place until the new
// one is complete, and opens if that download fails only for a fresh mark or the PLATFORM door's yes to
// this call's credential (never the row's model_url's answer). The
// new file is stamped with the current time, so the rule never fires for it again. On a device whose
// clock reads before the cutoff the rule is off (old and new cannot be told apart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../bithuman.dart' show BithumanAgent, BithumanAvatarException;
import 'door_gate.dart';

/// bitHuman's model doors: the platform API and the site. A redirect a door issues is followed (it
/// points at the signed file URL the door just minted); so is a redirect to one of these hosts.
const Set<String> kBithumanModelHosts = kBithumanDoorHosts;

/// The platform's model door for [code] (it redirects to a signed file URL).
Uri bithumanModelDoor(String code) =>
    Uri.https('api.bithuman.ai', '/v1/agent/${Uri.encodeComponent(code)}/model/download');

/// Essence 2 files kept from before the 2026-10-01 re-publish are fetched again once.
final DateTime kImxStaleBefore = DateTime.utc(2026, 10, 2);

/// The smallest file that can be a character (smaller is an error page).
const int _kMinImxBytes = 1024 * 1024;

/// The download and cache logic behind [downloadAgentImx]; injectable for tests.
class AgentImxDownloader {
  AgentImxDownloader({
    DateTime Function()? clock,
    DateTime? staleBefore,
    Uri Function(String code)? door,
    Set<String>? doorHosts,
    this.isContainer,
    this.allowInsecure = false,
    this.log,
    DoorGate? gate,
  })  : clock = clock ?? DateTime.now,
        staleBefore = staleBefore ?? kImxStaleBefore,
        door = door ?? bithumanModelDoor,
        doorHosts = doorHosts ?? kBithumanModelHosts,
        gate = gate ??
            DoorGate(clock: clock, doorHosts: doorHosts ?? kBithumanDoorHosts, allowInsecure: allowInsecure, log: log);

  final DateTime Function() clock;

  /// The entitlement marks (2.6.36): which credential the door has said yes to for which kept file.
  final DoorGate gate;
  final DateTime staleBefore;
  final Uri Function(String code) door;

  /// The hosts whose redirects are followed wherever they point (https): bitHuman's doors.
  final Set<String> doorHosts;

  /// Asks the native engine whether a file is one of bitHuman's containers (null = cannot tell).
  final Future<bool?> Function(String path)? isContainer;

  /// Tests only: plain-http loopback doors.
  final bool allowInsecure;
  final void Function(String line)? log;

  final Map<String, Future<void>> _refreshing = {};

  /// The background check (and download) for [agentId] under way, if any.
  @visibleForTesting
  Future<void>? refreshing(String agentId) => _refreshing[agentId];

  /// The mark name of [agentId]'s kept file (beside it, under `<cacheDir>/.door-auth/`).
  static String markEntry(String agentId) => '${agentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.imx';

  Future<String> download(
    BithumanAgent agent,
    String cacheDir, {
    Set<String>? allowedHosts,
    void Function(int received, int? total)? onProgress,
    String? apiSecret,
  }) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    // The catalog `id` comes from a public / MITM-able JSON feed, so never use it raw in a
    // filesystem path — a crafted '../' would escape cacheDir. Real ids are alphanumeric.
    final safeId = agent.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final local = File('$cacheDir/$safeId.imx');
    final key = (apiSecret != null && apiSecret.isNotEmpty) ? apiSecret : null;
    // ★THE ENTITLEMENT DOOR (2.6.36): the platform door for THIS code, asked with this call's credential
    // (or none) whenever a kept file needs a yes. The native stores ask the same owner-scoped door.
    final entDoor = door(agent.id);
    // With a key, the platform door (it honours the key); without, the catalog's own door.
    final src = key != null ? entDoor : Uri.parse(agent.modelUrl);
    _checkUrl(src, 'model_url');
    // A poisoned / MITM'd catalog could point model_url at an attacker host whose bytes reach the
    // native parser: with an allow-list, the first hop must be on it (or be bitHuman's own).
    if (allowedHosts != null && allowedHosts.isNotEmpty &&
        !hostIn(allowedHosts, src.host) && !hostIn(doorHosts, src.host)) {
      throw BithumanAvatarException('model_url host not allowed: ${src.host}');
    }
    final trusted = {...doorHosts, ...?allowedHosts};
    final entry = markEntry(agent.id);
    final what = 'imx:${agent.id}';
    // A download's own answer counts for the mark only when it IS the platform door for this code
    // (always, with a key). A catalog row's model_url is not: a stale or tampered row can name this code
    // with a URL on one of bitHuman's hosts that answers ANY code with a redirect (production, measured
    // 2026-10-03: the apex 307s every path to www, www 308s a trailing slash, and www's /embed/<code>
    // 307s to agent.viewer.bithuman.ai), and a redirect is not a yes about this code. Without a key the
    // file comes from the row's model_url as before, and the platform door is then asked (no credential)
    // for the mark: [_markFromDoor].
    final markable = src == entDoor;

    if (await local.exists() && await local.length() > _kMinImxBytes) {
      // ★ONE CREDENTIAL PER CALL (2.6.36): [key] is the only credential this call asks with, and the
      // door's answer to it is the only thing that marks (or unmarks) it.
      final marked = await gate.mayOpenWithoutDoor(cacheDir, entry, key);
      if (_isStale(local, agent)) {
        DoorAnswer? said;
        Object? failed;
        try {
          await _fetch(src, local, trusted, key, onProgress, onDoor: (a) => said = a);
        } on _DoorFailure catch (e) {
          said = e.door;
          failed = e.message;
        } catch (e) {
          failed = e;
        }
        final a = said ?? DoorAnswer.unreachable(failed ?? 'no answer');
        if (markable) await gate.note(cacheDir, entry, key, a);
        if (failed == null) {
          if (!markable) await _markFromDoor(cacheDir, entry, key, entDoor);
          log?.call('$what the kept file predates ${staleBefore.toIso8601String()}: downloaded again');
          return local.path;
        }
        if (markable && a.denied) throw gate.refusal(what, a, kept: true);
        // The download failed: the kept (older) file opens only for an entitlement: a fresh mark, or the
        // PLATFORM door's yes to this credential (its answer to this download, or asked now). Never the
        // row's model_url's answer: the kept file may be another account's.
        if (!marked && !(src == entDoor && a.granted)) {
          final d = src == entDoor ? a : (await _check(entDoor, trusted, key)).door;
          if (src != entDoor) await gate.note(cacheDir, entry, key, d);
          if (!d.granted) throw gate.refusal(what, d, kept: true);
        }
        log?.call('$what could not download it again ($failed); opening the kept file');
        return local.path;
      }
      if (marked) {
        _refreshInBackground(agent.id, src, entDoor, local, trusted, key, cacheDir, entry, markable);
        return local.path;
      }
      // No fresh mark for this credential: the door first. Its yes opens the kept file (and a published
      // file of another length is downloaded in the background, for the next open); anything else fails.
      final c = await _check(entDoor, trusted, key);
      await gate.note(cacheDir, entry, key, c.door);
      if (!c.door.granted) throw gate.refusal(what, c.door, kept: true);
      log?.call('$what the door said yes to this credential (${c.door}); opening the kept file');
      if (c.length != null && c.length != await local.length()) {
        _refreshInBackground(agent.id, src, entDoor, local, trusted, key, cacheDir, entry, markable,
            publishedLength: c.length);
      }
      return local.path;
    }
    DoorAnswer? said;
    try {
      await _fetch(src, local, trusted, key, onProgress, onDoor: (a) => said = a);
    } on _DoorFailure catch (e) {
      if (markable) await gate.note(cacheDir, entry, key, e.door);
      if (markable && e.door.denied) {
        throw BithumanEntitlementException(e.message, refused: true, status: e.door.status);
      }
      throw BithumanAvatarException(e.message);
    } catch (_) {
      // The door said yes to this credential even if the download then failed: the mark is about that.
      if (markable && said != null) await gate.note(cacheDir, entry, key, said!);
      rethrow;
    }
    if (markable) {
      await gate.note(cacheDir, entry, key, said ?? const DoorAnswer(200));
    } else {
      await _markFromDoor(cacheDir, entry, key, entDoor);
    }
    return local.path;
  }

  /// After a download from a catalog row's model_url (no key): the platform door for this code is asked
  /// with the same (absent) credential, and ITS answer marks the file (a yes: public, 7 days) or not. One
  /// request, redirect not followed. Best effort: no answer leaves no mark, and the next open asks first.
  Future<void> _markFromDoor(String cacheDir, String entry, String? key, Uri entDoor) async {
    await gate.note(cacheDir, entry, key, await gate.ask(entDoor, key));
  }

  bool _isStale(File f, BithumanAgent agent) {
    if (agent.modelType.isNotEmpty && agent.modelType != 'essence-2') return false;
    if (clock().isBefore(staleBefore)) return false;   // a clock before the cutoff cannot tell
    try {
      return f.lastModifiedSync().isBefore(staleBefore);
    } catch (_) {
      return false;
    }
  }

  void _checkUrl(Uri u, String what) {
    if (u.scheme == 'https' || (allowInsecure && u.scheme == 'http')) return;
    // dart:io's HttpClient is NOT subject to App Transport Security: a cleartext URL would be
    // fetched in the clear on macOS and fed to the native parser.
    throw BithumanAvatarException('refusing non-https $what: $u');
  }

  /// GET with redirects followed only when trusted: issued by a door ([doorHosts]), or pointing at a
  /// [trusted] host. The key goes to the door's own host only — never to the file host it redirects to.
  /// Returns the final 200 and what the FIRST host (the door) answered; any other final status throws
  /// [_DoorFailure] carrying the same (a storage host's 403 behind the door's redirect is not the door
  /// refusing the credential).
  Future<({HttpClientResponse res, DoorAnswer door})> _open(
      HttpClient client, Uri src, Set<String> trusted, String? key) async {
    var u = src;
    DoorAnswer? door;
    for (var hop = 0; hop <= 5; hop++) {
      final req = await client.getUrl(u);
      req.followRedirects = false;
      if (key != null && normalizeHost(u.host) == normalizeHost(src.host)) req.headers.set('api-secret', key);
      final res = await req.close();
      final code = res.statusCode;
      if (code >= 300 && code < 400) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>().catchError((_) {});
        if (loc == null || loc.isEmpty) {
          throw BithumanAvatarException('.imx download: HTTP $code without a location from ${u.host}');
        }
        final next = u.resolve(loc);
        _checkUrl(next, 'redirect');
        if (!hostIn(doorHosts, u.host) && !hostIn(trusted, next.host)) {
          throw BithumanAvatarException('.imx download: refusing a redirect to an untrusted host: ${next.host}');
        }
        // A door's yes is its redirect OFF bitHuman's door hosts (the signed file URL it minted). A
        // redirect from one door host to another (the apex to www, a trailing slash) is not an answer:
        // it is followed, and the next door's answer counts. Hosts compare as DNS names (case, a trailing
        // dot: `www.bithuman.ai.` is a door host).
        if (door == null && hostIn(doorHosts, u.host) && !hostIn(doorHosts, next.host)) door = DoorAnswer(code);
        u = next;
        continue;
      }
      if (code != 200) {
        final body = await readHead(res, 4096).catchError((_) => '');
        final answer = door ?? DoorAnswer(code, code: doorErrorCode(body));
        throw _DoorFailure(answer, _why(code, src, key != null, door == null ? answer.code : null));
      }
      return (res: res, door: door ?? const DoorAnswer(200));
    }
    throw BithumanAvatarException('.imx download: too many redirects from ${src.host}');
  }

  /// Downloads [src] over [dest]. [onDoor] hears what the door answered as soon as it answered (before
  /// the file, which may still fail); a door that did not lead to a 200 throws [_DoorFailure].
  Future<void> _fetch(Uri src, File dest, Set<String> trusted, String? key,
      void Function(int received, int? total)? onProgress, {void Function(DoorAnswer door)? onDoor}) async {
    final client = HttpClient();
    final tmp = File('${dest.path}.partial');
    try {
      final opened = await _open(client, src, trusted, key);
      onDoor?.call(opened.door);
      final res = opened.res;
      // Stream to a `.partial`, then rename over the destination: a failed or cancelled download
      // never replaces a kept file, and never leaves a half file that passes the size check.
      final sink = tmp.openWrite();
      final total = res.contentLength <= 0 ? null : res.contentLength;
      var received = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        try { await sink.close(); } catch (_) {}
        try { await tmp.delete(); } catch (_) {}
        rethrow;
      }
      // Validate before it replaces anything: a few MB at least, and — where the native engine can
      // tell — one of bitHuman's containers. The engine owns the format; this package asks it.
      final size = await tmp.length();
      if (size < _kMinImxBytes) {
        await tmp.delete();
        throw BithumanAvatarException('downloaded .imx is suspiciously small: $size bytes');
      }
      if (await isContainer?.call(tmp.path) == false) {
        await tmp.delete();
        throw BithumanAvatarException('downloaded .imx is not a bitHuman container');
      }
      await tmp.rename(dest.path);
      // Stamped NOW: the one-time stale rule never fires for a file fetched after the re-publish.
      try { await dest.setLastModified(clock()); } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  static String _why(int code, Uri src, bool withKey, [String? doorCode]) {
    if (code == 401 || code == 403) {
      return '.imx download HTTP $code from ${src.host}: this character is not downloadable without '
          "its owner's API key — pass apiSecret (anonymous downloads serve only the gallery's "
          'Essence 2 / Expression 2 showcase characters)';
    }
    if (code == 404 && withKey && (doorCode == null || doorCode == 'NOT_FOUND')) {
      return '.imx download HTTP 404 from ${src.host}: not found for this API key — its account '
          'does not own this character';
    }
    return '.imx download HTTP $code${doorCode == null ? '' : ' $doorCode'} from ${src.host}';
  }

  /// After a cached open: the platform door ([entDoor]) is asked with this call's credential (its yes
  /// renews the mark, its no drops it: the next open is refused), and the kept file is compared with the
  /// published one (its length). Another length: the published file is downloaded from [src] now, for the
  /// NEXT open. Offline / no answer: nothing (the mark keeps its age). [publishedLength]: the door was just
  /// asked; download only.
  void _refreshInBackground(String id, Uri src, Uri entDoor, File kept, Set<String> trusted, String? key,
      String cacheDir, String entry, bool markable, {int? publishedLength}) {
    final k = '$id|${credentialTag(key)}';
    if (_refreshing.containsKey(k)) return;
    final run = () async {
      try {
        var want = publishedLength;
        if (want == null) {
          final c = await _check(entDoor, trusted, key);
          await gate.note(cacheDir, entry, key, c.door);
          if (c.door.denied) {
            log?.call('imx:$id the door refused this credential (${c.door}): the next open is refused');
            return;
          }
          if (!c.door.granted) return;   // no answer: nothing to compare with
          want = c.length;
        }
        if (want == null || want == await kept.length()) return;
        log?.call('imx:$id the kept file is not the published one; downloading it in the background');
        DoorAnswer? said;
        try {
          await _fetch(src, kept, trusted, key, null, onDoor: (a) => said = a);
        } finally {
          if (markable && said != null) await gate.note(cacheDir, entry, key, said!);
        }
        log?.call('imx:$id refreshed');
      } on _DoorFailure catch (e) {
        if (markable) await gate.note(cacheDir, entry, key, e.door);
        log?.call('imx:$id background refresh did not finish (${e.message})');
      } catch (e) {
        log?.call('imx:$id background refresh did not finish ($e)');
      }
    }();
    _refreshing[k] = run;
    _refreshing[id] = run;
    unawaited(run.whenComplete(() {
      _refreshing.remove(k);
      if (identical(_refreshing[id], run)) _refreshing.remove(id);
    }));
  }

  static const Duration revalidateTimeout = Duration(seconds: 20);

  /// One door ask with [key], following its redirect for the published length (headers only, never the
  /// file). Never throws: a door that cannot be asked is [DoorAnswer.unreachable].
  Future<({DoorAnswer door, int? length})> _check(Uri src, Set<String> trusted, String? key) async {
    final client = HttpClient();
    try {
      final o = await _open(client, src, trusted, key).timeout(revalidateTimeout);
      final n = o.res.contentLength > 0 ? o.res.contentLength : null;
      await o.res.listen((_) {}).cancel();   // the headers are the answer: no body
      return (door: o.door, length: n);
    } on _DoorFailure catch (e) {
      return (door: e.door, length: null);
    } catch (e) {
      return (door: DoorAnswer.unreachable(e), length: null);
    } finally {
      client.close(force: true);
    }
  }
}

/// A download that did not end in a 200, with what the door (the first host) answered.
class _DoorFailure implements Exception {
  _DoorFailure(this.door, this.message);
  final DoorAnswer door;
  final String message;
  @override
  String toString() => message;
}
