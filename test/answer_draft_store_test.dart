import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/features/answers/answer_draft_store.dart';
import 'package:local_qa_concierge/shared/models/evidence_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

AnswerDraft draft({
  String question = 'question-a',
  String body = 'A carefully checked answer',
  String? requestId,
}) => AnswerDraft(
  questionId: question,
  body: body,
  evidenceSummary: 'Verified from current timetable',
  verificationMethod: '공식 사이트에서 확인',
  linkUrl: 'https://example.test/draft',
  linkTitle: 'Unfinished title',
  linkDescription: 'Unfinished note',
  sourceType: 'official',
  links: const [
    EvidenceLink(
      url: 'https://example.test/evidence',
      sourceType: 'official',
      title: 'Timetable',
      description: 'Current',
    ),
  ],
  pending: requestId == null
      ? null
      : AnswerSubmission(
          requestId: requestId,
          body: body,
          evidenceSummary: 'Verified from current timetable',
          verificationMethod: '공식 사이트에서 확인',
          links: const [
            EvidenceLink(
              url: 'https://example.test/evidence',
              sourceType: 'official',
            ),
          ],
          confirmedEvidence: true,
          confirmedNoAi: true,
          confirmedNoGuess: true,
        ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'all text and link draft round-trip; unsent confirmations and credentials are absent',
    () async {
      final store = AnswerDraftStore(server: 'server-a');
      final value = draft();
      await store.save('user-a', value);
      expect(
        (await store.read('user-a', 'question-a'))?.toJson(),
        value.toJson(),
      );
      final encoded = jsonEncode(value.toJson());
      expect(encoded, isNot(contains('confirmed_evidence')));
      expect(encoded, isNot(contains('password')));
      expect(encoded, isNot(contains('token')));
      expect(encoded, isNot(contains('photo')));
    },
  );

  test(
    'drafts isolate API, owner and question; deletion removes only matching owner',
    () async {
      final store = AnswerDraftStore(server: 'server-a');
      final other = AnswerDraftStore(server: 'server-b');
      await store.save('user-a', draft());
      await store.save('user-a', draft(question: 'question-b'));
      await store.save('user-b', draft());
      await other.save('user-a', draft());
      expect(await store.read('user-a', 'question-c'), isNull);
      await store.clearOwner('user-a');
      expect(await store.read('user-a', 'question-a'), isNull);
      expect(await store.read('user-a', 'question-b'), isNull);
      expect(await store.read('user-b', 'question-a'), isNotNull);
      expect(await other.read('user-a', 'question-a'), isNotNull);
      await expectLater(store.save('user-a', draft()), throwsStateError);
    },
  );

  test(
    'late completed or rejected request cannot erase or replace a newer draft',
    () async {
      final store = AnswerDraftStore(server: 'server-a');
      await store.save('user-a', draft(requestId: 'answer-new-request-00001'));
      await store.completeAttempt(
        'user-a',
        'question-a',
        'answer-old-request-00001',
      );
      await store.releaseAttempt(
        'user-a',
        draft(body: 'old rejected body'),
        'answer-old-request-00001',
      );
      expect(
        (await store.read('user-a', 'question-a'))?.pending?.requestId,
        'answer-new-request-00001',
      );
      await store.completeAttempt(
        'user-a',
        'question-a',
        'answer-new-request-00001',
      );
      await store.releaseAttempt('user-a', draft(), 'answer-new-request-00001');
      expect(await store.read('user-a', 'question-a'), isNull);
    },
  );

  test(
    'pending replay retains exact immutable links and already-confirmed flags',
    () async {
      final value = draft(requestId: 'answer-retry-request-0001');
      final store = AnswerDraftStore(server: 'server-a');
      await store.save('user-a', value);
      final restored = await store.read('user-a', 'question-a');
      expect(restored?.pending?.toJson(), value.pending?.toJson());
      expect(() => restored!.pending!.links.clear(), throwsUnsupportedError);
      final corrupt = value.toJson();
      (corrupt['pending'] as Map)['confirmed_no_ai'] = false;
      expect(() => AnswerDraft.fromJson(corrupt), throwsFormatException);
    },
  );

  test(
    'bounded timeout does not let a late storage write defeat later clear',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final gate = Completer<SharedPreferences>();
      var calls = 0;
      final store = AnswerDraftStore(
        server: 'server-a',
        timeout: const Duration(milliseconds: 15),
        preferences: () => ++calls == 1 ? gate.future : Future.value(prefs),
      );
      await expectLater(
        store.save('user-a', draft()),
        throwsA(isA<TimeoutException>()),
      );
      final clear = store.clear('user-a', 'question-a');
      gate.complete(prefs);
      await clear;
      expect(await store.read('user-a', 'question-a'), isNull);
    },
  );

  test(
    'corrupt or failed reads are surfaced without overwriting existing text',
    () async {
      final store = AnswerDraftStore(server: 'server-a');
      await store.save('user-a', draft());
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      await prefs.setString(key, '{bad-json');
      await expectLater(
        store.read('user-a', 'question-a'),
        throwsFormatException,
      );
      expect(prefs.getString(key), '{bad-json');
      final broken = AnswerDraftStore(
        server: 'server-a',
        preferences: () async => throw StateError('unavailable'),
      );
      await expectLater(broken.read('user-a', 'question-a'), throwsStateError);
    },
  );
}
