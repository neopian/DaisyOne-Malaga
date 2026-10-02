import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const legacySessionTokenKey = 'auth.api_session';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// A timed-out platform call can still finish later. Keep its raw operation in
/// the queue so a late secure-store write never overwrites a newer account.
class SerializedSessionStore implements SessionStore {
  SerializedSessionStore(this.delegate);
  final SessionStore delegate;
  Future<void> _tail = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  Future<String?> read() => _enqueue(delegate.read);
  @override
  Future<void> write(String token) => _enqueue(() => delegate.write(token));
  @override
  Future<void> clear() => _enqueue(delegate.clear);
}

/// Browser persistence is optional local storage, not native secure storage.
/// Also injectable in tests so storage failures and serialized writes stay
/// deterministic without replacing native secure storage in production.
class PreferencesSessionStore implements SessionStore {
  PreferencesSessionStore(this.preferences, {this.key = legacySessionTokenKey});
  final Future<SharedPreferences> Function() preferences;
  final String key;

  @override
  Future<String?> read() async => (await preferences()).getString(key);

  @override
  Future<void> write(String token) async {
    if (!await (await preferences()).setString(key, token)) {
      throw StateError('Session storage write failed');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await preferences()).remove(key)) {
      throw StateError('Session storage removal failed');
    }
  }
}

class LegacySessionRemoved implements Exception {
  const LegacySessionRemoved();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore({
    required this.key,
    FlutterSecureStorage? storage,
    Future<SharedPreferences> Function()? preferences,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked_this_device,
               synchronizable: false,
             ),
           ),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final String key;
  final FlutterSecureStorage _storage;
  final Future<SharedPreferences> Function() _preferences;

  Future<bool> _removeLegacy() async {
    final prefs = await _preferences();
    final hadLegacy = prefs.containsKey(legacySessionTokenKey);
    if (!await prefs.remove(legacySessionTokenKey)) {
      throw StateError('Legacy session removal failed');
    }
    return hadLegacy;
  }

  @override
  Future<String?> read() async {
    final hadLegacy = await _removeLegacy();
    final token = await _storage.read(key: key);
    // Re-entering a password is safer than copying an old plaintext credential
    // into a new store. Never silently fall back to preferences on native.
    if (token == null && hadLegacy) throw const LegacySessionRemoved();
    return token;
  }

  @override
  Future<void> write(String token) async {
    await _removeLegacy();
    await _storage.write(key: key, value: token);
  }

  @override
  Future<void> clear() async {
    await Future.wait([_storage.delete(key: key), _removeLegacy()]);
  }
}

SessionStore createSessionStore(String server) {
  if (kIsWeb) {
    return PreferencesSessionStore(SharedPreferences.getInstance);
  }
  return SecureSessionStore(
    key: 'auth.api_session.v2.${sha256.convert(utf8.encode(server))}',
  );
}
