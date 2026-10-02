import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/account/account_repository.dart';
import 'package:local_qa_concierge/features/answers/answer_draft_store.dart';
import 'answer_draft_store_test.dart' as answer_fixture;
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/auth/session_store.dart';
import 'package:local_qa_concierge/features/questions/travel_draft_store.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = {'id': 'account-a', 'email': 'a@example.test', 'name': 'A'};
http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class MemorySessionStore implements SessionStore {
  String? token;
  bool failClear = false;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async {
    token = value;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('unavailable');
    token = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late ApiClient api;
  late AuthRepository auth;
  late AccountRepository account;
  late TravelDraftStore drafts;
  late AnswerDraftStore answerDrafts;
  late MemorySessionStore sessions;
  late Future<http.Response> Function(http.Request) handle;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    sessions = MemorySessionStore();
    handle = (_) async => json({});
    api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient(
        (request) async => request.url.path.endsWith('/auth/login')
            ? json({
                'token': jsonDecode(request.body)['email'],
                'user': {
                  ...user,
                  'id': jsonDecode(request.body)['email'] == 'b@example.test'
                      ? 'account-b'
                      : 'account-a',
                },
              })
            : await handle(request),
      ),
      preferences: () async => prefs,
    );
    auth = AuthRepository(api, sessionStore: sessions);
    drafts = TravelDraftStore(
      server: api.baseUri.toString(),
      preferences: () async => prefs,
    );
    answerDrafts = AnswerDraftStore(
      server: api.baseUri.toString(),
      preferences: () async => prefs,
    );
    account = AccountRepository(
      api,
      auth,
      drafts,
      preferences: () async => prefs,
      clearExports: () async {},
      answerDrafts: answerDrafts,
    );
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<void> login() => auth.signIn(
    email: 'a@example.test',
    password: 'secret123',
    rememberMe: true,
  );

  test(
    'legacy models default to unverified; server timestamp marks verified',
    () {
      expect(AppUser.fromMap(user).isEmailVerified, isFalse);
      expect(
        AppUser.fromMap({
          ...user,
          'email_verified_at': '2026-10-02T00:00:00Z',
        }).isEmailVerified,
        isTrue,
      );
    },
  );

  test(
    'recovery is unauthenticated, retryable, never persists password or token',
    () async {
      var attempts = 0;
      final keys = <String?>[];
      handle = (request) async {
        expect(request.headers['authorization'], isNull);
        keys.add(request.headers['idempotency-key']);
        attempts++;
        if (attempts == 1) throw http.ClientException('interrupted');
        expect(jsonDecode(request.body), {
          'token': 'recovery-token',
          'password': 'new-password',
        });
        return json({'ok': true});
      };
      await expectLater(
        auth.confirmPasswordReset(
          token: 'recovery-token',
          password: 'new-password',
        ),
        throwsA(isA<ApiException>()),
      );
      await auth.confirmPasswordReset(
        token: 'recovery-token',
        password: 'new-password',
      );
      expect(keys[0], keys[1]);
      expect(keys[0], isNotEmpty);
      expect(prefs.getKeys(), isEmpty);
      expect(auth.currentUser, isNull);
    },
  );

  test(
    'disabled mail and malformed acceptance cannot become success',
    () async {
      handle = (_) async => json({
        'error': {'code': 'MAIL_UNAVAILABLE', 'message': 'Mail is disabled'},
      }, 503);
      await expectLater(
        auth.requestPasswordReset('a@example.test'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'MAIL_UNAVAILABLE'),
        ),
      );
      handle = (_) async => json({'accepted': false}, 202);
      await expectLater(
        auth.requestPasswordReset('a@example.test'),
        throwsA(isA<ApiException>()),
      );
      handle = (_) async => json({
        'accepted': true,
        'demo_only': true,
        'demo_token': 'should-not-expose',
      }, 202);
      final result = await auth.requestPasswordReset('a@example.test');
      expect(result.isDemonstration, isFalse);
      expect(result.demonstrationToken, isNull);
    },
  );

  test('failed reauthentication leaves current login intact', () async {
    await login();
    handle = (_) async => json({
      'error': {'code': 'REAUTHENTICATION_FAILED', 'message': 'Wrong password'},
    }, 403);
    await expectLater(
      account.exportData('wrong'),
      throwsA(isA<ApiException>()),
    );
    expect(auth.currentUser?.id, 'account-a');
    expect(sessions.token, 'a@example.test');
  });

  test(
    'verification commits confirmed state without GET and preserves profile on repeat',
    () async {
      await login();
      final detailed = {
        ...user,
        'name': 'Updated name',
        'point_balance': 421,
        'is_admin': true,
        'is_suspended': true,
        'avatar_url': '/media/avatar',
        'current_country': 'Spain',
        'current_city': 'Málaga',
        'questioner_rating_avg': 4.2,
        'helper_rating_avg': 4.8,
        'questioner_rating_count': 3,
        'helper_rating_count': 8,
        'created_at': '2026-01-01T00:00:00Z',
      };
      handle = (_) async => json(detailed);
      await auth.ensureCurrentProfile();
      final before = auth.currentUser!;
      var confirms = 0;
      handle = (request) async {
        expect(
          request.method,
          'POST',
          reason: 'No GET may gate an acknowledged verification.',
        );
        expect(request.url.path, '/api/auth/email-verification/confirm');
        confirms++;
        return confirms == 1
            ? json({'ok': true, 'email_verified_at': '2026-10-02T00:00:00Z'})
            : json({
                'error': {
                  'code': 'INVALID_OR_EXPIRED_TOKEN',
                  'message': 'Used token',
                },
              }, 400);
      };
      await auth.confirmEmailVerification('verification-code');
      final after = auth.currentUser!;
      expect(after.emailVerifiedAt, DateTime.utc(2026, 10, 2));
      expect(after.id, before.id);
      expect(after.email, before.email);
      expect(after.name, before.name);
      expect(after.avatarUrl, before.avatarUrl);
      expect(after.pointBalance, before.pointBalance);
      expect(after.currentCountry, before.currentCountry);
      expect(after.currentCity, before.currentCity);
      expect(after.isAdmin, before.isAdmin);
      expect(after.isSuspended, before.isSuspended);
      expect(after.questionerRatingAvg, before.questionerRatingAvg);
      expect(after.helperRatingAvg, before.helperRatingAvg);
      expect(after.questionerRatingCount, before.questionerRatingCount);
      expect(after.helperRatingCount, before.helperRatingCount);
      expect(after.createdAt, before.createdAt);
      await expectLater(
        auth.confirmEmailVerification('verification-code'),
        throwsA(isA<ApiException>()),
      );
      expect(auth.currentUser?.isEmailVerified, isTrue);
      expect(auth.currentUser?.pointBalance, 421);
      expect(confirms, 2);
    },
  );

  test('late verification cannot update a switched account', () async {
    await login();
    final started = Completer<void>();
    final response = Completer<http.Response>();
    handle = (_) {
      started.complete();
      return response.future;
    };
    final confirmation = auth.confirmEmailVerification('old-account-code');
    await started.future;
    await auth.signIn(email: 'b@example.test', password: 'other-password');
    response.complete(
      json({'ok': true, 'email_verified_at': '2026-10-02T00:00:00Z'}),
    );
    await expectLater(
      confirmation,
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
      ),
    );
    expect(auth.currentUser?.id, 'account-b');
    expect(auth.currentUser?.isEmailVerified, isFalse);
  });

  test(
    'cleanup pending is account deletion: clear session and only owner draft',
    () async {
      await login();
      const draft = TravelQuestionDraft(
        title: 'private',
        body: 'draft',
        category: '기타',
        reward: '20',
        country: 'Spain',
        city: 'Málaga',
        region: '',
        isManualLocation: true,
        imageCount: 0,
        submissionPending: false,
      );
      await drafts.save('account-a', draft);
      await drafts.save('account-b', draft);
      await answerDrafts.save(
        'account-a',
        answer_fixture.draft(question: 'q1'),
      );
      await answerDrafts.save(
        'account-a',
        answer_fixture.draft(question: 'q2'),
      );
      await answerDrafts.save(
        'account-b',
        answer_fixture.draft(question: 'q1'),
      );
      await prefs.setString('auth.remembered_email', 'a@example.test');
      handle = (request) async {
        expect(request.headers['idempotency-key'], isNotEmpty);
        expect(jsonDecode(request.body), {
          'password': 'secret123',
          'confirmation': 'DELETE',
        });
        return json({
          'ok': true,
          'account_deleted': true,
          'status': 'cleanup_pending',
        }, 202);
      };
      final result = await account.deleteAccount(
        password: 'secret123',
        confirmation: 'DELETE',
      );
      expect(result.cleanupPending, isTrue);
      expect(result.localCleanupComplete, isTrue);
      expect(auth.currentUser, isNull);
      expect(api.token, isNull);
      expect(sessions.token, isNull);
      expect(await drafts.read('account-a'), isNull);
      expect(await drafts.read('account-b'), isNotNull);
      expect(await answerDrafts.read('account-a', 'q1'), isNull);
      expect(await answerDrafts.read('account-a', 'q2'), isNull);
      expect(await answerDrafts.read('account-b', 'q1'), isNotNull);
      expect(prefs.getString('auth.remembered_email'), isNull);
    },
  );

  test(
    'late delete response cannot sign out a newly selected account',
    () async {
      await login();
      final started = Completer<void>();
      final response = Completer<http.Response>();
      handle = (_) {
        started.complete();
        return response.future;
      };
      final deletion = account.deleteAccount(
        password: 'secret123',
        confirmation: 'DELETE',
      );
      await started.future;
      await auth.signIn(email: 'b@example.test', password: 'new-secret');
      response.complete(
        json({'ok': true, 'account_deleted': true, 'status': 'deleted'}),
      );
      await expectLater(
        deletion,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      expect(auth.currentUser?.id, 'account-b');
    },
  );

  test(
    'injected native session stores token outside SharedPreferences',
    () async {
      await login();
      expect(sessions.token, 'a@example.test');
      expect(prefs.getKeys(), isEmpty);
      await auth.clearSession();
      expect(sessions.token, isNull);
    },
  );

  test(
    'acknowledged deletion reports incomplete local storage cleanup',
    () async {
      await login();
      sessions.failClear = true;
      handle = (_) async =>
          json({'ok': true, 'account_deleted': true, 'status': 'deleted'});
      final result = await account.deleteAccount(
        password: 'secret123',
        confirmation: 'DELETE',
      );
      expect(auth.currentUser, isNull);
      expect(result.localCleanupComplete, isFalse);
    },
  );
  test(
    'remote logout plus secure-store failure clears access and reports retained storage',
    () async {
      await login();
      sessions.failClear = true;
      handle = (request) async {
        expect(request.url.path, '/api/auth/logout');
        throw http.ClientException('offline');
      };
      await expectLater(auth.signOut(), throwsA(isA<ApiException>()));
      expect(auth.currentUser, isNull);
      expect(api.token, isNull);
      expect(api.userId, isNull);
      expect(auth.sessionStorageCleared, isFalse);
      expect(sessions.token, 'a@example.test');
    },
  );
}
