import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/city_catalog.g.dart';
import '../../core/services/api_service.dart';

enum OperationsStatus {
  open('답변자 대기'),
  assigned('가이드 답변 대기'),
  answered('여행자 검토 대기');

  const OperationsStatus(this.label);
  final String label;
}

final operationsRepositoryProvider = Provider<OperationsRepository>(
  (ref) => OperationsRepository(ref.watch(apiClientProvider)),
);

const _invalidResponse = ApiException('응답 대기 현황을 확인하지 못했어요. 다시 시도해주세요.');

class OperationsSummary {
  const OperationsSummary({
    required this.openCount,
    required this.assignedCount,
    required this.answeredCount,
  });

  final int openCount;
  final int assignedCount;
  final int answeredCount;

  int count(OperationsStatus status) => switch (status) {
    OperationsStatus.open => openCount,
    OperationsStatus.assigned => assignedCount,
    OperationsStatus.answered => answeredCount,
  };

  factory OperationsSummary.fromMap(Map<String, dynamic> map) {
    int count(String key) {
      final value = map[key];
      if (value is! int || value < 0) throw _invalidResponse;
      return value;
    }

    return OperationsSummary(
      openCount: count('open_count'),
      assignedCount: count('assigned_count'),
      answeredCount: count('answered_count'),
    );
  }
}

/// Only the compact, authorized operations response lives in this model.
/// Bodies, media, contact information and participant identities are not kept.
class OperationsQuestion {
  const OperationsQuestion({
    required this.id,
    required this.title,
    required this.country,
    required this.city,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.flags,
  });

  final String id;
  final String title;
  final String country;
  final String city;
  final OperationsStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> flags;

  factory OperationsQuestion.fromMap(Map<String, dynamic> map) {
    String text(String key) {
      final value = map[key];
      if (value is! String || value.trim().isEmpty) throw _invalidResponse;
      return value;
    }

    DateTime timestamp(String key) {
      final value = DateTime.tryParse(text(key));
      if (value == null) throw _invalidResponse;
      return value;
    }

    final status = OperationsStatus.values
        .where((value) => value.name == map['status'])
        .firstOrNull;
    final rawFlags = map['operational_flags'];
    if (status == null || rawFlags is! Map) throw _invalidResponse;
    const labels = {
      'question_hidden': '질문 숨김',
      'traveler_suspended': '여행자 이용 제한',
      'guide_suspended': '가이드 이용 제한',
      'guide_application_restricted': '가이드 승인 없음',
      'participants_blocked': '참여자 간 차단',
    };
    final flags = <String>[];
    for (final entry in labels.entries) {
      if (rawFlags[entry.key] is! bool) throw _invalidResponse;
      if (rawFlags[entry.key] == true) flags.add(entry.value);
    }
    return OperationsQuestion(
      id: text('id'),
      title: text('title'),
      country: text('country'),
      city: text('city'),
      status: status,
      createdAt: timestamp('created_at'),
      updatedAt: timestamp('updated_at'),
      flags: List.unmodifiable(flags),
    );
  }
}

class OperationsPageData {
  const OperationsPageData({
    required this.items,
    required this.summary,
    this.nextCursor,
  });

  final List<OperationsQuestion> items;
  final OperationsSummary summary;
  final String? nextCursor;
}

class OperationsRepository {
  const OperationsRepository(this._client);
  final ApiClient _client;

  Future<OperationsPageData> fetchPage({
    required OperationsStatus status,
    TravelCity? city,
    String? cursor,
  }) async {
    final path = Uri(
      path: 'admin/operations/questions',
      queryParameters: {
        'status': status.name,
        if (city != null) 'country': city.country,
        if (city != null) 'city': city.city,
        if (cursor != null) 'cursor': cursor,
      },
    ).toString();
    final response = await _client.getMap(path);
    final rows = response['items'];
    final next = response['next_cursor'];
    if (rows is! List ||
        response['summary'] is! Map ||
        (next != null && (next is! String || next.isEmpty))) {
      throw _invalidResponse;
    }
    return OperationsPageData(
      items: rows
          .map((row) => OperationsQuestion.fromMap(ApiClient.asMap(row)))
          .toList(growable: false),
      summary: OperationsSummary.fromMap(ApiClient.asMap(response['summary'])),
      nextCursor: next as String?,
    );
  }
}
