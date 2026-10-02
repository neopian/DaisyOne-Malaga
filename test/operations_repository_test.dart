import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/admin/operations_repository.dart';

import 'operations_test_support.dart';

void main() {
  test(
    'operations encodes country, city and opaque cursor and reads real flags',
    () async {
      late Uri requested;
      final client = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'items': [
                operationsRow(
                  'restricted',
                  status: OperationsStatus.assigned,
                  restricted: true,
                ),
              ],
              'next_cursor': 'next',
              'summary': {
                'open_count': 42,
                'assigned_count': 8,
                'answered_count': 3,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      )..token = 'session';
      addTearDown(client.dispose);
      final page = await OperationsRepository(client).fetchPage(
        status: OperationsStatus.assigned,
        city: CityCatalog.findCity('France', 'Paris'),
        cursor: 'opaque+/=&value',
      );
      expect(requested.path, '/api/admin/operations/questions');
      expect(requested.queryParameters, {
        'status': 'assigned',
        'country': 'France',
        'city': 'Paris',
        'cursor': 'opaque+/=&value',
      });
      expect(page.items.single.flags, [
        '질문 숨김',
        '여행자 이용 제한',
        '가이드 이용 제한',
        '가이드 승인 없음',
        '참여자 간 차단',
      ]);
      expect(page.summary.count(OperationsStatus.open), 42);
      expect(
        page.items.single.updatedAt.toIso8601String(),
        '2026-10-02T03:00:00.000Z',
      );
    },
  );

  for (final malformed in [
    'missing_summary',
    'null_count',
    'negative_count',
    'missing_flag',
    'bad_timestamp',
    'missing_items',
    'empty_cursor',
  ]) {
    test(
      '$malformed fails without fabricating empty rows or zero counts',
      () async {
        final row = operationsRow('question');
        final summary = <String, dynamic>{
          'open_count': 42,
          'assigned_count': 8,
          'answered_count': 3,
        };
        final response = <String, dynamic>{
          'items': [row],
          'next_cursor': null,
          'summary': summary,
        };
        switch (malformed) {
          case 'missing_summary':
            response.remove('summary');
          case 'null_count':
            summary['open_count'] = null;
          case 'negative_count':
            summary['answered_count'] = -1;
          case 'missing_flag':
            (row['operational_flags'] as Map).remove('participants_blocked');
          case 'bad_timestamp':
            row['created_at'] = 'not a date';
          case 'missing_items':
            response.remove('items');
          case 'empty_cursor':
            response['next_cursor'] = '';
        }
        final client = ApiClient(
          baseUrl: 'https://example.test/api',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(response),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        )..token = 'session';
        addTearDown(client.dispose);
        await expectLater(
          OperationsRepository(client).fetchPage(status: OperationsStatus.open),
          throwsA(isA<ApiException>()),
        );
      },
    );
  }
}
