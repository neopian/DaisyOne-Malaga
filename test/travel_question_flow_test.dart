import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/core/services/location_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/create_question_page.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/features/questions/travel_draft_store.dart';
import 'package:local_qa_concierge/features/questions/travel_location_section.dart';
import 'package:local_qa_concierge/features/questions/travel_question_support.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/question.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'travel_draft_store_test.dart' show travelDraftFixture;

const _owner = AppUser(
  id: 'user-a',
  email: 'a@example.test',
  name: '여행자',
  pointBalance: 1000,
  isAdmin: false,
);
const _other = AppUser(
  id: 'user-b',
  email: 'b@example.test',
  name: '다른 여행자',
  pointBalance: 1000,
  isAdmin: false,
);
const _gpsMadrid = DeviceLocation(
  country: 'Spain',
  city: 'Madrid',
  latitude: 40.4168,
  longitude: -3.7038,
);
const _titleKey = ValueKey('question-title');
const _bodyKey = ValueKey('question-body');
const _rewardKey = ValueKey('question-reward');

class _TestAuth extends AuthRepository {
  _TestAuth(super.client);
  AppUser? user = _owner;
  @override
  AppUser? get currentUser => user;
  void changeUser(AppUser? next) {
    user = next;
    notifyListeners();
  }
}

class _Questions extends QuestionRepository {
  _Questions(super.client);
  final calls = <Map<String, Object?>>[];
  Future<String> Function()? createResult;
  List<Question> visible = [];
  @override
  Future<List<Question>> fetchVisibleQuestions() async => visible;
  @override
  Future<String> createQuestion({
    required String title,
    required String body,
    required String country,
    required String city,
    required String? regionName,
    required String category,
    required String urgency,
    required int rewardPoints,
    required double latitude,
    required double longitude,
    required List<XFile> images,
    String? requestId,
  }) async {
    calls.add({
      'title': title,
      'body': body,
      'country': country,
      'city': city,
      'region': regionName,
      'category': category,
      'urgency': urgency,
      'reward': rewardPoints,
      'latitude': latitude,
      'longitude': longitude,
      'images': images.map((image) => image.path).toList(),
      'requestId': requestId,
    });
    return createResult == null ? 'question-saved' : await createResult!();
  }
}

class _WriteFailingStore extends TravelDraftStore {
  _WriteFailingStore() : super(server: 'test-server');
  @override
  Future<TravelQuestionDraft?> read(String ownerId) async => null;
  @override
  Future<void> save(String ownerId, TravelQuestionDraft draft) async =>
      throw StateError('storage full');
}

class _Harness {
  _Harness({
    Future<DeviceLocation> Function()? location,
    TravelDraftStore? store,
  }) : location = location ?? (() async => throw StateError('위치 권한이 필요합니다.')),
       store = store ?? TravelDraftStore(server: 'test-server') {
    api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient((_) async => throw StateError('unexpected HTTP')),
    );
    auth = _TestAuth(api);
    questions = _Questions(api);
    router = GoRouter(
      initialLocation: '/questions/new',
      routes: [
        GoRoute(
          path: '/questions/new',
          builder: (_, _) => const CreateQuestionPage(),
        ),
        GoRoute(
          path: '/questions/:id',
          builder: (_, state) =>
              Scaffold(body: Text('등록 완료 ${state.pathParameters['id']}')),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('내 질문 목록')),
        ),
      ],
    );
  }
  late final ApiClient api;
  late final _TestAuth auth;
  late final _Questions questions;
  late final GoRouter router;
  final TravelDraftStore store;
  final Future<DeviceLocation> Function() location;

  Future<void> mount(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          currentProfileProvider.overrideWith((ref) async => auth.currentUser!),
          questionRepositoryProvider.overrideWithValue(questions),
          questionLocationLoaderProvider.overrideWithValue(location),
          travelDraftStoreProvider.overrideWithValue(store),
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
    await tester.pump(const Duration(milliseconds: 30));
  }

  void cleanup(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
      auth.dispose();
      api.dispose();
    });
  }
}

String _field(WidgetTester tester, Key key) =>
    tester.widget<TextFormField>(find.byKey(key)).controller!.text;
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _enter(WidgetTester tester, Key key, String text) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.enterText(find.byKey(key), text);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _selectCity(WidgetTester tester, String city) async {
  await _tap(tester, find.byKey(const ValueKey('travel-city-select')));
  await tester.enterText(
    find.byKey(const ValueKey('travel-city-search')),
    city,
  );
  await tester.pump();
  await _tap(tester, find.byType(ListTile).last);
}

Future<void> _selectMalaga(WidgetTester tester) => _selectCity(tester, '말라가');

Future<void> _fill(WidgetTester tester) async {
  await _selectMalaga(tester);
  await _enter(tester, _titleKey, '공항에서 시내 이동');
  await _enter(tester, _bodyKey, '도착 시각은 밤 10시이고 가방이 두 개 있습니다.');
  await _enter(tester, _rewardKey, '150');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'GPS denial leaves manual city selection and never loads a map implicitly',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      await h.mount(tester);
      expect(find.textContaining('위치 권한 없이도'), findsOneWidget);
      await _selectMalaga(tester);
      expect(find.text('스페인 · 말라가 · Málaga'), findsOneWidget);
      expect(find.textContaining('도시 중심에 표시'), findsOneWidget);
      expect(find.byKey(const ValueKey('travel-map-Málaga')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'traveler outside a catalog city can plan a European city without GPS',
    (tester) async {
      final h = _Harness(
        location: () async => throw StateError('선택 가능한 도시에서 멀리 떨어져 있습니다.'),
      )..cleanup(tester);
      await h.mount(tester);
      expect(find.textContaining('여행지 밖에 있어도'), findsOneWidget);
      await _selectMalaga(tester);
      expect(find.text('스페인 · 말라가 · Málaga'), findsOneWidget);
    },
  );

  testWidgets(
    'a US destination can be selected offline and submitted with canonical location',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      await h.mount(tester);
      await _selectCity(tester, '뉴욕');
      expect(find.text('미국 · 뉴욕 · New York'), findsOneWidget);
      await _enter(tester, _titleKey, '공항에서 맨해튼 이동');
      await _enter(tester, _bodyKey, '저녁에 도착합니다. 짐 두 개와 이용할 교통편이 궁금해요.');
      await _enter(tester, _rewardKey, '100');
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls.single['country'], 'United States');
      expect(h.questions.calls.single['city'], 'New York');
      expect(h.questions.calls.single['longitude'], lessThan(-70));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual selection wins over a late GPS success', (tester) async {
    final gps = Completer<DeviceLocation>();
    final h = _Harness(location: () => gps.future)..cleanup(tester);
    await h.mount(tester);
    await _selectMalaga(tester);
    gps.complete(_gpsMadrid);
    await tester.pumpAndSettle();
    expect(find.text('스페인 · 말라가 · Málaga'), findsOneWidget);
    expect(find.text('스페인 · 마드리드 · Madrid'), findsNothing);
  });

  testWidgets(
    'GPS retry preserves entered text, reward, manual city and selected photo',
    (tester) async {
      const imageChannel = MethodChannel('plugins.flutter.io/image_picker');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        imageChannel,
        (_) async => ['/fake/travel-photo.jpg'],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          imageChannel,
          null,
        ),
      );
      final h = _Harness()..cleanup(tester);
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.text('사진 첨부'));
      expect(find.text('사진 1장 선택됨'), findsOneWidget);
      await _tap(tester, find.text('내 위치 사용'));
      expect(_field(tester, _titleKey), '공항에서 시내 이동');
      expect(_field(tester, _bodyKey), contains('가방이 두 개'));
      expect(_field(tester, _rewardKey), '150');
      expect(find.text('사진 1장 선택됨'), findsOneWidget);
      expect(find.text('스페인 · 말라가 · Málaga'), findsOneWidget);
    },
  );

  testWidgets(
    'starters never overwrite typed text unless replace is confirmed',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      await h.mount(tester);
      await _tap(tester, find.byKey(const ValueKey('question-starters')));
      await _tap(tester, find.text('공항 이동'));
      expect(_field(tester, _titleKey), travelQuestionStarters.first.title);
      await _enter(tester, _titleKey, '내가 작성한 제목');
      await _enter(tester, _bodyKey, '여행 중 직접 작성한 내용을 유지합니다.');
      await _tap(tester, find.text('현지 언어 도움'));
      await _tap(tester, find.text('유지하기'));
      expect(_field(tester, _titleKey), '내가 작성한 제목');
      expect(_field(tester, _bodyKey), '여행 중 직접 작성한 내용을 유지합니다.');
      await _tap(tester, find.text('현지 언어 도움'));
      await _tap(tester, find.text('예시로 바꾸기'));
      expect(_field(tester, _bodyKey), travelQuestionStarters.last.body);
      expect(
        find.byKey(const ValueKey('question-category-번역')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'timeout freezes exact payload and operation ID for explicit same-screen retry',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      var attempts = 0;
      h.questions.createResult = () async {
        if (++attempts == 1) throw const ApiException('연결 지연', code: 'timeout');
        return 'question-saved';
      };
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls.length, 1);
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isFalse,
      );
      expect(find.text('같은 요청 다시 확인'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls.length, 2);
      expect(h.questions.calls.first, h.questions.calls.last);
      expect(h.questions.calls.first['requestId'], isNotEmpty);
      expect(find.text('등록 완료 question-saved'), findsOneWidget);
      expect(await h.store.read(_owner.id), isNull);
    },
  );

  for (final failure in <Object>[
    const ApiException('로그인 필요', status: 401),
    const ApiException('요청 시간 초과', status: 408),
    const ApiException('처리 중', status: 409),
    const ApiException('잠시 후 다시 시도', status: 429),
    const ApiException('서버 오류', status: 500),
    const ApiException('저장 공간 오류', code: 'storage'),
    const ApiException('뒤늦은 입력 오류', code: 'VALIDATION', status: 400),
    const ApiException('재시도 사진을 읽을 수 없음', code: 'invalid_image'),
    const ApiException('응답을 읽을 수 없음', status: 200),
    const FormatException('malformed response'),
  ]) {
    testWidgets(
      'lost acknowledgement then $failure keeps the same frozen operation',
      (tester) async {
        final h = _Harness()..cleanup(tester);
        var attempt = 0;
        h.questions.createResult = () async {
          attempt++;
          if (attempt == 1) {
            throw const ApiException('첫 응답 유실', code: 'timeout');
          }
          if (attempt == 2) throw failure;
          return 'question-saved';
        };
        await h.mount(tester);
        await _fill(tester);
        await _tap(tester, find.byKey(const ValueKey('question-submit')));
        await _tap(tester, find.byKey(const ValueKey('question-submit')));
        expect(
          tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
          isFalse,
        );
        final stored = await h.store.read(_owner.id);
        expect(stored?.submissionPending, isTrue);
        expect(stored?.requestId, h.questions.calls.first['requestId']);
        await _tap(tester, find.byKey(const ValueKey('question-submit')));
        expect(h.questions.calls.length, 3);
        expect(h.questions.calls[0], h.questions.calls[1]);
        expect(h.questions.calls[1], h.questions.calls[2]);
        expect(find.text('등록 완료 question-saved'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'definitive validation rejection preserves text but new intent gets a new operation ID',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      h.questions.createResult = () async =>
          throw const ApiException('입력 확인', code: 'VALIDATION', status: 400);
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isTrue,
      );
      expect(_field(tester, _bodyKey), contains('가방이 두 개'));
      h.questions.createResult = () async => 'question-saved';
      await _enter(tester, _titleKey, '수정한 공항 이동 질문');
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls.length, 2);
      expect(
        h.questions.calls.first['requestId'],
        isNot(h.questions.calls.last['requestId']),
      );
    },
  );

  testWidgets(
    'pre-HTTP image validation on first attempt leaves the draft editable',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      h.questions.createResult = () async =>
          throw const ApiException('사진 형식을 확인해주세요.', code: 'invalid_image');
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isTrue,
      );
      expect((await h.store.read(_owner.id))?.submissionPending, isFalse);
      expect((await h.store.read(_owner.id))?.requestId, isNull);
    },
  );

  testWidgets(
    'late submission result cannot navigate or copy a draft into another account',
    (tester) async {
      final result = Completer<String>();
      final h = _Harness()..cleanup(tester);
      h.questions.createResult = () => result.future;
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls.length, 1);
      h.auth.changeUser(_other);
      await tester.pump();
      result.complete('old-account-question');
      await tester.pumpAndSettle();
      expect(_field(tester, _titleKey), isEmpty);
      expect(find.text('등록 완료 old-account-question'), findsNothing);
      expect((await h.store.read(_owner.id))?.submissionPending, isTrue);
      expect(await h.store.read(_other.id), isNull);
    },
  );

  testWidgets(
    'unsent text draft restores for its owner without requesting GPS or photos',
    (tester) async {
      final store = TravelDraftStore(server: 'test-server');
      await store.save(_owner.id, travelDraftFixture);
      final h = _Harness(
        store: store,
        location: () async => throw StateError('must not request GPS'),
      )..cleanup(tester);
      await h.mount(tester);
      expect(_field(tester, _titleKey), travelDraftFixture.title);
      expect(_field(tester, _bodyKey), travelDraftFixture.body);
      expect(_field(tester, _rewardKey), '150');
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isTrue,
      );
      expect(find.textContaining('사진은 저장되지'), findsOneWidget);
      expect(find.text('사진 첨부'), findsOneWidget);
      expect(h.questions.calls, isEmpty);
    },
  );

  testWidgets(
    'restored pending text retries frozen snapshot with its persisted operation ID',
    (tester) async {
      final store = TravelDraftStore(server: 'test-server');
      await store.save(
        _owner.id,
        TravelQuestionDraft.fromJson({
          ...travelDraftFixture.toJson(),
          'image_count': 0,
          'submission_pending': true,
          'request_id': 'durable-operation-12345',
        }),
      );
      final h = _Harness(store: store)..cleanup(tester);
      await h.mount(tester);
      expect(h.questions.calls, isEmpty);
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isFalse,
      );
      await _tap(tester, find.text('같은 요청 다시 확인'));
      expect(h.questions.calls.single['requestId'], 'durable-operation-12345');
      expect(h.questions.calls.single['title'], travelDraftFixture.title);
      expect(h.questions.calls.single['reward'], 150);
      expect(await store.read(_owner.id), isNull);
    },
  );

  testWidgets(
    'restored photo submission stays read-only and points to existing questions',
    (tester) async {
      final store = TravelDraftStore(server: 'test-server');
      await store.save(
        _owner.id,
        TravelQuestionDraft.fromJson({
          ...travelDraftFixture.toJson(),
          'submission_pending': true,
          'request_id': 'durable-operation-12345',
        }),
      );
      final h = _Harness(store: store)..cleanup(tester);
      await h.mount(tester);
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isFalse,
      );
      expect(find.byKey(const ValueKey('question-submit')), findsNothing);
      expect(h.questions.calls, isEmpty);
      expect(find.textContaining('사진 2장'), findsOneWidget);
      await _tap(tester, find.text('내 질문에서 등록 여부 확인'));
      expect(find.text('최근 내 질문'), findsOneWidget);
      expect(find.textContaining('등록 실패가 확정되는 것은 아닙니다'), findsOneWidget);
      expect((await store.read(_owner.id))?.submissionPending, isTrue);
    },
  );

  testWidgets(
    'photo recovery finds own questions outside map bounds without showing other accounts',
    (tester) async {
      final store = TravelDraftStore(server: 'test-server');
      await store.save(
        _owner.id,
        TravelQuestionDraft.fromJson({
          ...travelDraftFixture.toJson(),
          'submission_pending': true,
        }),
      );
      final h = _Harness(store: store)..cleanup(tester);
      h.questions.visible = [
        Question.fromMap({
          'id': 'my-malaga-question',
          'user_id': _owner.id,
          'city': 'Málaga',
          'title': '내 사진 질문',
        }),
        Question.fromMap({
          'id': 'other-question',
          'user_id': _other.id,
          'city': 'Madrid',
          'title': '다른 계정 질문',
        }),
      ];
      await h.mount(tester);
      await _tap(tester, find.text('내 질문에서 등록 여부 확인'));
      expect(find.text('내 사진 질문'), findsOneWidget);
      expect(find.text('다른 계정 질문'), findsNothing);
      await _tap(tester, find.text('내 사진 질문'));
      expect(find.text('등록 완료 my-malaga-question'), findsOneWidget);
      expect(h.questions.calls, isEmpty);
    },
  );

  testWidgets(
    'account switch clears visible text and cannot submit the old account draft',
    (tester) async {
      final h = _Harness()..cleanup(tester);
      await h.mount(tester);
      await _fill(tester);
      h.auth.changeUser(_other);
      await tester.pumpAndSettle();
      expect(_field(tester, _titleKey), isEmpty);
      expect(_field(tester, _bodyKey), isEmpty);
      expect(_field(tester, _rewardKey), '100');
      expect(h.questions.calls, isEmpty);
      expect((await h.store.read(_owner.id))?.title, '공항에서 시내 이동');
      expect(await h.store.read(_other.id), isNull);
    },
  );

  testWidgets(
    'storage failure preserves text and does not send an untracked request',
    (tester) async {
      final store = _WriteFailingStore();
      final h = _Harness(store: store)..cleanup(tester);
      await h.mount(tester);
      await _fill(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(h.questions.calls, isEmpty);
      expect(_field(tester, _titleKey), '공항에서 시내 이동');
      expect(find.textContaining('임시 저장 실패'), findsOneWidget);
    },
  );

  testWidgets(
    'failed draft read never overwrites an existing snapshot and offers bounded retry',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final seed = TravelDraftStore(server: 'test-server');
      await seed.save(_owner.id, travelDraftFixture);
      var failRead = true;
      final store = TravelDraftStore(
        server: 'test-server',
        preferences: () async {
          if (failRead) throw StateError('temporarily unavailable');
          return prefs;
        },
      );
      final h = _Harness(store: store)..cleanup(tester);
      await h.mount(tester);
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isFalse,
      );
      expect((await seed.read(_owner.id))?.title, travelDraftFixture.title);
      failRead = false;
      await _tap(tester, find.text('임시 저장 다시 확인'));
      expect(_field(tester, _titleKey), travelDraftFixture.title);
      expect(
        tester.widget<TextFormField>(find.byKey(_titleKey)).enabled,
        isTrue,
      );
      expect(h.questions.calls, isEmpty);
    },
  );

  testWidgets(
    'small phone with enlarged Korean text remains scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = _Harness()..cleanup(tester);
      await h.mount(tester, textScale: 1.3);
      await _fill(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('question-submit')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('question-submit')), findsOneWidget);
    },
  );

  testWidgets('question text comes first and wide screens stay readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = _Harness()..cleanup(tester);
    await h.mount(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('question-form-content'))).width,
      lessThanOrEqualTo(720),
    );
    expect(
      tester.getTopLeft(find.byKey(_titleKey)).dy,
      lessThan(tester.getTopLeft(find.byType(TravelLocationSection)).dy),
    );
    expect(find.text('공항 이동'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large text can open optional starters and retry a failed request',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = _Harness()..cleanup(tester);
      h.questions.createResult = () async =>
          throw const ApiException('연결 지연', code: 'timeout');
      await h.mount(tester, textScale: 2);
      await _tap(tester, find.byKey(const ValueKey('question-starters')));
      await _tap(tester, find.text('현지 언어 도움'));
      await _selectMalaga(tester);
      await _tap(tester, find.byKey(const ValueKey('question-submit')));
      expect(find.text('같은 요청 다시 확인'), findsOneWidget);
      expect(h.questions.calls, hasLength(1));
      h.questions.createResult = () async => 'question-saved';
      await _tap(tester, find.text('같은 요청 다시 확인'));
      expect(h.questions.calls, hasLength(2));
      expect(h.questions.calls.first, h.questions.calls.last);
      expect(find.text('등록 완료 question-saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('photo recovery remains usable on a phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = TravelDraftStore(server: 'test-server');
    await store.save(
      _owner.id,
      TravelQuestionDraft.fromJson({
        ...travelDraftFixture.toJson(),
        'submission_pending': true,
      }),
    );
    final h = _Harness(store: store)..cleanup(tester);
    const title = '말라가 공항에서 늦은 밤 시내까지 이동할 방법이 궁금해요';
    h.questions.visible = [
      Question.fromMap({
        'id': 'recovered-question',
        'user_id': _owner.id,
        'city': 'Málaga',
        'title': title,
      }),
    ];
    await h.mount(tester, textScale: 2);
    await _tap(tester, find.text('내 질문에서 등록 여부 확인'));
    expect(find.text(title), findsOneWidget);
    await _tap(tester, find.text(title));
    expect(find.text('등록 완료 recovered-question'), findsOneWidget);
    expect(h.questions.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
