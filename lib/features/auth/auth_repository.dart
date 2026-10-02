import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/api_service.dart';
import '../../core/constants/app_config.dart';
import '../../shared/models/app_user.dart';
import 'session_store.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final repository = AuthRepository(ref.watch(apiClientProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

final authStateProvider = StreamProvider<AppUser?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges;
});

class AuthRepository extends ChangeNotifier {
  AuthRepository(
    this._client, {
    Future<SharedPreferences> Function()? preferences,
    SessionStore? sessionStore,
  }) : _sessionStore = SerializedSessionStore(
         sessionStore ??
             (preferences == null
                 ? createSessionStore(_client.baseUri.toString())
                 : PreferencesSessionStore(preferences)),
       ) {
    _client.onUnauthorized = () => clearSession(cancelPendingAuth: false);
  }
  static const sessionTokenKey = legacySessionTokenKey;
  final ApiClient _client;
  final SessionStore _sessionStore;
  final _changes = StreamController<AppUser?>.broadcast();
  AppUser? _currentUser;
  bool initialized = false;
  bool sessionStorageCleared = true;
  String? restorationError;
  bool canRetryRestoration = false;
  bool isRestoring = false;
  Future<void>? _restoration;
  int _sessionGeneration = 0;
  int _authAttempt = 0;
  Future<void> _storageTail = Future<void>.value();

  Stream<AppUser?> get authStateChanges async* {
    yield _currentUser;
    yield* _changes.stream;
  }

  AppUser? get currentUser => _currentUser;

  Future<void> restoreSession() => _restoration ??= _restoreSession();

  /// Revalidates the remembered token without asking for the password. A saved
  /// token alone never grants authenticated access while the server is offline.
  Future<void> retryRestoreSession() {
    if (isRestoring) return _restoration ?? Future<void>.value();
    if (!canRetryRestoration || _currentUser != null) {
      return Future<void>.value();
    }
    return _restoration = _restoreSession();
  }

  Future<void> _restoreSession() async {
    if (_currentUser != null) return;
    final generation = _sessionGeneration;
    final attempt = _authAttempt;
    isRestoring = true;
    canRetryRestoration = false;
    restorationError = null;
    notifyListeners();
    try {
      final savedToken = await _sessionStore.read().timeout(_client.timeout);
      if (generation != _sessionGeneration || attempt != _authAttempt) return;
      if (savedToken != null && savedToken.isNotEmpty) {
        _client.token = savedToken;
        final user = AppUser.fromMap(await _client.getMap('auth/me'));
        if (generation == _sessionGeneration && attempt == _authAttempt) {
          _setUser(user);
        }
      } else {
        _client.token = null;
        _setUser(null);
      }
    } catch (error) {
      final legacyRemoved = error is LegacySessionRemoved;
      final invalidSession =
          error is LegacySessionRemoved ||
          error is ApiException &&
              (error.status == 401 ||
                  const [
                    'UNAUTHENTICATED',
                    'INVALID_SESSION',
                  ].contains(error.code.toUpperCase()));
      if (attempt == _authAttempt && _currentUser == null) {
        canRetryRestoration = !invalidSession;
        restorationError = invalidSession
            ? '이전 로그인 시간이 만료되었습니다. 다시 로그인해주세요.'
            : '이전 로그인을 확인하지 못했습니다. 연결이 돌아오면 비밀번호 없이 다시 확인할 수 있습니다.';
      }
      if (generation == _sessionGeneration && attempt == _authAttempt) {
        if (invalidSession) {
          await clearSession();
          restorationError = legacyRemoved
              ? '로그인 보관 방식이 변경되었습니다. 보안을 위해 다시 로그인해주세요.'
              : '이전 로그인 시간이 만료되었습니다. 다시 로그인해주세요.';
        } else {
          // Keep the remembered token in storage. Remove only in-memory access
          // until /auth/me succeeds on an explicit retry.
          _client.token = null;
          _setUser(null);
        }
      }
    } finally {
      initialized = true;
      isRestoring = false;
      notifyListeners();
    }
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String name,
    bool rememberMe = false,
  }) async {
    final attempt = ++_authAttempt;
    final response = await _client.mutate(
      'auth/register',
      authenticated: false,
      body: {'email': email, 'password': password, 'name': name},
    );
    await _acceptSession(
      ApiClient.asMap(response),
      rememberMe: rememberMe,
      attempt: attempt,
    );
  }

  Future<void> signIn({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    final attempt = ++_authAttempt;
    final response = await _client.mutate(
      'auth/login',
      authenticated: false,
      body: {'email': email, 'password': password},
    );
    await _acceptSession(
      ApiClient.asMap(response),
      rememberMe: rememberMe,
      attempt: attempt,
    );
  }

  Future<void> _acceptSession(
    Map<String, dynamic> response, {
    required bool rememberMe,
    required int attempt,
  }) async {
    _checkAttempt(attempt);
    final token = response['token'];
    if (token is! String || token.isEmpty) {
      throw const ApiException('로그인 응답을 확인해주세요.');
    }
    final user = AppUser.fromMap(ApiClient.asMap(response['user']));
    await _serializeStorage(() async {
      _checkAttempt(attempt);
      await _sessionStore.clear().timeout(_client.timeout);
      _checkAttempt(attempt);
      if (rememberMe) {
        await _sessionStore.write(token).timeout(_client.timeout);
      }
      if (attempt != _authAttempt) {
        await _sessionStore.clear().timeout(_client.timeout);
        _checkAttempt(attempt);
      }
    });
    _checkAttempt(attempt);
    _client.token = token;
    initialized = true;
    restorationError = null;
    canRetryRestoration = false;
    _setUser(user);
  }

  Future<MailRequestResult> requestPasswordReset(String email) async {
    final response = ApiClient.asMap(
      await _client.mutate(
        'auth/password-reset/request',
        authenticated: false,
        body: {'email': email.trim()},
      ),
    );
    _requireAcceptedMail(response);
    return MailRequestResult.fromMap(response);
  }

  Future<void> confirmPasswordReset({
    required String token,
    required String password,
  }) async {
    final response = ApiClient.asMap(
      await _client.mutate(
        'auth/password-reset/confirm',
        authenticated: false,
        body: {'token': token.trim(), 'password': password},
      ),
    );
    if (response['ok'] != true) {
      throw const ApiException('비밀번호 변경 결과를 확인할 수 없습니다. 다시 시도해주세요.');
    }
  }

  Future<MailRequestResult> requestEmailVerification() async {
    final response = ApiClient.asMap(
      await _client.mutate('auth/email-verification/request'),
    );
    _requireAcceptedMail(response);
    return MailRequestResult.fromMap(response);
  }

  Future<void> confirmEmailVerification(String token) async {
    final sessionToken = _client.token;
    final ownerId = _currentUser?.id;
    final response = ApiClient.asMap(
      await _client.mutate(
        'auth/email-verification/confirm',
        body: {'token': token.trim()},
      ),
    );
    if (response['ok'] != true) {
      throw const ApiException('이메일 인증 결과를 확인할 수 없습니다. 다시 확인해주세요.');
    }
    final user = _currentUser;
    if (sessionToken == null ||
        _client.token != sessionToken ||
        user == null ||
        user.id != ownerId) {
      throw const ApiException('로그인 정보가 변경되었습니다.', code: 'session_changed');
    }
    final verifiedAt = DateTime.tryParse(
      response['email_verified_at'] as String? ?? '',
    );
    if (verifiedAt == null) {
      throw const ApiException('이메일 인증 결과를 확인할 수 없습니다. 다시 확인해주세요.');
    }
    // Confirmation is authoritative. A subsequent profile read could fail
    // after the one-time code was consumed, incorrectly reporting failure.
    // Preserve the latest profile fields in this same session.
    _setUser(user.withVerifiedEmail(verifiedAt));
  }

  void _requireAcceptedMail(Map<String, dynamic> response) {
    if (response['accepted'] != true) {
      throw const ApiException(
        '이메일 요청이 접수되지 않았습니다. 잠시 후 다시 시도해주세요.',
        code: 'MAIL_UNAVAILABLE',
      );
    }
  }

  Future<void> signOut() async {
    final attempt = ++_authAttempt;
    try {
      if (_client.token != null) await _client.mutate('auth/logout');
    } finally {
      // A late logout for the previous account must not clear a newer login.
      if (attempt == _authAttempt) await clearSession();
    }
  }

  Future<void> clearSession({bool cancelPendingAuth = true}) async {
    if (cancelPendingAuth) _authAttempt++;
    sessionStorageCleared = true;
    canRetryRestoration = false;
    restorationError = null;
    _client.token = null;
    _setUser(null);
    final generation = _sessionGeneration;
    try {
      await _serializeStorage(() async {
        if (generation != _sessionGeneration) return;
        await _sessionStore.clear().timeout(_client.timeout);
      });
    } catch (_) {
      sessionStorageCleared = false;
      // Routing and in-memory logout still finish if storage is broken.
    }
  }

  void _checkAttempt(int attempt) {
    if (attempt != _authAttempt) {
      throw const ApiException('로그인 요청이 변경되었습니다.', code: 'session_changed');
    }
  }

  Future<void> _serializeStorage(Future<void> Function() action) {
    final next = _storageTail.then((_) => action());
    _storageTail = next.catchError((Object _) {});
    return next;
  }

  Future<AppUser> ensureCurrentProfile() async {
    final profile = AppUser.fromMap(await _client.getMap('profile'));
    _setUser(profile);
    return profile;
  }

  void _setUser(AppUser? user) {
    _sessionGeneration++;
    _currentUser = user;
    _client.userId = user?.id;
    _changes.add(user);
    notifyListeners();
  }

  @override
  void dispose() {
    _client.onUnauthorized = null;
    unawaited(_changes.close());
    super.dispose();
  }
}

class MailRequestResult {
  const MailRequestResult({
    this.isDemonstration = false,
    this.demonstrationToken,
  });
  final bool isDemonstration;
  final String? demonstrationToken;
  factory MailRequestResult.fromMap(Map<String, dynamic> map) {
    final demo = AppConfig.demoMode && map['demo_only'] == true;
    return MailRequestResult(
      isDemonstration: demo,
      demonstrationToken: demo ? map['demo_token'] as String? : null,
    );
  }
}
