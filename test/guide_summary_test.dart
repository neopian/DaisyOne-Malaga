import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/auth/session_scope.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/guide_summary.dart';
import 'package:local_qa_concierge/shared/models/question.dart';

Map<String, dynamic> _record({
  int accepted = 1,
  int earned = 120,
  int pending = 80,
}) => {
  'accepted_answer_count': accepted,
  'earned_mock_points': earned,
  'pending_mock_points': pending,
  'application_status': 'approved',
  'activity_regions': [
    {'country': 'Spain', 'city': 'Malaga', 'region_name': 'Centro'},
    {'country': 'Spain', 'city': 'Sevilla', 'region_name': null},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('guide DTO uses independent server records, not balance or ratings', () {
    final summary = GuideSummary.fromMap({
      ..._record(),
      'point_balance': 99999,
      'helper_rating_avg': 5,
    });
    expect(summary.acceptedAnswerCount, 1);
    expect(summary.earnedMockPoints, 120);
    expect(summary.pendingMockPoints, 80);
    expect(summary.isApproved, isTrue);
    expect(summary.activityRegions.first.label, 'Spain · Malaga · Centro');
    expect(summary.activityRegions.last.label, 'Spain · Sevilla');
    expect(() => summary.activityRegions.clear(), throwsUnsupportedError);
  });

  test(
    'Málaga aliases are display-only and unknown cities remain untouched',
    () {
      final aliases = [
        const GuideActivityRegion(country: 'Spain', city: 'Malaga'),
        const GuideActivityRegion(country: 'Spain', city: 'Málaga'),
        const GuideActivityRegion(country: '스페인', city: '말라가'),
        const GuideActivityRegion(country: '스페인', city: 'Malaga'),
      ];
      expect(aliases.map((region) => region.displayLabel).toSet(), {
        'Spain · Málaga',
      });
      expect(aliases.first.city, 'Malaga');
      expect(
        const GuideActivityRegion(
          country: 'Spain',
          city: 'Unknown',
        ).displayLabel,
        'Spain · Unknown',
      );
      expect(
        const GuideActivityRegion(
          country: 'Other country',
          city: 'Malaga',
        ).displayLabel,
        'Other country · Malaga',
      );
    },
  );

  test('new guide has genuine zero activity and nullable application', () {
    final summary = GuideSummary.fromMap({
      ..._record(accepted: 0, earned: 0, pending: 0),
      'application_status': null,
      'activity_regions': <dynamic>[],
    });
    expect(summary.acceptedAnswerCount, 0);
    expect(summary.isApproved, isFalse);
    expect(summary.activityRegions, isEmpty);
  });

  for (final field in [
    'accepted_answer_count',
    'earned_mock_points',
    'pending_mock_points',
  ]) {
    for (final badValue in [null, -1, 1.5, '120']) {
      test('$field does not turn malformed $badValue into fabricated zero', () {
        expect(
          () => GuideSummary.fromMap({..._record(), field: badValue}),
          throwsFormatException,
        );
      });
    }
  }

  test('missing regions is an invalid response, not an empty region claim', () {
    final map = _record()..remove('activity_regions');
    expect(() => GuideSummary.fromMap(map), throwsFormatException);
  });

  test('question consumes limited assigned guide DTO when available', () {
    final question = Question.fromMap({
      'assigned_helper_user_id': 'guide',
      'assigned_helper': {..._record(), 'id': 'guide', 'name': '말라가 가이드'},
    });
    expect(question.assignedHelper?.name, '말라가 가이드');
    expect(question.assignedHelper?.acceptedAnswerCount, 1);
    expect(Question.fromMap({}).assignedHelper, isNull);
  });

  test(
    'repository reload uses read-only authenticated guide endpoint and never increments locally',
    () async {
      var accepted = false;
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          expect(request.url.path, '/api/guide/me');
          expect(request.method, 'GET');
          expect(request.headers['Authorization'], 'Bearer guide-session');
          return http.Response(
            jsonEncode(
              accepted
                  ? _record(accepted: 1, earned: 80, pending: 0)
                  : _record(accepted: 0, earned: 0, pending: 80),
            ),
            200,
          );
        }),
      )..token = 'guide-session';
      addTearDown(api.dispose);
      final repo = HelperRepository(api);
      final pending = await repo.fetchGuideSummary();
      expect(pending.pendingMockPoints, 80);
      expect(pending.earnedMockPoints, 0);
      accepted =
          true; // Simulated new server response; ledger correctness is tested in backend.
      for (var retry = 0; retry < 3; retry++) {
        final refreshed = await repo.fetchGuideSummary();
        expect(refreshed.acceptedAnswerCount, 1);
        expect(refreshed.earnedMockPoints, 80);
        expect(refreshed.pendingMockPoints, 0);
      }
    },
  );

  test(
    'guide request rejects a previous account response after account switch',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((_) {
                started.complete();
                return response.future;
              }),
            )
            ..token = 'session-a'
            ..userId = 'guide-a';
      addTearDown(api.dispose);
      final request = HelperRepository(api).fetchGuideSummary();
      final failure = expectLater(
        request,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      await started.future;
      api.token = 'session-b';
      api.userId = 'guide-b';
      response.complete(http.Response(jsonEncode(_record()), 200));
      await failure;
    },
  );

  test('session-scope clearing invalidates cached guide totals', () async {
    var earned = 120;
    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(
        (_) async => http.Response(jsonEncode(_record(earned: earned)), 200),
      ),
    )..token = 'session';
    addTearDown(api.dispose);
    final clear = Provider<void Function()>(
      (ref) =>
          () => invalidateSessionScopedProvidersForRef(ref),
    );
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authStateProvider.overrideWith((ref) => const Stream<AppUser?>.empty()),
      ],
    );
    addTearDown(container.dispose);
    expect(
      (await container.read(guideSummaryProvider.future)).earnedMockPoints,
      120,
    );
    earned = 0;
    container.read(clear)();
    expect(
      (await container.read(guideSummaryProvider.future)).earnedMockPoints,
      0,
    );
  });
  testWidgets(
    'foreground poll refreshes guide records and stops while backgrounded',
    (tester) async {
      var earned = 120;
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(_record(earned: earned)), 200);
        }),
      )..token = 'session';
      final auth = _SignedInAuth(api);
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          authStateProvider.overrideWith(
            (ref) => const Stream<AppUser?>.empty(),
          ),
        ],
      );
      var disposed = false;
      void dispose() {
        if (disposed) return;
        disposed = true;
        container.dispose();
        auth.dispose();
        api.dispose();
      }

      addTearDown(dispose);
      container.listen(guideSummaryProvider, (_, _) {});
      container.listen(questionRealtimeProvider, (_, _) {});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(
        (await container.read(guideSummaryProvider.future)).earnedMockPoints,
        120,
      );
      earned = 200;
      await tester.pump(const Duration(seconds: 15));
      expect(
        (await container.read(guideSummaryProvider.future)).earnedMockPoints,
        200,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausedCalls = calls;
      earned = 280;
      await tester.pump(const Duration(seconds: 30));
      expect(calls, pausedCalls);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        (await container.read(guideSummaryProvider.future)).earnedMockPoints,
        280,
      );
      dispose();
      await tester.pump();
    },
  );
}

class _SignedInAuth extends AuthRepository {
  _SignedInAuth(super.client);
  @override
  AppUser? get currentUser => const AppUser(
    id: 'guide',
    email: 'guide@example.test',
    name: '가이드',
    pointBalance: 1000,
    isAdmin: false,
  );
}
