import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/questions/question_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<String> create(
    QuestionRepository repo, {
    List<XFile> images = const [],
  }) => repo.createQuestion(
    title: '기차표 구매 질문',
    body: '말라가역에서 기차표를 어디서 구매하나요?',
    country: 'Spain',
    city: 'Malaga',
    regionName: null,
    category: '교통',
    urgency: '보통',
    rewardPoints: 100,
    latitude: 36.7213,
    longitude: -4.4214,
    images: images,
  );

  for (final delayRead in [false, true]) {
    test(
      'image ${delayRead ? 'read' : 'length'} preprocessing cannot switch the creating account',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        var sent = 0;
        final api =
            ApiClient(
                baseUrl: 'https://example.test/api',
                client: MockClient((_) async {
                  sent++;
                  return http.Response('{"id":"unexpected"}', 201);
                }),
              )
              ..token = 'session-a'
              ..userId = 'user-a';
        addTearDown(api.dispose);
        final creation = create(
          QuestionRepository(api),
          images: [_DelayedImage(started, release, delayRead: delayRead)],
        );
        final failure = expectLater(
          creation,
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
        api.userId = 'user-b';
        release.complete();
        await failure;
        expect(sent, 0);
      },
    );
  }

  for (final failRead in [false, true]) {
    test(
      'unreadable photo ${failRead ? 'bytes' : 'length'} is a definite local failure with no point-hold request',
      () async {
        var sent = 0;
        final api =
            ApiClient(
                baseUrl: 'https://example.test/api',
                client: MockClient((_) async {
                  sent++;
                  return http.Response('{"id":"unexpected"}', 201);
                }),
              )
              ..token = 'session'
              ..userId = 'owner';
        addTearDown(api.dispose);
        final good = XFile.fromData(
          Uint8List.fromList([137, 80, 78, 71]),
          name: 'good.png',
          path: 'good.png',
          mimeType: 'image/png',
        );
        await expectLater(
          create(
            QuestionRepository(api),
            images: [
              good,
              _UnreadableImage(failRead: failRead),
            ],
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'invalid_image')
                .having((e) => e.status, 'status', isNull)
                .having((e) => e.toString(), 'message', contains('다시 선택'))
                .having(
                  (e) => e.toString(),
                  'private path redaction',
                  isNot(contains('private-photo-path')),
                ),
          ),
        );
        expect(sent, 0);
      },
    );
  }

  test(
    'transport failure after photo reading stays an unknown request outcome',
    () async {
      var sent = 0;
      final api =
          ApiClient(
              baseUrl: 'https://example.test/api',
              client: MockClient((_) async {
                sent++;
                throw const ApiException(
                  'response lost after request',
                  code: 'timeout',
                );
              }),
            )
            ..token = 'session'
            ..userId = 'owner';
      addTearDown(api.dispose);
      await expectLater(
        create(
          QuestionRepository(api),
          images: [
            XFile.fromData(
              Uint8List(4),
              name: 'good.png',
              path: 'good.png',
              mimeType: 'image/png',
            ),
          ],
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            isNot('invalid_image'),
          ),
        ),
      );
      expect(sent, 1);
    },
  );

  test(
    'guide feed uses server eligibility endpoint rather than all open questions',
    () async {
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          expect(request.url.path, '/api/guide/questions');
          expect(request.url.query, isEmpty);
          expect(request.method, 'GET');
          return http.Response('[]', 200);
        }),
      )..token = 'session';
      addTearDown(api.dispose);
      expect(await QuestionRepository(api).fetchOpenQuestions(), isEmpty);
    },
  );

  test(
    'question creation sends images and hold as one server operation',
    () async {
      final requests = <http.Request>[];
      final api =
          ApiClient(
              baseUrl: 'http://localhost:8080/api',
              client: MockClient((request) async {
                requests.add(request);
                return http.Response('{"id":"question-1"}', 201);
              }),
            )
            ..token = 'opaque-session'
            ..userId = 'owner';
      addTearDown(api.dispose);
      final bytes = Uint8List.fromList([137, 80, 78, 71]);
      final id = await create(
        QuestionRepository(api),
        images: [
          XFile.fromData(
            bytes,
            name: 'photo.png',
            path: 'photo.png',
            mimeType: 'image/png',
          ),
        ],
      );
      expect(id, 'question-1');
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.url.path, '/api/questions');
      expect(request.method, 'POST');
      expect(request.headers['Idempotency-Key'], isNotEmpty);
      final payload = jsonDecode(request.body) as Map;
      expect(payload['reward_points'], 100);
      expect(payload.containsKey('point_balance'), isFalse);
      expect(payload.containsKey('user_id'), isFalse);
      expect(payload['images'], [
        {
          'name': 'photo.png',
          'content_type': 'image/png',
          'data_base64': base64Encode(bytes),
        },
      ]);
    },
  );

  test('image count, size and media type fail before sending a hold', () async {
    var requests = 0;
    final api =
        ApiClient(
            baseUrl: 'http://localhost:8080/api',
            client: MockClient((_) async {
              requests++;
              return http.Response('{"id":"unexpected"}', 201);
            }),
          )
          ..token = 'session'
          ..userId = 'owner';
    addTearDown(api.dispose);
    final repo = QuestionRepository(api);
    final valid = XFile.fromData(
      Uint8List(2),
      name: 'photo.png',
      path: 'photo.png',
      mimeType: 'image/png',
    );
    await expectLater(
      create(repo, images: List.filled(6, valid)),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_image',
        ),
      ),
    );
    await expectLater(
      create(
        repo,
        images: [
          XFile.fromData(
            Uint8List(QuestionRepository.maxImageBytes + 1),
            name: 'photo.png',
            path: 'photo.png',
            mimeType: 'image/png',
          ),
        ],
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_image',
        ),
      ),
    );
    await expectLater(
      create(
        repo,
        images: [
          XFile.fromData(
            Uint8List(2),
            name: 'payload.svg',
            mimeType: 'image/svg+xml',
          ),
        ],
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_image',
        ),
      ),
    );
    expect(requests, 0);
  });

  test(
    'cancel sends neither client-controlled refund nor user fields',
    () async {
      late http.Request request;
      final api =
          ApiClient(
              baseUrl: 'http://localhost:8080/api',
              client: MockClient((value) async {
                request = value;
                return http.Response('{"ok":true}', 200);
              }),
            )
            ..token = 'session'
            ..userId = 'owner';
      addTearDown(api.dispose);
      await QuestionRepository(api).cancelQuestion('question-1');
      expect(request.url.path, '/api/questions/question-1/cancel');
      expect(jsonDecode(request.body), isEmpty);
      expect(request.headers['Idempotency-Key'], isNotEmpty);
    },
  );
}

class _DelayedImage extends XFile {
  _DelayedImage(this.started, this.release, {required this.delayRead})
    : super('photo.png', mimeType: 'image/png');
  final Completer<void> started;
  final Completer<void> release;
  final bool delayRead;
  @override
  Future<int> length() async {
    if (!delayRead) {
      started.complete();
      await release.future;
    }
    return 4;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    if (delayRead) {
      started.complete();
      await release.future;
    }
    return Uint8List.fromList([137, 80, 78, 71]);
  }
}

class _UnreadableImage extends XFile {
  _UnreadableImage({required this.failRead})
    : super('private-photo-path.png', mimeType: 'image/png');
  final bool failRead;
  @override
  Future<int> length() async {
    if (!failRead) throw StateError('Cannot stat private-photo-path.png');
    return 4;
  }

  @override
  Future<Uint8List> readAsBytes() async =>
      throw StateError('Cannot read private-photo-path.png');
}
