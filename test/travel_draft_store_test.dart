import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/features/questions/travel_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const travelDraftFixture = TravelQuestionDraft(
  title: '공항에서 시내 이동',
  body: '도착 시각은 밤 10시이고 가방이 두 개 있습니다.',
  category: '교통',
  reward: '150',
  country: 'Spain',
  city: 'Málaga',
  region: '',
  latitude: 36.7213,
  longitude: -4.4214,
  isManualLocation: true,
  imageCount: 2,
  submissionPending: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'draft text round trips while photos and credentials are never serialized',
    () async {
      final store = TravelDraftStore(server: 'test-server');
      await store.save('user-a', travelDraftFixture);
      final restored = await store.read('user-a');
      expect(restored?.toJson(), travelDraftFixture.toJson());
      expect(restored?.toJson().keys, isNot(contains('images')));
      expect(restored?.toJson().keys, isNot(contains('token')));
    },
  );

  test('same device isolates both account and API server namespaces', () async {
    final store = TravelDraftStore(server: 'test-server');
    final other = TravelDraftStore(server: 'other-server');
    await store.save('user-a', travelDraftFixture);
    expect(await store.read('user-b'), isNull);
    expect(await other.read('user-a'), isNull);
    expect((await store.read('user-a'))?.title, travelDraftFixture.title);
  });

  test('serialized clear wins over an older in-flight draft write', () async {
    final store = TravelDraftStore(server: 'test-server');
    final save = store.save('user-a', travelDraftFixture);
    final clear = store.clear('user-a');
    await Future.wait([save, clear]);
    expect(await store.read('user-a'), isNull);
  });

  test(
    'storage failures are reported instead of claiming a saved draft',
    () async {
      final store = TravelDraftStore(
        server: 'test-server',
        preferences: () async => throw StateError('unavailable'),
      );
      await expectLater(
        store.save('user-a', travelDraftFixture),
        throwsStateError,
      );
      await expectLater(store.read('user-a'), throwsStateError);
      await expectLater(store.clear('user-a'), throwsStateError);
    },
  );

  test(
    'pending text snapshot persists its operation ID without editing its payload',
    () {
      final pending = TravelQuestionDraft.fromJson({
        ...travelDraftFixture.toJson(),
        'image_count': 0,
        'submission_pending': true,
        'request_id': 'operation-1234567890',
      });
      final restored = TravelQuestionDraft.fromJson(pending.toJson());
      expect(restored.requestId, 'operation-1234567890');
      expect(restored.submissionPending, isTrue);
      expect(restored.body, travelDraftFixture.body);
    },
  );
}
