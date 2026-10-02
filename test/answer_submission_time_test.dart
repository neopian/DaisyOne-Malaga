import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_detail_page.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/question.dart';

const _submissionTime = '답변 작성 · 2025년 12월 31일 23:45:12 (기기 시간 기준)';

Future<void> _mount(
  WidgetTester tester, {
  bool hasCreatedAt = true,
  bool largeText = false,
}) async {
  tester.view.physicalSize = Size(largeText ? 320 : 390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final question = Question.fromMap({
    'id': 'question',
    'user_id': 'traveler',
    'country': 'Spain',
    'city': 'Malaga',
    'title': '공항 버스 승차 위치',
    'body': '버스를 어디에서 타나요?',
    'reward_points': 100,
    'status': 'answered',
    'created_at': '2025-12-31T01:00:00Z',
    'answers': [
      {
        'id': 'answer',
        'question_id': 'question',
        'helper_user_id': 'guide',
        'body': '공항 출구 앞에서 버스를 탈 수 있습니다.',
        'evidence_summary': '공식 교통 안내 페이지를 참고했습니다.',
        'verification_method': '운영 기관 웹사이트 확인',
        'status': 'submitted',
        if (hasCreatedAt)
          'created_at': DateTime(
            2025,
            12,
            31,
            23,
            45,
            12,
          ).toUtc().toIso8601String(),
        'updated_at': '2026-10-02T15:30:00Z',
      },
    ],
  });
  final router = GoRouter(
    initialLocation: '/questions/question',
    routes: [
      GoRoute(
        path: '/questions/:id',
        builder: (_, _) => const QuestionDetailPage(questionId: 'question'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        questionRealtimeProvider.overrideWith((ref) {}),
        helperApplicationProvider.overrideWith((ref) async => null),
        currentProfileProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'traveler',
            email: 'traveler@example.test',
            name: '여행자',
            pointBalance: 1000,
            isAdmin: false,
          ),
        ),
        questionProvider('question').overrideWith((ref) async => question),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(largeText ? 2 : 1)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('답변 작성 시각은 수정 시각 대신 최초 작성 시각을 기기 시간으로 표시한다', (tester) async {
    await _mount(tester);
    await tester.scrollUntilVisible(
      find.text(_submissionTime),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(_submissionTime), findsOneWidget);
    expect(find.textContaining('2026년 10월 2일'), findsNothing);
    expect(find.textContaining('최신 확인'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('작성 시각이 없으면 수정 시각을 대신 사용하지 않는다', (tester) async {
    await _mount(tester, hasCreatedAt: false);
    await tester.scrollUntilVisible(
      find.text('답변 작성 시각 정보 없음'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('답변 작성 시각 정보 없음'), findsOneWidget);
    expect(find.textContaining('2026년 10월 2일'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px 두 배 글자에서도 답변 작성 시각을 줄바꿈한다', (tester) async {
    await _mount(tester, largeText: true);
    await tester.scrollUntilVisible(
      find.text(_submissionTime),
      350,
      maxScrolls: 30,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(_submissionTime), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
