// The credential a session bills to: an API secret, or a short-lived session token
// that the app refreshes.
//
// ★ WHY THERE ARE TWO KINDS. An API secret is long-lived and never changes under a
// session. A bitHuman Live app holds no API secret: its backend mints a short-lived
// per-user session token (about an hour) and replaces it before it expires. The
// service answers an expired token with 401, and a single-session token that is
// already bound to another session with `token_spent` (403). Before this file, the
// plugin treated both as a permanent refusal, so every token expiry ended a
// conversation.
//
// ★ WHAT THIS CAN AND CANNOT DO. It can only hand the plugin a DIFFERENT credential to
// present. The service still validates every credential, derives the payer from it and
// prices every second from its own tables. There is no unmetered answer, no price and
// no endpoint in here. A provider with nothing new to offer leaves every refusal
// exactly as it was.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';

/// Returns the credential to use now.
///
/// [forceRefresh] is true when the service has just refused the last credential you
/// returned (it expired, or it was already spent on another session). Mint or refresh a
/// NEW one. When it is false, return the credential you already hold; that call should
/// be cheap.
///
/// Return `null` when you have none. The session then refuses exactly as it would with
/// no credential at all.
typedef BithumanCredentialProvider = Future<String?> Function({required bool forceRefresh});

/// What a session presents to bitHuman: an API secret, or a session token from a
/// [BithumanCredentialProvider].
///
/// ```dart
/// // A developer with an API secret (unchanged behaviour):
/// final c = BithumanCredential.apiSecret(secret);
///
/// // An app whose backend mints short-lived session tokens:
/// final c = BithumanCredential.provider(({required forceRefresh}) =>
///     forceRefresh ? liveSession.refresh() : liveSession.currentToken());
/// ```
class BithumanCredential {
  /// A long-lived API secret. It never changes, and a 401 for it is final.
  BithumanCredential.apiSecret(String secret)
      : _secret = _clean(secret),
        _provider = null,
        timeout = const Duration(seconds: 10);

  /// A short-lived token from [provider]. The plugin asks it for the current token when a
  /// session starts, and asks it ONCE with `forceRefresh: true` when the service refuses
  /// the token (401, or `token_spent`), before that refusal becomes final.
  ///
  /// A provider that does not answer within [timeout], throws, or returns a blank value
  /// counts as "no credential".
  BithumanCredential.provider(BithumanCredentialProvider provider,
      {this.timeout = const Duration(seconds: 10)})
      : _secret = null,
        _provider = provider;

  final String? _secret;
  final BithumanCredentialProvider? _provider;

  /// How long the plugin waits for the provider.
  final Duration timeout;

  /// True for a provider: the credential may change during a session.
  bool get rotates => _provider != null;

  /// The credential to present now, or null. Never throws.
  Future<String?> current() => _ask(forceRefresh: false);

  /// The service refused [rejected]. Returns a DIFFERENT credential to try once, or null
  /// when there is none (an API secret never has one). Never throws.
  Future<String?> fresh(String rejected) async {
    if (_provider == null) return null;
    final next = await _ask(forceRefresh: true);
    return (next == null || next == rejected) ? null : next;
  }

  Future<String?> _ask({required bool forceRefresh}) async {
    final p = _provider;
    if (p == null) return _secret;
    try {
      return _clean(await p(forceRefresh: forceRefresh).timeout(timeout));
    } catch (e) {
      // ignore: avoid_print
      print('[bithuman] the credential provider '
          '${e is TimeoutException ? 'did not answer within ${timeout.inSeconds} s' : 'failed (${e.runtimeType})'}'
          '; no new credential is used');
      return null;
    }
  }

  static String? _clean(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}

/// "This credential is spent, and a new one may pass": 401 (expired, closed, revoked),
/// or a refusal that names `token_spent` (a single-session token already bound to
/// another session; the service answers it with 403, and 409 is accepted too). Every
/// other 402/403 is the ACCOUNT's answer (no credit, not entitled). A new token for the
/// same account changes none of those, so they stay final.
bool credentialAsksForFresh(int? status, {String? code}) {
  if (status == 401) return true;
  final spent = (code ?? '').toLowerCase() == 'token_spent';
  return spent && (status == null || status == 403 || status == 409);
}
