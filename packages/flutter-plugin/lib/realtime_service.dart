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
  }) : _http = client ?? http.Client();
  final http.Client _http;

  /// Public API gateway base.
  final String apiBase;

  /// The realtime model minted for when the caller does not name one.
  final String defaultModel;

  // ── The mint must be BOUNDED and RETRIED (2026-09-17) ─────────────────────
  //
  // This call used a bare `_http.post` with NO timeout and NO retry. Dart's
  // `http.Client` waits INDEFINITELY, so a backend that was slow rather than
  // down left this future pending forever and the UI sat at
  // "Avatar ready — connecting …" with nothing to time out and nothing to retry.
  // That is exactly how both phones were stranded on 2026-09-17: the server's
  // credential gate had serialized under concurrency and this endpoint was
  // answering in 8.8–11.9 s, or returning 408/504 — and a single non-200 threw
  // once, with no second attempt, though a retry would have succeeded in ~1 s.
  //
  // The server defect is fixed (platform#450). This is the CLIENT half: a client
  // that hangs forever on a slow dependency is its own defect, and the next slow
  // dependency should cost a retry, not a session.
  //
  // RETRY ONLY WHAT A RETRY CAN FIX: a timeout, a transport error, or a
  // 408/429/5xx (the server is slow/overloaded — a later attempt can differ). A
  // 401/403/400 is a verdict about the credential or the request, so it is
  // raised on the FIRST attempt; retrying it would only delay a clear error.
  static const _attemptTimeout = Duration(seconds: 10);
  static const _maxAttempts = 3;
  static const _backoff = [Duration(milliseconds: 500), Duration(milliseconds: 1500)];

  static bool _worthRetrying(int status) =>
      status == 408 || status == 429 || status >= 500;

  /// Mint a per-session OpenAI Realtime ephemeral token, authenticated by the
  /// account [apiSecret]. Bounded per attempt and retried on slow/overloaded
  /// responses; throws once the attempts are spent, or immediately on a
  /// credential/request verdict (400/401/403).
  Future<EphemeralToken> mintEphemeralToken(String apiSecret, {String? model}) async {
    final uri = Uri.parse('$apiBase/v1/realtime/ephemeral-token');

    http.Response? resp;
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_backoff[attempt - 1]);
      }
      try {
        resp = await _http
            .post(
              uri,
              headers: {'api-secret': apiSecret, 'Content-Type': 'application/json'},
              body: jsonEncode({'model': model ?? defaultModel}),
            )
            .timeout(_attemptTimeout);
      } catch (e) {
        // Timeout or transport failure — retryable by construction.
        lastError = e;
        // ignore: avoid_print
        print('[realtime] ephemeral-token attempt ${attempt + 1}/$_maxAttempts failed: $e');
        continue;
      }
      if (resp.statusCode == 200) break;
      if (!_worthRetrying(resp.statusCode)) {
        throw Exception(
            'Ephemeral token mint failed (${resp.statusCode}): ${resp.body}');
      }
      lastError =
          Exception('Ephemeral token mint failed (${resp.statusCode}): ${resp.body}');
      // ignore: avoid_print
      print('[realtime] ephemeral-token attempt ${attempt + 1}/$_maxAttempts '
          'got ${resp.statusCode}; retrying');
      resp = null;
    }

    if (resp == null || resp.statusCode != 200) {
      throw Exception(
          'Ephemeral token mint failed after $_maxAttempts attempts: ${lastError ?? 'unknown'}');
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
