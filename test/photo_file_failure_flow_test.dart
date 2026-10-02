import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/core/services/location_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/create_question_page.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';
import 'package:local_qa_concierge/features/questions/travel_draft_store.dart';
import 'package:local_qa_concierge/features/questions/travel_question_support.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = AppUser(
  id: 'photo-test-owner',
  email: 'photo-test@example.test',
  name: '여행자',
  pointBalance: 1000,
  isAdmin: false,
);
const _titleKey = ValueKey('question-title');
const _bodyKey = ValueKey('question-body');
const _rewardKey = ValueKey('question-reward');
const _submitKey = ValueKey('question-submit');
const _title = '공항에서 시내 이동';
const _body = '밤 10시에 도착하며 가방이 두 개 있습니다.';
const _uncertainNotice = '처리 결과를 확인하지 못했습니다. 중복 차감을 막기 위해 같은 내용으로 다시 확인합니다.';

// A synthetic one-pixel PNG; no device photo library or user files are used.
final _photoBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6N8AAAAASUVORK5CYII=',
);

class _TestAuth extends AuthRepository {
  _TestAuth(super.client);

  @override
  AppUser get currentUser => _owner;
}

class _Harness {
  _Harness({required this.photoPath, this.loseAcknowledgement = false}) {
    api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) async {
              expect(request.method, 'POST');
              expect(request.url.path, '/api/questions');
              posts.add(request);
              if (loseAcknowledgement) {
                // The request reached the transport. Its commit state is unknown.
                throw TimeoutException('Synthetic lost acknowledgement');
              }
              return http.Response('{"id":"photo-question"}', 201);
            }),
          )
          ..token = 'synthetic-photo-session'
          ..userId = _owner.id;
    auth = _TestAuth(api);
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
      ],
    );
  }

  String photoPath;
  final bool loseAcknowledgement;
  final posts = <http.Request>[];
  final store = TravelDraftStore(server: 'synthetic-photo-server');
  late final ApiClient api;
  late final _TestAuth auth;
  late final GoRouter router;

  Future<void> mount(WidgetTester tester) async {
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
      call,
    ) async {
      expect(call.method, 'pickMultiImage');
      return [photoPath];
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        null,
      );
      router.dispose();
      auth.dispose();
      api.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          currentProfileProvider.overrideWith((ref) async => _owner),
          questionRepositoryProvider.overrideWithValue(QuestionRepository(api)),
          questionLocationLoaderProvider.overrideWithValue(
            () async => const DeviceLocation(
              country: 'Spain',
              city: 'Málaga',
              latitude: 36.7213,
              longitude: -4.4214,
            ),
          ),
          travelDraftStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Key key, String text) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.enterText(find.byKey(key), text);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _fillAndPick(WidgetTester tester) async {
  await _enter(tester, _titleKey, _title);
  await _enter(tester, _bodyKey, _body);
  await _enter(tester, _rewardKey, '150');
  await _tap(tester, find.text('사진 첨부'));
  expect(find.text('사진 1장 선택됨'), findsOneWidget);
}

Future<void> _submit(WidgetTester tester) async {
  final target = find.byKey(_submitKey);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pump();
  // Let actual XFile I/O run between fake-clock frames, with a bounded wait.
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text('등록 결과 확인 중…').evaluate().isEmpty) break;
  }
  expect(find.text('등록 결과 확인 중…'), findsNothing);
  await tester.pumpAndSettle();
}

void _expectFields(WidgetTester tester, {required bool enabled}) {
  for (final entry in {
    _titleKey: _title,
    _bodyKey: _body,
    _rewardKey: '150',
  }.entries) {
    final field = tester.widget<TextFormField>(find.byKey(entry.key));
    expect(field.controller!.text, entry.value);
    expect(field.enabled, enabled);
  }
}

void _expectPrivateFileErrorHidden(WidgetTester tester, String path) {
  expect(find.text('사진을 읽지 못했어요. 사진을 다시 선택해주세요.'), findsOneWidget);
  expect(find.textContaining(path), findsNothing);
  expect(find.textContaining('FileSystemException'), findsNothing);
  expect(find.textContaining('No such file'), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temporary = Directory.systemTemp.createTempSync('photo-file-flow-test-');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  testWidgets(
    'missing picked photo leaves an editable draft and replacement sends one POST',
    (tester) async {
      final missingPath = '${temporary.path}/missing-photo.png';
      final h = _Harness(photoPath: missingPath);
      await h.mount(tester);
      await _fillAndPick(tester);
      await _submit(tester);

      expect(h.posts, isEmpty);
      _expectFields(tester, enabled: true);
      _expectPrivateFileErrorHidden(tester, missingPath);
      expect(find.text(_uncertainNotice), findsNothing);
      expect(find.text('같은 요청 다시 확인'), findsNothing);
      final draft = (await h.store.read(_owner.id))!;
      expect(draft.title, _title);
      expect(draft.body, _body);
      expect(draft.reward, '150');
      expect(draft.imageCount, 1);
      expect(draft.submissionPending, isFalse);
      expect(draft.requestId, isNull);

      final replacement = File('${temporary.path}/replacement.png')
        ..writeAsBytesSync(_photoBytes);
      h.photoPath = replacement.path;
      await _enter(tester, _titleKey, '수정한 공항 이동 질문');
      await _enter(tester, _bodyKey, '수정한 도착 시각은 저녁 9시이며 가방은 한 개입니다.');
      await _enter(tester, _rewardKey, '200');
      await _tap(tester, find.text('사진 1장 선택됨'));
      await _submit(tester);

      expect(h.posts, hasLength(1));
      final request = h.posts.single;
      expect(request.headers['Idempotency-Key'], isNotEmpty);
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['title'], '수정한 공항 이동 질문');
      expect(payload['body'], '수정한 도착 시각은 저녁 9시이며 가방은 한 개입니다.');
      expect(payload['reward_points'], 200);
      expect(payload['images'], [
        {
          'name': 'replacement.png',
          'content_type': 'image/png',
          'data_base64': base64Encode(_photoBytes),
        },
      ]);
      expect(find.text('등록 완료 photo-question'), findsOneWidget);
      expect(await h.store.read(_owner.id), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost acknowledgement then missing photo keeps the original frozen operation',
    (tester) async {
      final photo = File('${temporary.path}/original.png')
        ..writeAsBytesSync(_photoBytes);
      final h = _Harness(photoPath: photo.path, loseAcknowledgement: true);
      await h.mount(tester);
      await _fillAndPick(tester);
      await _submit(tester);

      expect(h.posts, hasLength(1));
      _expectFields(tester, enabled: false);
      final frozen = (await h.store.read(_owner.id))!;
      expect(frozen.submissionPending, isTrue);
      expect(frozen.requestId, h.posts.single.headers['Idempotency-Key']);
      expect(frozen.requestId, isNotEmpty);
      expect(find.text(_uncertainNotice), findsOneWidget);

      photo.deleteSync();
      await _submit(tester);

      expect(h.posts, hasLength(1));
      _expectFields(tester, enabled: false);
      _expectPrivateFileErrorHidden(tester, photo.path);
      expect((await h.store.read(_owner.id))!.toJson(), frozen.toJson());
      expect(find.text('같은 요청 다시 확인'), findsOneWidget);
      expect(find.text(_uncertainNotice), findsOneWidget);
      expect(find.textContaining('아직 등록 전'), findsNothing);
      expect(find.text('등록 완료 photo-question'), findsNothing);
      final picker = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('사진 1장 선택됨'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(picker.onPressed, isNull);
    },
  );
}
