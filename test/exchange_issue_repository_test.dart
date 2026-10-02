import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'exchange_issue_test_support.dart';

http.Response jsonResponse(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ExchangeIssueRepository repositoryFor(
    Future<http.Response> Function(http.Request) response,
  ) {
    final client = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(response),
    )..token = 'session';
    addTearDown(client.dispose);
    return ExchangeIssueRepository(client);
  }

  for (final view in ExchangeIssueView.values) {
    test(
      '${view.name} uses only its endpoint and encodes opaque cursor',
      () async {
        late http.Request requested;
        final repository = repositoryFor((request) async {
          requested = request;
          final row = switch (view) {
            ExchangeIssueView.eligible => eligibleExchangeRow('question'),
            ExchangeIssueView.mine => exchangeIssueRow('issue'),
            _ => adminExchangeIssueRow(
              'issue',
              status: view == ExchangeIssueView.adminOpen ? 'open' : 'reviewed',
            ),
          };
          return jsonResponse({
            'items': [row],
            'next_cursor': 'next',
          });
        });
        final page = await repository.fetchPage(
          view: view,
          cursor: 'opaque+/=&value ? 한글',
        );
        expect(requested.method, 'GET');
        expect(requested.headers['Authorization'], 'Bearer session');
        expect(requested.url.path, switch (view) {
          ExchangeIssueView.eligible => '/api/exchange-issues/eligible',
          ExchangeIssueView.mine => '/api/exchange-issues',
          _ => '/api/admin/exchange-issues',
        });
        expect(requested.url.queryParameters, {
          if (view.isAdmin)
            'status': view == ExchangeIssueView.adminOpen ? 'open' : 'reviewed',
          'cursor': 'opaque+/=&value ? 한글',
        });
        expect(page.nextCursor, 'next');
        expect(page.items, hasLength(1));
        expect(() => page.items.clear(), throwsUnsupportedError);
      },
    );
  }

  test(
    'hidden eligible reference drops title but retains own issue link',
    () async {
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'items': [
            {
              ...eligibleExchangeRow(
                'hidden-question',
                contentAvailable: false,
                ownIssueId: 'my-hidden-issue',
              ),
              'title': 'must never be exposed',
              'body': 'private full question',
              'photo_url': 'https://example.test/private.jpg',
            },
          ],
        }),
      );
      final page = await repository.fetchPage(view: ExchangeIssueView.eligible);
      final row = page.items.single as EligibleExchange;
      expect(row.questionId, 'hidden-question');
      expect(row.title, isNull);
      expect(row.contentAvailable, isFalse);
      expect(row.ownIssueId, 'my-hidden-issue');
      expect(row.roleLabel, '여행자');
    },
  );

  test('participant list and exact GET never retain admin metadata', () async {
    final requests = <http.Request>[];
    final row = adminExchangeIssueRow(
      'own/issue?ref=1',
      status: 'reviewed',
      reviewNote: 'private operator note',
    );
    final repository = repositoryFor((request) async {
      requests.add(request);
      return jsonResponse(
        requests.length == 1
            ? {
                'items': [row],
              }
            : row,
      );
    });
    final page = await repository.fetchPage(view: ExchangeIssueView.mine);
    final direct = await repository.fetchOwn('own/issue?ref=1');
    for (final record in [page.items.single, direct]) {
      expect(record.runtimeType, ExchangeIssueRecord);
      expect(record, isNot(isA<AdminExchangeIssueRecord>()));
      expect((record as ExchangeIssueRecord).details, '비공개 진행 내용');
      expect(record.statusLabel, '검토 표시됨');
    }
    expect(requests.last.url.pathSegments, [
      'api',
      'exchange-issues',
      'own/issue?ref=1',
    ]);
    expect(requests.last.url.queryParameters, isEmpty);
  });

  test(
    'admin page retains the private review note only in admin type',
    () async {
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'items': [
            adminExchangeIssueRow(
              'issue',
              status: 'reviewed',
              reviewNote: '운영자 기록',
            ),
          ],
        }),
      );
      final page = await repository.fetchPage(
        view: ExchangeIssueView.adminReviewed,
      );
      final row = page.items.single as AdminExchangeIssueRecord;
      expect(row.reporterId, 'reporter');
      expect(row.otherParticipantId, 'other-participant');
      expect(row.reviewedBy, 'admin');
      expect(row.reviewNote, '운영자 기록');
    },
  );

  for (final details in ['  상황 설명  ', ' \n ']) {
    test(
      'create sends only question, reason and nonempty trimmed details ($details)',
      () async {
        late http.Request requested;
        final repository = repositoryFor((request) async {
          requested = request;
          return jsonResponse({'id': 'created-issue'});
        });
        final id = await repository.create(
          questionId: 'question',
          reason: ExchangeIssueReason.cannotContinue,
          details: details,
        );
        expect(id, 'created-issue');
        expect(requested.method, 'POST');
        expect(requested.url.path, '/api/exchange-issues');
        expect(jsonDecode(requested.body), {
          'question_id': 'question',
          'reason': 'cannot_continue',
          if (details.trim().isNotEmpty) 'details': details.trim(),
        });
        expect(requested.headers['Idempotency-Key'], isNotEmpty);
      },
    );
  }

  for (final note in ['  운영자 비공개 메모  ', ' \n ']) {
    test('review sends only optional private note ($note)', () async {
      late http.Request requested;
      final repository = repositoryFor((request) async {
        requested = request;
        return jsonResponse({'ok': true});
      });
      await repository.review('issue/with?separator', note);
      expect(requested.method, 'POST');
      expect(requested.url.pathSegments, [
        'api',
        'admin',
        'exchange-issues',
        'issue/with?separator',
        'review',
      ]);
      expect(requested.url.queryParameters, isEmpty);
      expect(jsonDecode(requested.body), {
        if (note.trim().isNotEmpty) 'note': note.trim(),
      });
    });
  }

  for (final malformed in [
    'missing_items',
    'nonlist_items',
    'nonmap_row',
    'empty_cursor',
    'numeric_cursor',
    'missing_id',
    'blank_question',
    'bad_role',
    'bad_reason',
    'bad_status',
    'bad_details',
    'bad_created_at',
    'bad_reviewed_at',
  ]) {
    test('rejects malformed participant page: $malformed', () async {
      final row = exchangeIssueRow('issue');
      final response = <String, dynamic>{
        'items': [row],
      };
      switch (malformed) {
        case 'missing_items':
          response.remove('items');
        case 'nonlist_items':
          response['items'] = {};
        case 'nonmap_row':
          response['items'] = ['invalid'];
        case 'empty_cursor':
          response['next_cursor'] = '';
        case 'numeric_cursor':
          response['next_cursor'] = 3;
        case 'missing_id':
          row.remove('id');
        case 'blank_question':
          row['question_id'] = ' ';
        case 'bad_role':
          row['role'] = 'admin';
        case 'bad_reason':
          row['reason'] = 'refund';
        case 'bad_status':
          row['status'] = 'resolved';
        case 'bad_details':
          row['details'] = {'body': 'invalid'};
        case 'bad_created_at':
          row['created_at'] = 'not a date';
        case 'bad_reviewed_at':
          row['reviewed_at'] = 'not a date';
      }
      final repository = repositoryFor((_) async => jsonResponse(response));
      await expectLater(
        repository.fetchPage(view: ExchangeIssueView.mine),
        throwsA(isA<ApiException>()),
      );
    });
  }

  for (final malformed in [
    'visibility',
    'status',
    'title',
    'own_issue',
    'timestamp',
  ]) {
    test('rejects malformed eligible page: $malformed', () async {
      final row = eligibleExchangeRow('question');
      switch (malformed) {
        case 'visibility':
          row['content_available'] = 'true';
        case 'status':
          row['status'] = 'open';
        case 'title':
          row['title'] = 3;
        case 'own_issue':
          row['own_issue_id'] = 3;
        case 'timestamp':
          row['updated_at'] = null;
      }
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'items': [row],
        }),
      );
      await expectLater(
        repository.fetchPage(view: ExchangeIssueView.eligible),
        throwsA(isA<ApiException>()),
      );
    });
  }

  for (final field in [
    'reporter_id',
    'other_participant_id',
    'reviewed_by',
    'review_note',
  ]) {
    test('rejects malformed admin field $field', () async {
      final row = adminExchangeIssueRow('issue')..[field] = 17;
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'items': [row],
        }),
      );
      await expectLater(
        repository.fetchPage(view: ExchangeIssueView.adminOpen),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test(
    'mutation acknowledgements require valid id and true review result',
    () async {
      final repository = repositoryFor(
        (_) async => jsonResponse({'id': '', 'ok': false}),
      );
      await expectLater(
        repository.create(
          questionId: 'question',
          reason: ExchangeIssueReason.other,
          details: '',
        ),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        repository.review('issue', ''),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'backend cursor and conflict codes remain available to recovery state',
    () async {
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'error': {
            'code': 'INVALID_EXCHANGE_ISSUES_CURSOR',
            'message': 'invalid',
          },
        }, 400),
      );
      await expectLater(
        repository.fetchPage(view: ExchangeIssueView.mine, cursor: 'expired'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_EXCHANGE_ISSUES_CURSOR',
          ),
        ),
      );
      expect(
        exchangeIssueErrorText(
          const ApiException('invalid', code: 'INVALID_EXCHANGE_ISSUES_CURSOR'),
        ),
        '목록을 처음부터 다시 확인해주세요.',
      );
    },
  );

  for (final contentAvailable in [true, false]) {
    test(
      'direct eligible reference encodes only the exact question and redacts hidden title ($contentAvailable)',
      () async {
        final requests = <http.Request>[];
        const questionId = 'question/with?cursor=secret&한글';
        final repository = repositoryFor((request) async {
          requests.add(request);
          return jsonResponse({
            ...eligibleExchangeRow(
              questionId,
              contentAvailable: contentAvailable,
              ownIssueId: 'my-existing-issue',
            ),
            'title': 'private question title',
            'body': 'full question must not be retained',
            'review_note': 'admin note must not be retained',
          });
        });
        final row = await repository.fetchEligible(questionId);
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.url.pathSegments, [
          'api',
          'exchange-issues',
          'eligible',
          questionId,
        ]);
        expect(requests.single.url.queryParameters, isEmpty);
        expect(row.questionId, questionId);
        expect(row.contentAvailable, contentAvailable);
        expect(row.title, contentAvailable ? 'private question title' : isNull);
        expect(row.ownIssueId, 'my-existing-issue');
        expect(row.runtimeType, EligibleExchange);
      },
    );
  }

  test('direct eligible reference rejects malformed availability', () async {
    final repository = repositoryFor(
      (_) async => jsonResponse({
        ...eligibleExchangeRow('question'),
        'content_available': 'false',
      }),
    );
    await expectLater(
      repository.fetchEligible('question'),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'record 404 is preserved but does not mean global access failure',
    () async {
      final repository = repositoryFor(
        (_) async => jsonResponse({
          'error': {'code': 'NOT_FOUND', 'message': 'record removed'},
        }, 404),
      );
      await expectLater(
        repository.fetchOwn('removed-issue'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.status, 'status', 404)
              .having(
                (error) => exchangeIssueAccessFailure(error),
                'global access failure',
                isFalse,
              ),
        ),
      );
      await expectLater(
        repository.fetchEligible('removed-question'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.status, 'status', 404)
              .having(
                (error) => exchangeIssueAccessFailure(error),
                'global access failure',
                isFalse,
              ),
        ),
      );
    },
  );
}
