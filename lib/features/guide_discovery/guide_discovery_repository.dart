import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/question.dart';

final guideDiscoveryRepositoryProvider = Provider<GuideDiscoveryRepository>(
  (ref) => GuideDiscoveryRepository(ref.watch(apiClientProvider)),
);

class GuideDiscoveryPageData {
  const GuideDiscoveryPageData({required this.items, this.nextCursor});

  final List<Question> items;
  final String? nextCursor;
}

/// Eligibility and ordering belong to the server. Discovery reads only compact
/// summaries; opening a question separately rechecks current claim permissions.
class GuideDiscoveryRepository {
  const GuideDiscoveryRepository(this._client);

  final ApiClient _client;
  static const _summaryFields = {
    'id',
    'user_id',
    'assigned_helper_user_id',
    'country',
    'city',
    'region_name',
    'category',
    'urgency',
    'title',
    'reward_points',
    'status',
    'created_at',
    'updated_at',
    'expires_at',
  };

  Future<GuideDiscoveryPageData> fetchPage({String? cursor}) async {
    final result = await _client.get(
      Uri(
        path: 'guide/discovery',
        queryParameters: cursor == null ? null : {'cursor': cursor},
      ).toString(),
    );
    const invalid = ApiException(
      '질문 목록 응답을 확인하지 못했어요. 다시 시도해주세요.',
      code: 'INVALID_DISCOVERY_RESPONSE',
    );
    if (result is! Map) throw invalid;
    final rows = result['items'];
    final next = result['next_cursor'];
    if (rows is! List ||
        rows.length > 20 ||
        (next != null && (next is! String || next.isEmpty || rows.isEmpty))) {
      throw invalid;
    }
    final items = <Question>[];
    try {
      for (final row in rows) {
        final data = ApiClient.asMap(row);
        final question = Question.fromMap({
          for (final key in _summaryFields)
            if (data.containsKey(key)) key: data[key],
        });
        if (question.id.isEmpty || question.userId.isEmpty) throw invalid;
        items.add(question);
      }
    } catch (_) {
      throw invalid;
    }
    return GuideDiscoveryPageData(
      items: List.unmodifiable(items),
      nextCursor: next as String?,
    );
  }
}
