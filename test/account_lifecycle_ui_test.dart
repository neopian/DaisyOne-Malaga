import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/account/account_settings_page.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/auth/email_verification_page.dart';
import 'package:local_qa_concierge/features/auth/password_recovery_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late ApiClient api;
  late AuthRepository auth;
  late Future<http.Response> Function(http.Request) handler;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    handler = (_) async => json({});
    api = ApiClient(
      baseUrl: 'https://example.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          final email = jsonDecode(request.body)['email'];
          return json({
            'token': email,
            'user': {'id': email, 'email': email, 'name': '여행자'},
          });
        }
        return handler(request);
      }),
    );
    auth = AuthRepository(api, preferences: SharedPreferences.getInstance);
  });
  tearDown(() {
    auth.dispose();
    api.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: child,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    '320px double-text recovery reports mail unavailable truthfully and retries',
    (tester) async {
      var attempts = 0;
      handler = (_) async {
        attempts++;
        return attempts == 1
            ? json({
                'error': {'code': 'MAIL_UNAVAILABLE', 'message': 'disabled'},
              }, 503)
            : json({'accepted': true}, 202);
      };
      await pump(tester, const PasswordRecoveryPage());
      await tester.enterText(
        find.byType(TextFormField).first,
        'a@example.test',
      );
      await tester.ensureVisible(find.text('복구 이메일 요청'));
      await tester.tap(find.text('복구 이메일 요청'));
      await tester.pumpAndSettle();
      expect(find.textContaining('이메일은 전송되지 않았습니다'), findsOneWidget);
      expect(find.textContaining('발송 대기 중입니다'), findsNothing);
      await tester.ensureVisible(find.text('복구 이메일 요청'));
      await tester.tap(find.text('복구 이메일 요청'));
      await tester.pumpAndSettle();
      expect(find.textContaining('발송 대기 중입니다'), findsOneWidget);
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recovery can resume directly with a code and reset after reopening',
    (tester) async {
      Object? body;
      handler = (request) async {
        body = jsonDecode(request.body);
        return json({'ok': true});
      };
      await pump(tester, const PasswordRecoveryPage());
      final fields = find.byType(TextFormField);
      await tester.ensureVisible(fields.at(1));
      await tester.enterText(
        fields.at(1),
        'https://example.test/reset#action=reset_password&token=recovery-code',
      );
      await tester.ensureVisible(fields.at(2));
      await tester.enterText(fields.at(2), 'new-password');
      await tester.ensureVisible(fields.at(3));
      await tester.enterText(fields.at(3), 'new-password');
      await tester.ensureVisible(find.text('비밀번호 변경'));
      await tester.tap(find.text('비밀번호 변경'));
      await tester.pumpAndSettle();
      expect(body, {'token': 'recovery-code', 'password': 'new-password'});
      expect(find.text('로그인으로 돌아가기'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing recovery during network response causes no stale UI update',
    (tester) async {
      final response = Completer<http.Response>();
      handler = (_) => response.future;
      await pump(tester, const PasswordRecoveryPage());
      await tester.enterText(
        find.byType(TextFormField).first,
        'a@example.test',
      );
      await tester.ensureVisible(find.text('복구 이메일 요청'));
      await tester.tap(find.text('복구 이메일 요청'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      response.complete(json({'accepted': true}, 202));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('verification clears entered token when account changes', (
    tester,
  ) async {
    await tester.runAsync(
      () => auth.signIn(email: 'a@example.test', password: 'password'),
    );
    await pump(tester, const EmailVerificationPage());
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), 'old-account-code');
    await tester.runAsync(
      () => auth.signIn(email: 'b@example.test', password: 'password'),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
    );
    expect(find.text('b@example.test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'delete requires password and exact confirmation; cancel sends nothing',
    (tester) async {
      var requests = 0;
      handler = (_) async {
        requests++;
        return json({});
      };
      await tester.runAsync(
        () => auth.signIn(email: 'a@example.test', password: 'password'),
      );
      await pump(tester, const AccountSettingsPage());
      await tester.ensureVisible(find.text('계정 삭제 안내'));
      await tester.tap(find.text('계정 삭제 안내'));
      await tester.pumpAndSettle();
      expect(find.textContaining('복구할 수 없습니다'), findsWidgets);
      await tester.ensureVisible(find.text('영구 삭제'));
      await tester.tap(find.text('영구 삭제'));
      await tester.pumpAndSettle();
      expect(find.text('현재 비밀번호를 입력해주세요.'), findsOneWidget);
      expect(find.text('삭제하려면 DELETE를 정확히 입력해주세요.'), findsOneWidget);
      expect(requests, 0);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reauth dialog from prior account cannot export the next account',
    (tester) async {
      var requests = 0;
      handler = (_) async {
        requests++;
        return json({});
      };
      await tester.runAsync(
        () => auth.signIn(email: 'a@example.test', password: 'password'),
      );
      await pump(tester, const AccountSettingsPage());
      await tester.ensureVisible(find.text('비밀번호 확인 후 준비'));
      await tester.tap(find.text('비밀번호 확인 후 준비'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'old-account-password',
      );
      await tester.runAsync(
        () => auth.signIn(email: 'b@example.test', password: 'password'),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('내 데이터 준비'));
      await tester.tap(find.text('내 데이터 준비'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.text('JSON 저장 / 공유'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'export image option is explicit and prepared data clears after account change',
    (tester) async {
      Object? payload;
      handler = (request) async {
        payload = jsonDecode(request.body);
        return json({
          'profile': {'id': 'a@example.test'},
        });
      };
      await tester.runAsync(
        () => auth.signIn(email: 'a@example.test', password: 'password'),
      );
      await pump(tester, const AccountSettingsPage());
      await tester.ensureVisible(find.text('저장된 사진 포함'));
      await tester.tap(find.text('저장된 사진 포함'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('비밀번호 확인 후 준비'));
      await tester.tap(find.text('비밀번호 확인 후 준비'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'password');
      await tester.ensureVisible(find.text('내 데이터 준비'));
      await tester.tap(find.text('내 데이터 준비'));
      await tester.pumpAndSettle();
      expect(payload, {'password': 'password', 'include_images': false});
      expect(find.text('JSON 저장 / 공유'), findsOneWidget);
      await tester.runAsync(
        () => auth.signIn(email: 'b@example.test', password: 'password'),
      );
      await tester.pumpAndSettle();
      expect(find.text('JSON 저장 / 공유'), findsNothing);
      expect(find.text('JSON 복사'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
