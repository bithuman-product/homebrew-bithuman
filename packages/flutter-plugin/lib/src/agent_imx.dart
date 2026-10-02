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
// before the open. Whether it is still the published one is asked in the background afterwards (its
// published length), and a different file is downloaded then, for the NEXT open. Every Essence 2
// character was re-published on 2026-10-01 (the mouth-corner fix) and the pinned engine refuses the
// old files, so a kept Essence 2 file older than [kImxStaleBefore] is fetched again ONCE before it
// opens — the old file stays in place until the new one is complete, and opens if that download
// fails. The new file is stamped with the current time, so the rule never fires for it again. On a
// device whose clock reads before the cutoff the rule is off (old and new cannot be told apart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../bithuman.dart' show BithumanAgent, BithumanAvatarException;

/// bitHuman's model doors: the platform API and the site. A redirect a door issues is followed (it
/// points at the signed file URL the door just minted); so is a redirect to one of these hosts.
const Set<String> kBithumanModelHosts = {
  'api.bithuman.ai',
  'www.bithuman.ai',
  'bithuman.ai',
};

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
  })  : clock = clock ?? DateTime.now,
        staleBefore = staleBefore ?? kImxStaleBefore,
        door = door ?? bithumanModelDoor,
        doorHosts = doorHosts ?? kBithumanModelHosts;

  final DateTime Function() clock;
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
    // With a key, the platform door (it honours the key); without, the catalog's own door.
    final src = key != null ? door(agent.id) : Uri.parse(agent.modelUrl);
    _checkUrl(src, 'model_url');
    // A poisoned / MITM'd catalog could point model_url at an attacker host whose bytes reach the
    // native parser: with an allow-list, the first hop must be on it (or be bitHuman's own).
    if (allowedHosts != null && allowedHosts.isNotEmpty &&
        !allowedHosts.contains(src.host) && !doorHosts.contains(src.host)) {
      throw BithumanAvatarException('model_url host not allowed: ${src.host}');
    }
    final trusted = {...doorHosts, ...?allowedHosts};

    if (await local.exists() && await local.length() > _kMinImxBytes) {
      if (_isStale(local, agent)) {
        try {
          await _fetch(src, local, trusted, key, onProgress);
          log?.call('imx:${agent.id} the kept file predates ${staleBefore.toIso8601String()}: downloaded again');
        } catch (e) {
          log?.call('imx:${agent.id} could not download it again ($e); opening the kept file');
        }
        return local.path;
      }
      _refreshInBackground(agent.id, src, local, trusted, key);
      return local.path;
    }
    await _fetch(src, local, trusted, key, onProgress);
    return local.path;
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
  Future<HttpClientResponse> _open(HttpClient client, Uri src, Set<String> trusted, String? key) async {
    var u = src;
    for (var hop = 0; hop <= 5; hop++) {
      final req = await client.getUrl(u);
      req.followRedirects = false;
      if (key != null && u.host == src.host) req.headers.set('api-secret', key);
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
        if (!doorHosts.contains(u.host) && !trusted.contains(next.host)) {
          throw BithumanAvatarException('.imx download: refusing a redirect to an untrusted host: ${next.host}');
        }
        u = next;
        continue;
      }
      return res;
    }
    throw BithumanAvatarException('.imx download: too many redirects from ${src.host}');
  }

  Future<void> _fetch(Uri src, File dest, Set<String> trusted, String? key,
      void Function(int received, int? total)? onProgress) async {
    final client = HttpClient();
    final tmp = File('${dest.path}.partial');
    try {
      final res = await _open(client, src, trusted, key);
      if (res.statusCode != 200) {
        await res.drain<void>().catchError((_) {});
        throw BithumanAvatarException(_why(res.statusCode, src, key != null));
      }
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

  static String _why(int code, Uri src, bool withKey) {
    if (code == 401 || code == 403) {
      return '.imx download HTTP $code from ${src.host}: this character is not downloadable without '
          "its owner's API key — pass apiSecret (anonymous downloads serve only the gallery's "
          'Essence 2 / Expression 2 showcase characters)';
    }
    if (code == 404 && withKey) {
      return '.imx download HTTP 404 from ${src.host}: not found for this API key — its account '
          'does not own this character';
    }
    return '.imx download HTTP $code from ${src.host}';
  }

  /// After a cached open: is the kept file still the published one (same length)? If not, download
  /// the published file now, for the NEXT open. Offline / no answer: nothing (the next open asks).
  void _refreshInBackground(String id, Uri src, File kept, Set<String> trusted, String? key) {
    if (_refreshing.containsKey(id)) return;
    final run = () async {
      try {
        final want = await _publishedLength(src, trusted, key);
        if (want == null || want == await kept.length()) return;
        log?.call('imx:$id the kept file is not the published one; downloading it in the background');
        await _fetch(src, kept, trusted, key, null);
        log?.call('imx:$id refreshed');
      } catch (e) {
        log?.call('imx:$id background refresh did not finish ($e)');
      }
    }();
    _refreshing[id] = run;
    unawaited(run.whenComplete(() => _refreshing.remove(id)));
  }

  static const Duration revalidateTimeout = Duration(seconds: 20);

  Future<int?> _publishedLength(Uri src, Set<String> trusted, String? key) async {
    final client = HttpClient()..connectionTimeout = revalidateTimeout;
    try {
      final res = await _open(client, src, trusted, key).timeout(revalidateTimeout);
      final n = res.statusCode == 200 && res.contentLength > 0 ? res.contentLength : null;
      await res.listen((_) {}).cancel();   // the headers are the answer: no body
      return n;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
