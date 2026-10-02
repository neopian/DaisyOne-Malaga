import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';

final safetyRepositoryProvider = Provider<SafetyRepository>(
  (ref) => SafetyRepository(ref.watch(apiClientProvider)),
);
final blockedUsersProvider = FutureProvider<List<BlockedUser>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(safetyRepositoryProvider).blockedUsers();
});
final moderationReportsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, status) {
      ref.watch(authStateProvider);
      return ref.watch(safetyRepositoryProvider).reports(status);
    });

class BlockedUser {
  const BlockedUser({required this.id, required this.name});
  final String id;
  final String name;
  factory BlockedUser.fromMap(Map<String, dynamic> map) => BlockedUser(
    id: map['blocked_user_id'] as String,
    name: map['name'] as String? ?? '사용자',
  );
}

class SafetyRepository {
  const SafetyRepository(this._client);
  final ApiClient _client;

  Future<void> report({
    required String targetType,
    required String targetId,
    required String reason,
    String? details,
  }) async {
    await _client.mutate(
      'reports',
      body: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
      },
    );
  }

  Future<List<BlockedUser>> blockedUsers() async =>
      (await _client.getList('blocks')).map(BlockedUser.fromMap).toList();

  Future<void> block(String userId) async {
    await _client.mutate('blocks/${Uri.encodeComponent(userId)}');
  }

  Future<void> unblock(String userId) async {
    await _client.mutate('blocks/${Uri.encodeComponent(userId)}/unblock');
  }

  Future<List<Map<String, dynamic>>> reports(String status) => _client.getList(
    'admin/reports?status=${Uri.encodeQueryComponent(status)}',
  );

  Future<void> review({
    required String reportId,
    required String action,
    String? note,
  }) async {
    await _client.mutate(
      'admin/reports/${Uri.encodeComponent(reportId)}/review',
      body: {
        'action': action,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
  }
}

const reportReasons = <String, String>{
  'harassment': '괴롭힘 · 모욕',
  'hate': '혐오 · 차별',
  'sexual': '성적 콘텐츠',
  'violence': '폭력 · 위협',
  'spam': '스팸 · 광고',
  'privacy': '개인정보 노출',
  'other': '기타',
};
