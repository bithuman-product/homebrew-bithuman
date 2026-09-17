// Umbrella OpenAI access.
//
// Fetches a short-lived OpenAI Realtime client secret ("ek_...") from the
// bitHuman backend so the app never embeds a long-lived OpenAI key. The value
// is used as the Bearer for the OpenAI Realtime WS (macOS) / WebRTC (iOS) dial
// in place of DevConfig.openaiApiKey — injected at pickTransport().
//
// Moved down from the product app so the demo and the product mint the same way
// (one implementation, not one per app). The backend base and the default model
// are constructor arguments rather than a host-app config import, so this file
// carries no app dependency.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A short-lived OpenAI Realtime credential.
class EphemeralToken {
  const EphemeralToken({required this.value, required this.model, this.expiresAt});

  /// The "ek_..." client secret used as the OpenAI Bearer.
  final String value;

  /// Epoch seconds when this token expires (if the backend reported it).
  final int? expiresAt;

  /// The realtime model the token was minted for.
  final String model;
}

class RealtimeService {
  RealtimeService({
    http.Client? client,
    this.apiBase = 'https://api.bithuman.ai',
    this.defaultModel = 'gpt-realtime',
    Duration? mintTimeout,
  })  : _http = client ?? http.Client(),
        // Overridable ONLY so the boundedness test can assert the bound in
        // milliseconds instead of adding 50 s to every CI run. Production never
        // passes it; `defaultMintTimeout` is what ships, and a test asserts that.
        _attemptTimeout = mintTimeout ?? defaultMintTimeout;
  final http.Client _http;
  final Duration _attemptTimeout;

  /// Public API gateway base.
  final String apiBase;

  /// The realtime model minted for when the caller does not name one.
  final String defaultModel;

  // ── The mint must be BOUNDED. It must NOT be retried on a slow server. ────
  //
  // ORIGINAL DEFECT (2026-09-17). This call used a bare `_http.post` with NO
  // timeout. Dart's `http.Client` waits INDEFINITELY, so a backend that was slow
  // rather than down left this future pending forever and the UI sat at
  // "Avatar ready — connecting …" with nothing to time out. Boundedness is the
  // fix, and it is the part that matters.
  //
  // ★ THE FIRST VERSION OF THIS FIX GOT THE RETRY POLICY BACKWARDS, and it is
  //   worth stating why, because the reasoning is the reusable part. It shipped
  //   10 s x 3 attempts, retrying 408/429/5xx. That was calibrated against a
  //   HEALTHY server (resting p50 1.22 s, p90 1.62 s, max 3.15 s) — but the
  //   whole point of the policy is what it does against a SICK one. Measured on
  //   the same endpoint while the backend's Postgres pool was exhausted, a
  //   SUCCESSFUL mint took 20.9 s / 27.2 s / 33.7 s / 35.7 s, and a single
  //   request at concurrency ONE took 26.7 s. Against those numbers 10 s x 3
  //   cannot succeed at all — it times out three times and surfaces a failure —
  //   while sending THREE requests instead of one into a service whose defect is
  //   that it collapses under load. A retry policy sized for a fast server
  //   becomes an amplifier against a slow one, and the failure mode it produces
  //   is the exact symptom it was meant to prevent.
  //
  // SO: ONE attempt, generously bounded. 50 s is not a round number — the edge
  // proxy bounds this route upstream at 45 s
  // (platform services/public-api-service/proxy.py, _FAST_UPSTREAM_TIMEOUT_S),
  // so after ~45 s the caller gets the proxy's structured answer and waiting
  // longer can never produce a token. 50 s sits just past that, which means this
  // client never cuts off a request the server would still have answered, and
  // never waits on one it would not.
  //
  // NOT RETRIED: a timeout or any non-200. A slow/overloaded server (408/429/
  // 5xx) is precisely where a retry does harm, and 400/401/403 is a verdict
  // about the credential or the request that a retry cannot change.
  //
  // RETRIED ONCE: a TRANSPORT failure that is not a timeout — a dropped socket
  // on a handover between cellular and wi-fi, which is common on a phone and is
  // not a signal about server load (a shedding server answers with a STATUS, not
  // a dead socket). One cheap retry, and it cannot amplify a server-side stall.
  static const defaultMintTimeout = Duration(seconds: 50);

  /// Mint a per-session OpenAI Realtime ephemeral token, authenticated by the
  /// account [apiSecret]. ONE bounded attempt (50 s); a dropped socket that is
  /// not a timeout is retried once. A timeout or any non-200 is raised — never
  /// retried, because the server being slow is exactly when a retry does harm.
  Future<EphemeralToken> mintEphemeralToken(String apiSecret, {String? model}) async {
    final uri = Uri.parse('$apiBase/v1/realtime/ephemeral-token');

    Future<http.Response> send() => _http
        .post(
          uri,
          headers: {'api-secret': apiSecret, 'Content-Type': 'application/json'},
          body: jsonEncode({'model': model ?? defaultModel}),
        )
        .timeout(_attemptTimeout);

    // Nullable local then a final alias: Dart's flow analysis cannot prove a
    // `final` is unassigned on entry to the catch (the throw could in principle
    // follow the assignment), so assigning one in both branches is a compile
    // error — "Final variable 'resp' might already be assigned at this point."
    http.Response? attempted;
    try {
      attempted = await send();
    } on TimeoutException {
      // Deliberately NOT retried: at 50 s the edge has already given up
      // upstream, so a second attempt cannot find a faster server — it only
      // doubles the load on a slow one.
      rethrow;
    } catch (_) {
      // Transport failure that is not a timeout (dropped socket, network
      // handover). One retry, no backoff — this is not a load signal.
      // ignore: avoid_print
      print('[realtime] ephemeral-token transport failure; one retry');
      attempted = await send();
    }
    final resp = attempted;

    if (resp.statusCode != 200) {
      throw Exception('Ephemeral token mint failed (${resp.statusCode}): ${resp.body}');
    }
    // Success envelope from auth-service: { data: {value, expires_at, model},
    // status, status_code }. Tolerate an unwrapped body too.
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = (body['data'] as Map<String, dynamic>?) ?? body;
    final value = data['value'] as String?;
    if (value == null) {
      throw Exception('Ephemeral token response missing value');
    }
    return EphemeralToken(
      value: value,
      expiresAt: data['expires_at'] as int?,
      model: (data['model'] as String?) ?? (model ?? defaultModel),
    );
  }
}
