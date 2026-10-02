import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_qa_concierge/app/theme.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/auth/auth_repository.dart';
import 'package:local_qa_concierge/features/helper_application/helper_repository.dart';
import 'package:local_qa_concierge/features/profile/profile_page.dart';
import 'package:local_qa_concierge/features/profile/profile_repository.dart';
import 'package:local_qa_concierge/features/questions/question_realtime.dart';
import 'package:local_qa_concierge/shared/models/app_user.dart';
import 'package:local_qa_concierge/shared/models/guide_summary.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = AppUser(
  id: 'alice',
  email: 'alice@example.test',
  name: 'Alice',
  pointBalance: 1000,
  isAdmin: false,
  currentCountry: 'France',
  currentCity: 'Paris',
);
const _bob = AppUser(
  id: 'bob',
  email: 'bob@example.test',
  name: 'Bob',
  pointBalance: 1000,
  isAdmin: false,
  currentCountry: 'United States',
  currentCity: 'New York',
);

class _Auth extends AuthRepository {
  _Auth(super.client);
  AppUser user = _alice;
  @override
  AppUser get currentUser => user;
  void change(AppUser next) {
    user = next;
    notifyListeners();
  }
}

class _Harness {
  final gps = Completer<Map<String, dynamic>>();
  Completer<http.Response>? patchReply;
  final writes = <http.Request>[];
  late final ApiClient api;
  late final _Auth auth;
  late ProviderContainer container;
  int gpsCalls = 0;

  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('flutter.baseflow.com/geolocator');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isLocationServiceEnabled') return true;
          if (call.method == 'checkPermission') {
            return LocationPermission.whileInUse.index;
          }
          if (call.method == 'getCurrentPosition') {
            gpsCalls++;
            return gps.future;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    api =
        ApiClient(
            baseUrl: 'https://example.test/api',
            client: MockClient((request) async {
              if (request.method == 'PATCH') {
                writes.add(request);
                return patchReply == null
                    ? http.Response('{}', 200)
                    : patchReply!.future;
              }
              final user = auth.currentUser;
              return http.Response(
                jsonEncode({
                  'id': user.id,
                  'email': user.email,
                  'name': user.name,
                  'point_balance': 1000,
                  'is_admin': false,
                  'current_country': user.currentCountry,
                  'current_city': user.currentCity,
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          )
          ..token = 'token-alice'
          ..userId = 'alice';
    auth = _Auth(api);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authRepositoryProvider.overrideWithValue(auth),
          questionRealtimeProvider.overrideWith((_) {}),
          guideSummaryProvider.overrideWith(
            (_) async => const GuideSummary(
              acceptedAnswerCount: 0,
              earnedMockPoints: 0,
              pendingMockPoints: 0,
              applicationStatus: null,
              activityRegions: [],
            ),
          ),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const ProfilePage()),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(ProfilePage)),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
      api.dispose();
    });
  }

  Future<void> change(WidgetTester tester, AppUser user) async {
    api.token = 'token-${user.id}';
    api.userId = user.id;
    auth.change(user);
    container.invalidate(currentProfileProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> startGps(WidgetTester tester) async {
    await tester.ensureVisible(find.byIcon(Icons.my_location_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.my_location_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(gpsCalls, 1);
  }

  void resolveGps() => gps.complete(
    Position(
      longitude: -3.7038,
      latitude: 40.4168,
      timestamp: DateTime.utc(2026, 10, 2),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    ).toJson(),
  );
}

void main() {
  testWidgets('current account can still save its requested GPS association', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.startGps(tester);
    h.resolveGps();
    await tester.pumpAndSettle();
    expect(h.writes.length, 1);
    expect(h.writes.single.headers['Authorization'], 'Bearer token-alice');
    expect(jsonDecode(h.writes.single.body), {
      'current_country': 'Spain',
      'current_city': 'Madrid',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-account reauthentication cancels old GPS and releases UI', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.startGps(tester);
    h.api.token = 'fresh-alice-session';
    h.auth.change(_alice);
    await tester.pump();
    h.resolveGps();
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
    expect(find.byIcon(Icons.my_location_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile location follows the current account after switching', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.ensureVisible(find.text('France · Paris'));
    await h.change(tester, _bob);
    expect(find.text('France · Paris'), findsNothing);
    expect(find.text('United States · New York'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('GPS started by old account cannot update the new account', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.startGps(tester);
    await h.change(tester, _bob);
    h.resolveGps();
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
    expect(find.text('United States · New York'), findsOneWidget);
    expect(find.text('Spain · Madrid'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late profile acknowledgement cannot affect another session UI', (
    tester,
  ) async {
    final h = _Harness()..patchReply = Completer<http.Response>();
    await h.mount(tester);
    await h.startGps(tester);
    h.resolveGps();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(h.writes.length, 1);
    expect(h.writes.single.headers['Authorization'], 'Bearer token-alice');
    await h.change(tester, _bob);
    h.patchReply!.complete(http.Response('{}', 200));
    await tester.pumpAndSettle();
    expect(find.text('United States · New York'), findsOneWidget);
    expect(find.textContaining('로그인 정보가 변경'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
