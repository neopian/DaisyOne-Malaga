import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/question.dart';

enum ActivityRole { traveler, guide }

enum ActivityView { active, history }

final activityRepositoryProvider = Provider<ActivityRepository>(
  (ref) => ActivityRepository(ref.watch(apiClientProvider)),
);

class ActivityPageData {
  const ActivityPageData({required this.items, this.nextCursor});

  final List<Question> items;
  final String? nextCursor;
}

/// Participant-only summaries. The detail screen fetches current permissions,
/// body and evidence separately; this list never needs maps or image downloads.
class ActivityRepository {
  const ActivityRepository(this._client);

  final ApiClient _client;

  Future<ActivityPageData> fetchPage({
    required ActivityRole role,
    required ActivityView view,
    String? cursor,
  }) async {
    final path = Uri(
      path: 'activity/questions',
      queryParameters: {
        'role': role.name,
        'view': view.name,
        if (cursor != null) 'cursor': cursor,
      },
    ).toString();
    final result = await _client.getMap(path);
    final rows = result['items'];
    final next = result['next_cursor'];
    if (rows is! List || (next != null && (next is! String || next.isEmpty))) {
      throw const ApiException('질문 목록 응답을 확인하지 못했어요. 다시 시도해주세요.');
    }
    final items = rows
        .map((row) => Question.fromMap(ApiClient.asMap(row)))
        .toList();
    if (items.any((question) => question.id.isEmpty)) {
      throw const ApiException('질문 목록 응답을 확인하지 못했어요. 다시 시도해주세요.');
    }
    return ActivityPageData(items: items, nextCursor: next as String?);
  }

  /// Recovery remains conservative: absence from these recent pages does not
  /// prove that an interrupted creation failed.
  Future<List<Question>> fetchRecentOwnQuestions() async {
    final token = _client.token;
    final owner = _client.userId;
    if (token == null || owner == null) {
      throw const ApiException('로그인이 필요합니다.', status: 401);
    }
    final pages = await Future.wait([
      fetchPage(role: ActivityRole.traveler, view: ActivityView.active),
      fetchPage(role: ActivityRole.traveler, view: ActivityView.history),
    ]);
    if (_client.token != token || _client.userId != owner) {
      throw const ApiException('로그인 정보가 변경되었습니다.', code: 'session_changed');
    }
    final items =
        <String, Question>{
          for (final page in pages)
            for (final question in page.items)
              if (question.userId == owner) question.id: question,
        }.values.toList()..sort((a, b) {
          final byDate = (b.createdAt ?? DateTime(1970)).compareTo(
            a.createdAt ?? DateTime(1970),
          );
          return byDate != 0 ? byDate : b.id.compareTo(a.id);
        });
    return items.take(10).toList();
  }
}
