import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/features/helper_application/helper_home_page.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_detail_page.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/guide_summary.dart';
import 'package:local_qa_concierge/shared/models/helper_application.dart';
import 'package:local_qa_concierge/shared/models/question.dart';
import 'package:local_qa_concierge/shared/widgets/guide_activity_card.dart';

const _summary = GuideSummary(
  acceptedAnswerCount: 1,
  earnedMockPoints: 120,
  pendingMockPoints: 80,
  applicationStatus: 'approved',
  activityRegions: [
    GuideActivityRegion(country: 'Spain', city: 'Malaga', regionName: 'Centro'),
  ],
);
const _user = AppUser(
  id: 'guide',
  email: 'guide@example.test',
  name: '가이드',
  pointBalance: 9999,
  isAdmin: false,
);
HelperApplication _application(String status) => HelperApplication(
  id: 'application',
  userId: 'guide',
  status: status,
  languages: const ['ko'],
  introduction: '현지에서 생활해요',
  experienceDescription: '말라가 여행 안내 경험',
);
Question _question({String status = 'open'}) => Question.fromMap({
  'id': 'question',
  'user_id': 'traveler',
  'country': 'Spain',
  'city': 'Malaga',
  'title': '말라가 역에서 버스 타는 곳',
  'body': '현지 교통이 궁금합니다',
  'reward_points': 100,
  'status': status,
  if (status != 'open') 'assigned_helper_user_id': 'guide',
  if (status != 'open')
    'assigned_helper': {
      'id': 'guide',
      'name': '말라가 길잡이',
      'accepted_answer_count': 1,
      'application_status': 'approved',
      'activity_regions': [
        {'country': 'Spain', 'city': 'Malaga', 'region_name': null},
      ],
    },
});

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _home(
  WidgetTester tester, {
  HelperApplication? application,
  Future<GuideSummary> Function()? summary,
  Future<List<Question>> Function()? questions,
}) async {
  final router = GoRouter(
    initialLocation: '/helper/home',
    routes: [
      GoRoute(path: '/helper/home', builder: (_, _) => const HelperHomePage()),
      GoRoute(
        path: '/helper/apply',
        builder: (_, _) => const Scaffold(body: Text('신청 화면')),
      ),
      GoRoute(
        path: '/helper/waiting',
        builder: (_, _) => const Scaffold(body: Text('신청 결과 화면')),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('지도 홈')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        questionRealtimeProvider.overrideWith((ref) {}),
        currentProfileProvider.overrideWith((ref) async => _user),
        guideSummaryProvider.overrideWith(
          (ref) => summary?.call() ?? Future.value(_summary),
        ),
        helperApplicationProvider.overrideWith((ref) async => application),
        helperOpenQuestionsProvider.overrideWith(
          (ref) => questions?.call() ?? Future.value([]),
        ),
      ],
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    '390px guide activity distinguishes accepted, earned, pending and mock status',
    (tester) async {
      await _phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: GuideActivityCard(summary: _summary),
              ),
            ),
          ),
        ),
      );
      expect(find.text('1건'), findsOneWidget);
      expect(find.text('120P'), findsOneWidget);
      expect(find.text('80P'), findsOneWidget);
      expect(find.text('받은 포인트'), findsOneWidget);
      expect(find.text('채택 대기'), findsOneWidget);
      expect(find.textContaining('현금 가치·구매·출금 기능은 없습니다'), findsOneWidget);
      expect(find.textContaining('여행자가 답변을 채택하면'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long registered region and larger text wrap at 320px width', (
    tester,
  ) async {
    await _phone(tester);
    tester.view.physicalSize = const Size(320, 844);
    const longSummary = GuideSummary(
      acceptedAnswerCount: 1234,
      earnedMockPoints: 123456789,
      pendingMockPoints: 99999999,
      applicationStatus: 'approved',
      activityRegions: [
        GuideActivityRegion(
          country: 'Spain',
          city: 'Malaga',
          regionName:
              'Centro histórico, estación de María Zambrano y alrededores',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: GuideActivityCard(summary: longSummary),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty questions retain actual stats and how-to-help instead of an empty screen',
    (tester) async {
      await _phone(tester);
      await _home(tester, application: _application('approved'));
      expect(find.text('1건'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('지금 수락 가능한 질문이 없어요'), 350);
      expect(find.text('지금 수락 가능한 질문이 없어요'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('현지 경험을 도움으로'), 250);
      expect(find.text('현지 경험을 도움으로'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed statistics do not block available questions and retry recovers',
    (tester) async {
      await _phone(tester);
      var attempts = 0;
      await _home(
        tester,
        application: _application('approved'),
        summary: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return _summary;
        },
        questions: () async => [_question()],
      );
      expect(find.text('활동 기록을 불러오지 못했어요'), findsOneWidget);
      expect(find.text('말라가 역에서 버스 타는 곳'), findsOneWidget);
      expect(find.text('0건'), findsNothing);
      await tester.tap(find.text('활동 기록 다시 불러오기'));
      await tester.pumpAndSettle();
      expect(find.text('1건'), findsOneWidget);
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('slow statistics leave independent question feed usable', (
    tester,
  ) async {
    await _phone(tester);
    final result = Completer<GuideSummary>();
    await _home(
      tester,
      application: _application('approved'),
      summary: () => result.future,
      questions: () async => [_question()],
    );
    expect(find.text('로컬 가이드 활동을 불러오는 중'), findsOneWidget);
    expect(find.text('말라가 역에서 버스 타는 곳'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('말라가 역에서 버스 타는 곳')).dy,
      lessThan(350),
      reason: 'Available questions should be visible before activity records.',
    );
    expect(find.text('0건'), findsNothing);
    result.complete(_summary);
    await tester.pumpAndSettle();
    expect(find.text('1건'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final status in <String?>[null, 'pending', 'rejected']) {
    testWidgets('unapproved status $status has no question acceptance feed', (
      tester,
    ) async {
      await _phone(tester);
      var feedCalls = 0;
      await _home(
        tester,
        application: status == null ? null : _application(status),
        questions: () async {
          feedCalls++;
          return [_question()];
        },
      );
      final button = find.text(status == null ? '답변자 신청하기' : '신청 상태 확인');
      await tester.scrollUntilVisible(button, 350);
      expect(feedCalls, 0);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(status == null ? '신청 화면' : '신청 결과 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final userId in ['traveler', 'guide', 'unrelated']) {
    testWidgets(
      'assigned guide record appears only for a question participant: $userId',
      (tester) async {
        await _phone(tester);
        final user = AppUser(
          id: userId,
          email: '$userId@example.test',
          name: '사용자',
          pointBalance: 1000,
          isAdmin: false,
        );
        final router = GoRouter(
          initialLocation: '/questions/question',
          routes: [
            GoRoute(
              path: '/questions/:id',
              builder: (_, _) =>
                  const QuestionDetailPage(questionId: 'question'),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              questionRealtimeProvider.overrideWith((ref) {}),
              currentProfileProvider.overrideWith((ref) async => user),
              helperApplicationProvider.overrideWith(
                (ref) async => _application('approved'),
              ),
              questionProvider(
                'question',
              ).overrideWith((ref) async => _question(status: 'assigned')),
            ],
            child: MaterialApp.router(
              theme: buildAppTheme(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('이 질문의 로컬 가이드'),
          userId == 'unrelated' ? findsNothing : findsOneWidget,
        );
        expect(find.text('1:1로 수락'), findsNothing);
        if (userId != 'unrelated') {
          expect(find.text('말라가 길잡이'), findsOneWidget);
          expect(find.text('채택된 답변 1건'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
