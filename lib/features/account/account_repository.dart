import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';
import '../answers/answer_draft_store.dart';
import '../questions/travel_draft_store.dart';
import 'export_file.dart';

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(
    ref.watch(apiClientProvider),
    ref.watch(authRepositoryProvider),
    ref.watch(travelDraftStoreProvider),
    answerDrafts: ref.watch(answerDraftStoreProvider),
  ),
);

class AccountDeletionResult {
  const AccountDeletionResult({
    required this.cleanupPending,
    required this.localCleanupComplete,
  });
  final bool cleanupPending;
  final bool localCleanupComplete;
}

class AccountRepository {
  AccountRepository(
    this._client,
    this._auth,
    this._drafts, {
    Future<SharedPreferences> Function()? preferences,
    Future<void> Function()? clearExports,
    AnswerDraftStore? answerDrafts,
  }) : _answerDrafts =
           answerDrafts ??
           AnswerDraftStore(
             server: _client.baseUri.toString(),
             preferences: preferences,
           ),
       _clearExports = clearExports ?? cleanupAccountExportFiles,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final AnswerDraftStore _answerDrafts;
  final ApiClient _client;
  final AuthRepository _auth;
  final TravelDraftStore _drafts;
  final Future<SharedPreferences> Function() _preferences;
  final Future<void> Function() _clearExports;

  Future<Map<String, dynamic>> exportData(
    String password, {
    bool includeImages = true,
  }) async {
    final token = _client.token;
    final result = ApiClient.asMap(
      await _client.mutate(
        'account/export',
        body: {'password': password, 'include_images': includeImages},
      ),
    );
    _checkSession(token);
    return result;
  }

  void _checkSession(String? token) {
    if (token == null || token != _client.token) {
      throw const ApiException('로그인 정보가 변경되었습니다.', code: 'session_changed');
    }
  }

  Future<AccountDeletionResult> deleteAccount({
    required String password,
    required String confirmation,
  }) async {
    final owner = _auth.currentUser;
    final token = _client.token;
    if (owner == null) {
      throw const ApiException('로그인이 필요합니다.', code: 'unauthorized');
    }
    final result = ApiClient.asMap(
      await _client.mutate(
        'account/delete',
        body: {'password': password, 'confirmation': confirmation},
      ),
    );
    _checkSession(token);
    if (result['account_deleted'] != true || result['ok'] != true) {
      throw const ApiException('계정 삭제 결과를 확인할 수 없습니다. 같은 요청으로 다시 시도해주세요.');
    }
    // Clear access immediately on an acknowledged account deletion, including
    // deferred private-file cleanup. The server owns its durable cleanup job.
    await _auth.clearSession();
    var localCleanupComplete = _auth.sessionStorageCleared;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        localCleanupComplete = false;
      }
    }

    await cleanup(() => _drafts.clear(owner.id));
    await cleanup(() => _answerDrafts.clearOwner(owner.id));
    await cleanup(() => _clearExports().timeout(_client.timeout));
    await cleanup(() async {
      final prefs = await _preferences().timeout(_client.timeout);
      // Another login can finish while device cleanup is running.
      if (_auth.currentUser == null &&
          prefs.getString('auth.remembered_email') == owner.email) {
        if (!await prefs
            .remove('auth.remembered_email')
            .timeout(_client.timeout)) {
          localCleanupComplete = false;
        }
      }
    });
    return AccountDeletionResult(
      cleanupPending: result['status'] == 'cleanup_pending',
      localCleanupComplete: localCleanupComplete,
    );
  }
}
