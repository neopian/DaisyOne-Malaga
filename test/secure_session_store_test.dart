import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/features/auth/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DelayedSessionStore implements SessionStore {
  final writeGate = Completer<void>();
  String? token;
  int clears = 0;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async {
    await writeGate.future;
    token = value;
  }

  @override
  Future<void> clear() async {
    clears++;
    token = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'native remembered token is only in secure store; clear removes both stores',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = SecureSessionStore(key: 'test-server-session');
      await store.write('secure-token');
      expect(preferences.getKeys(), isEmpty);
      expect(await store.read(), 'secure-token');
      expect(
        await const FlutterSecureStorage().read(key: 'test-server-session'),
        'secure-token',
      );
      await store.clear();
      expect(await store.read(), isNull);
      expect(preferences.getKeys(), isEmpty);
    },
  );

  test(
    'legacy plaintext token is removed and requires new login, never copied',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(legacySessionTokenKey, 'legacy-plaintext');
      final store = SecureSessionStore(key: 'new-server-session');
      await expectLater(store.read(), throwsA(isA<LegacySessionRemoved>()));
      expect(preferences.containsKey(legacySessionTokenKey), isFalse);
      expect(
        await const FlutterSecureStorage().read(key: 'new-server-session'),
        isNull,
      );
      expect(await store.read(), isNull);
    },
  );

  test(
    'secure token wins and old plaintext storage is still removed',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(legacySessionTokenKey, 'legacy-plaintext');
      FlutterSecureStorage.setMockInitialValues({
        'secure-server': 'fresh-token',
      });
      final store = SecureSessionStore(key: 'secure-server');
      expect(await store.read(), 'fresh-token');
      expect(preferences.containsKey(legacySessionTokenKey), isFalse);
    },
  );

  test(
    'a different API namespace cannot restore another server session',
    () async {
      final first = SecureSessionStore(key: 'server-one');
      final second = SecureSessionStore(key: 'server-two');
      await first.write('first-token');
      expect(await second.read(), isNull);
      expect(await first.read(), 'first-token');
    },
  );
  test(
    'a timed-out platform write cannot overwrite later session cleanup',
    () async {
      final delegate = DelayedSessionStore();
      final store = SerializedSessionStore(delegate);
      await expectLater(
        store.write('old-token').timeout(const Duration(milliseconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
      final cleanup = store.clear();
      await Future<void>.delayed(Duration.zero);
      expect(delegate.clears, 0);
      delegate.writeGate.complete();
      await cleanup;
      expect(delegate.clears, 1);
      expect(delegate.token, isNull);
    },
  );
}
