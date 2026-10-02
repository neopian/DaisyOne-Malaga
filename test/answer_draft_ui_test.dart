import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/answers/answer_draft_store.dart';
import 'package:local_qa_concierge/features/answers/answer_form_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'answer_draft_store_test.dart' show draft;

class DraftAuth extends AuthRepository {
  DraftAuth(this.api) : super(api, preferences: SharedPreferences.getInstance);
  final ApiClient api;
  String owner = 'user-a';
  @override
  AppUser get currentUser => AppUser(
    id: owner,
    email: '$owner@example.test',
    name: '가이드',
    pointBalance: 0,
    isAdmin: false,
  );
  void switchTo(String value) {
    owner = value;
    api.userId = value;
    api.token = value;
    notifyListeners();
  }
}

class ControllableDrafts extends AnswerDraftStore {
  ControllableDrafts(SharedPreferences preferences)
    : super(
        server: 'https://example.test/api/',
        preferences: () async => preferences,
      );
  final values = <String, Map<String, dynamic>>{};
  Completer<AnswerDraft?>? firstRead;
  bool failReads = false;
  bool failWrites = false;
  String key(String owner, String question) => '$owner|$question';
  @override
  Future<AnswerDraft?> read(String owner, String question) async {
    if (failReads) throw StateError('storage unavailable');
    if (question == 'qA' && firstRead != null) return firstRead!.future;
    final value = values[key(owner, question)];
    return value == null ? null : AnswerDraft.fromJson(value);
  }

  @override
  Future<void> save(String owner, AnswerDraft draft) async {
    if (failWrites) throw StateError('storage unavailable');
    values[key(owner, draft.questionId)] = draft.toJson();
  }

  @override
  Future<void> clear(String owner, String question) async {
    values.remove(key(owner, question));
  }

  @override
  Future<void> completeAttempt(
    String owner,
    String question,
    String requestId,
  ) async {
    final value = values[key(owner, question)];
    if (value != null &&
        AnswerDraft.fromJson(value).pending?.requestId == requestId) {
      values.remove(key(owner, question));
    }
  }

  @override
  Future<void> releaseAttempt(
    String owner,
    AnswerDraft draft,
    String requestId,
  ) async {
    final value = values[key(owner, draft.questionId)];
    if (value != null &&
        AnswerDraft.fromJson(value).pending?.requestId == requestId) {
      await save(owner, draft);
    }
  }
}

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late ApiClient api;
  late DraftAuth auth;
  late ControllableDrafts store;
  late GoRouter router;
  late Future<http.Response> Function(http.Request) handle;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    handle = (_) async => json({'id': 'answer-a'}, 201);
    api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) => handle(request)),
            preferences: () async => preferences,
          )
          ..token = 'user-a'
          ..userId = 'user-a';
    auth = DraftAuth(api);
    store = ControllableDrafts(preferences);
    router = GoRouter(
      initialLocation: '/answers/new/qA',
      routes: [
        GoRoute(
          path: '/answers/new/:id',
          builder: (_, state) =>
              AnswerFormPage(questionId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/questions/:id',
          builder: (_, state) =>
              Scaffold(body: Text('question ${state.pathParameters['id']}')),
        ),
        GoRoute(
          path: '/verify',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.pop(),
              child: const Text('검증에서 돌아가기'),
            ),
          ),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
      ],
    );
  });
  tearDown(() {
    router.dispose();
    auth.dispose();
    api.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          answerDraftStoreProvider.overrideWithValue(store),
          currentProfileProvider.overrideWith((_) async => auth.currentUser),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Future<void> enter(WidgetTester tester, String label, String value) async {
    await tester.ensureVisible(field(label));
    await tester.enterText(field(label), value);
  }

  bool readOnly(WidgetTester tester, String label) => tester
      .widget<TextField>(
        find.descendant(of: field(label), matching: find.byType(TextField)),
      )
      .readOnly;
  Future<void> prepare(WidgetTester tester) async {
    await enter(tester, '답변 본문', '현지에서 공식 안내를 확인한 답변입니다.');
    await enter(tester, '근거 설명', '현재 공식 사이트의 시간표를 확인했습니다.');
    await enter(tester, 'URL', 'https://example.test/timetable');
    await tester.ensureVisible(find.text('근거 추가'));
    await tester.tap(find.text('근거 추가'));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      final checkbox = find.byType(CheckboxListTile).at(i);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('답변 제출'));
  }

  testWidgets(
    'local evidence rejection explains public URLs and preserves input for correction',
    (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();
      await enter(tester, 'URL', 'http://localhost:8080/source');
      await tester.ensureVisible(find.text('근거 추가'));
      await tester.tap(find.text('근거 추가'));
      await tester.pumpAndSettle();
      expect(
        find.text(apiErrorMessage('INVALID_EVIDENCE_URL')),
        findsOneWidget,
      );
      expect(find.byTooltip('삭제'), findsNothing);
      expect(
        tester.widget<TextFormField>(field('URL')).controller!.text,
        'http://localhost:8080/source',
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await enter(tester, 'URL', 'https://example.test/source');
      await tester.ensureVisible(find.text('근거 추가'));
      await tester.tap(find.text('근거 추가'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('삭제'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('URL')).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '320px double-text restores all unsent text and links with fresh confirmations',
    (tester) async {
      await tester.runAsync(() => store.save('user-a', draft(question: 'qA')));
      await mount(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        'A carefully checked answer',
      );
      expect(
        tester.widget<TextFormField>(field('URL')).controller!.text,
        'https://example.test/draft',
      );
      expect(
        tester.widget<TextFormField>(field('근거 제목')).controller!.text,
        'Unfinished title',
      );
      expect(find.text('Timetable'), findsOneWidget);
      for (final check in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(check.value, isFalse);
      }
      expect(readOnly(tester, '답변 본문'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending payload freezes during send and exact retry survives reopen without duplicate',
    (tester) async {
      final first = Completer<http.Response>();
      var requests = 0;
      final keys = <String>[];
      final payloads = <String>[];
      handle = (request) async {
        requests++;
        keys.add(request.headers['Idempotency-Key']!);
        payloads.add(request.body);
        return requests == 1 ? first.future : json({'id': 'answer-a'}, 201);
      };
      await mount(tester);
      await tester.pumpAndSettle();
      await prepare(tester);
      await tester.tap(find.text('답변 제출'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, 1);
      expect(readOnly(tester, '답변 본문'), isTrue);
      for (final checkbox in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(checkbox.onChanged, isNull);
      }
      first.completeError(http.ClientException('ack lost'));
      await tester.pumpAndSettle();
      expect(find.text('같은 요청 다시 확인'), findsOneWidget);
      router.go('/questions/qA');
      await tester.pumpAndSettle();
      router.go('/answers/new/qA');
      await tester.pumpAndSettle();
      expect(readOnly(tester, '답변 본문'), isTrue);
      for (final checkbox in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(checkbox.value, isTrue);
      }
      await tester.ensureVisible(find.text('같은 요청 다시 확인'));
      await tester.tap(find.text('같은 요청 다시 확인'));
      await tester.pumpAndSettle();
      expect(find.text('question qA'), findsOneWidget);
      expect(keys.toSet(), hasLength(1));
      expect(payloads.toSet(), hasLength(1));
      expect(await tester.runAsync(() => store.read('user-a', 'qA')), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'initial definitive rejection unlocks edits but unknown-then-rejected retry stays frozen',
    (tester) async {
      var requests = 0;
      handle = (_) async {
        requests++;
        return requests == 1
            ? json({
                'error': {'code': 'VALIDATION', 'message': 'Fix body'},
              }, 400)
            : throw http.ClientException('offline');
      };
      await mount(tester);
      await tester.pumpAndSettle();
      await prepare(tester);
      await tester.tap(find.text('답변 제출'));
      await tester.pumpAndSettle();
      expect(readOnly(tester, '답변 본문'), isFalse);
      for (final checkbox in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(checkbox.value, isFalse);
      }
      for (var i = 0; i < 3; i++) {
        final check = find.byType(CheckboxListTile).at(i);
        await tester.ensureVisible(check);
        await tester.tap(check);
        await tester.pump();
      }
      await tester.ensureVisible(find.text('답변 제출'));
      await tester.tap(find.text('답변 제출'));
      await tester.pumpAndSettle();
      handle = (_) async => json({
        'error': {'code': 'EMAIL_VERIFICATION_REQUIRED', 'message': 'Verify'},
      }, 403);
      await tester.ensureVisible(find.text('같은 요청 다시 확인'));
      await tester.tap(find.text('같은 요청 다시 확인'));
      await tester.pumpAndSettle();
      expect(readOnly(tester, '답변 본문'), isTrue);
      expect(find.text('같은 요청 다시 확인'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'question change during delayed restore cannot populate the new question',
    (tester) async {
      store.firstRead = Completer<AnswerDraft?>();
      await mount(tester);
      router.go('/answers/new/qB');
      await tester.pumpAndSettle();
      store.firstRead!.complete(
        draft(question: 'qA', body: 'Old question private answer'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        isEmpty,
      );
      await enter(tester, '답변 본문', 'Only question B draft');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        (await tester.runAsync(() => store.read('user-a', 'qB')))?.body,
        'Only question B draft',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'old submit acknowledgement clears old attempt without navigating a new question',
    (tester) async {
      final response = Completer<http.Response>();
      handle = (_) => response.future;
      await mount(tester);
      await tester.pumpAndSettle();
      await prepare(tester);
      await tester.tap(find.text('답변 제출'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      router.go('/answers/new/qB');
      await tester.pumpAndSettle();
      response.complete(json({'id': 'answer-a'}, 201));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/answers/new/qB');
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        isEmpty,
      );
      expect(await tester.runAsync(() => store.read('user-a', 'qA')), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'verification push/pop keeps visible text; back saves while account switching clears it',
    (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();
      await enter(tester, '답변 본문', 'Unsaved local answer for A');
      unawaited(router.push('/verify'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('검증에서 돌아가기'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        'Unsaved local answer for A',
      );
      await tester.tap(find.byTooltip('질문으로 돌아가기'));
      await tester.pumpAndSettle();
      router.go('/answers/new/qA');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        'Unsaved local answer for A',
      );
      auth.switchTo('user-b');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('답변 본문')).controller!.text,
        isEmpty,
      );
      expect(
        (await tester.runAsync(() => store.read('user-a', 'qA')))?.body,
        'Unsaved local answer for A',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('read failure locks overwrite and recovers with explicit retry', (
    tester,
  ) async {
    store.failReads = true;
    await mount(tester);
    await tester.pumpAndSettle();
    expect(readOnly(tester, '답변 본문'), isTrue);
    expect(find.text('임시 저장 다시 불러오기'), findsOneWidget);
    store.failReads = false;
    await tester.tap(find.text('임시 저장 다시 불러오기'));
    await tester.pumpAndSettle();
    expect(readOnly(tester, '답변 본문'), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'failed pending storage sends nothing and exact retry succeeds after recovery',
    (tester) async {
      var requests = 0;
      handle = (_) async {
        requests++;
        return json({'id': 'answer-a'}, 201);
      };
      await mount(tester);
      await tester.pumpAndSettle();
      await prepare(tester);
      store.failWrites = true;
      await tester.tap(find.text('답변 제출'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(readOnly(tester, '답변 본문'), isTrue);
      expect(find.textContaining('임시 저장 실패'), findsOneWidget);
      store.failWrites = false;
      await tester.ensureVisible(find.text('같은 요청 다시 확인'));
      await tester.tap(find.text('같은 요청 다시 확인'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('question qA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
