import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Local-only account verifier (PBKDF2). No backend; persists credentials in prefs.
class AuthStore {
  static const keySession = 'taktak.account.v1';

  Future<AccountSession?> verifySavedAccount({
    required String password,
    required SharedPreferences prefs,
  }) async {
    final raw = prefs.getString(keySession);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final email = map['email'] as String?;
      final displayName = map['displayName'] as String?;
      final saltB64 = map['saltB64'] as String?;
      final verifierB64 = map['passwordVerifierB64'] as String?;
      if ([email, displayName, saltB64, verifierB64].any((x) => (x ?? '').isEmpty)) {
        return null;
      }

      final session = AccountSession(
        email: email!,
        displayName: displayName!,
        saltBytes: base64Decode(saltB64!),
        passwordVerifier: base64Decode(verifierB64!),
      );
      final ok = await matchesPassword(password, session);
      if (!ok) return null;

      return session;
    } catch (err, stack) {
      debugPrint('[AuthStore] decode failed $err');
      debugPrint('$stack');
      return null;
    }
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
    required SharedPreferences prefs,
  }) async {
    final saltBytes =
        List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final verifierBytes = await _derive(password, saltBytes);
    await prefs.setString(
      keySession,
      jsonEncode({
        'email': email.trim().toLowerCase(),
        'displayName': displayName.trim(),
        'saltB64': base64Encode(saltBytes),
        'passwordVerifierB64': base64Encode(verifierBytes),
      }),
    );
  }

  Future<void> clearSession(SharedPreferences prefs) async {
    await prefs.remove(keySession);
  }

  Future<bool> matchesPassword(String password, AccountSession session) async {
    final candidate = await _derive(password, session.saltBytes);
    if (candidate.length != session.passwordVerifier.length) return false;
    var diff = 0;
    for (var i = 0; i < candidate.length; i++) {
      diff |= candidate[i] ^ session.passwordVerifier[i];
    }
    return diff == 0;
  }

  static Future<List<int>> _derive(String password, List<int> salt) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120_000,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return await key.extractBytes();
  }
}
