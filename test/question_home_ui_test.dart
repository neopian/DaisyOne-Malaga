import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_home_page.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/question.dart';

class _OfflineTiles extends TileProvider {
  @override
  ImageProvider getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) => MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAQAAAAEAAQMAAABmvDolAAAAAXNSR0IB2cksfwAAAAlwSFlzAAALEwAACxMBAJqcGAAAAANQTFRF////p8QbyAAAAB9JREFUeJztwQENAAAAwqD3T20ON6AAAAAAAAAAAL4NIQAAAfFnIe4AAAAASUVORK5CYII=',
    ),
  );
}

Question _question({String title = '마드리드 공항에서 시내로 가는 방법'}) => Question.fromMap({
  'id': 'madrid-question',
  'user_id': 'traveler',
  'country': 'Spain',
  'city': 'Madrid',
  'region_name': 'Centro histórico y estación de Atocha',
  'category': '교통',
  'urgency': '보통',
  'title': title,
  'body': '짐이 많아서 공항버스를 타고 싶어요',
  'reward_points': 1234567,
  'status': 'open',
  'latitude': 40.4168,
  'longitude': -3.7038,
  'created_at': '2026-10-02T00:00:00Z',
});

Future<void> _home(
  WidgetTester tester, {
  Future<List<Question>> Function()? questions,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const locationChannel = MethodChannel('flutter.baseflow.com/geolocator');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(locationChannel, (call) async {
        if (call.method == 'isLocationServiceEnabled') return false;
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locationChannel, null);
  });
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => QuestionHomePage(tileProvider: _OfflineTiles()),
      ),
      GoRoute(
        path: '/questions/new',
        builder: (_, _) => const Scaffold(body: Text('질문 작성 화면')),
      ),
      GoRoute(
        path: '/questions/:id',
        builder: (_, _) => const Scaffold(body: Text('질문 상세 화면')),
      ),
      GoRoute(
        path: '/helper/home',
        builder: (_, _) => const Scaffold(body: Text('답변자 화면')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        questionRealtimeProvider.overrideWith((ref) {}),
        questionsProvider.overrideWith(
          (ref) => questions?.call() ?? Future.value([_question()]),
        ),
        currentProfileProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'traveler',
            email: 'traveler@example.test',
            name: '여행자',
            pointBalance: 1000,
            isAdmin: false,
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets(
    'offline map can jump to a US city through local search at double text',
    (tester) async {
      await _home(tester, size: const Size(320, 800), textScale: 2);
      await tester.tap(find.byTooltip('여행할 도시 선택'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travel-city-search')),
        '뉴욕',
      );
      await tester.pump();
      expect(find.text('뉴욕 · New York'), findsOneWidget);
      await tester.tap(find.byType(ListTile).last);
      await tester.pumpAndSettle();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.mapController!.camera.center.longitude, closeTo(-74.006, .1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'question creation remains reachable with GPS off and a loading feed',
    (tester) async {
      final pending = Completer<List<Question>>();
      await _home(tester, questions: () => pending.future);
      expect(find.byTooltip('여행할 도시 선택'), findsOneWidget);
      expect(find.textContaining('위치를 사용할 수 없어'), findsNothing);
      final create = find.byWidgetPredicate((widget) => widget is FilledButton);
      expect(tester.getSize(create).height, greaterThanOrEqualTo(48));
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.text('질문 작성 화면'), findsOneWidget);
      pending.complete([]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search covers question content, clears, and retains detail navigation',
    (tester) async {
      await _home(tester);
      final search = find.byType(TextField);
      await tester.enterText(search, '없는검색어');
      await tester.pump();
      expect(find.text('일치하는 질문이 없어요'), findsOneWidget);
      await tester.enterText(search, '공항버스');
      await tester.pump();
      expect(find.text('마드리드 공항에서 시내로 가는 방법'), findsOneWidget);
      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pump();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      await tester.tap(find.text('마드리드 공항에서 시내로 가는 방법'));
      await tester.pumpAndSettle();
      expect(find.text('질문 상세 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small phone and enlarged text keep map actions usable', (
    tester,
  ) async {
    await _home(tester, size: const Size(320, 568), textScale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('답변자로 전환'));
    await tester.pumpAndSettle();
    expect(find.text('답변자 화면'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wide map preserves a bounded sheet and keyboard-usable expansion',
    (tester) async {
      await _home(tester, size: const Size(1440, 900));
      final create = find.byWidgetPredicate((widget) => widget is FilledButton);
      final initialTop = tester.getTopLeft(create).dy;
      final handle = find.byTooltip('질문 목록 펼치기 또는 접기');
      final handleBody = find
          .descendant(of: handle, matching: find.byType(SizedBox))
          .first;
      Focus.of(tester.element(handleBody)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(create).dy, lessThan(initialTop));
      final tile = find.text('마드리드 공항에서 시내로 가는 방법');
      expect(tester.getSize(tile).width, lessThan(760));
      await tester.tap(find.byTooltip('질문 목록 펼치기 또는 접기'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(create).dy, closeTo(initialTop, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('question card wraps long metadata and reward on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: QuestionCard(
                  question: _question(
                    title: '마드리드 공항에서 아토차역 근처 숙소까지 아이들과 이동하는 방법이 궁금해요',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1,234,567P'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
