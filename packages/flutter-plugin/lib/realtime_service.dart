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

  /// Mint a per-session OpenAI Realtime ephemeral token, authenticated by the
  /// account [apiSecret]. Throws on failure.
  Future<EphemeralToken> mintEphemeralToken(String apiSecret, {String? model}) async {
    final uri = Uri.parse('$apiBase/v1/realtime/ephemeral-token');
    final resp = await _http.post(
      uri,
      headers: {'api-secret': apiSecret, 'Content-Type': 'application/json'},
      body: jsonEncode({'model': model ?? defaultModel}),
    );
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
