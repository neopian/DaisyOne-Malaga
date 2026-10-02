import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_draft.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_repository.dart';

import 'exchange_issue_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient client;
  late ExchangeIssueTestAuth auth;
  late ExchangeIssueTestRepository repository;
  late int deniedCount;
  late int missingCount;

  setUp(() {
    client = ApiClient(baseUrl: 'https://example.test/api');
    auth = ExchangeIssueTestAuth(client);
    repository = ExchangeIssueTestRepository(client);
    deniedCount = 0;
    missingCount = 0;
  });

  tearDown(() {
    auth.dispose();
    client.dispose();
  });

  ExchangeIssueDraft makeDraft({
    String questionId = 'question',
    String? issueId,
    AdminExchangeIssueRecord? adminRecord,
  }) {
    final draft = ExchangeIssueDraft(
      repository: repository,
      auth: auth,
      questionId: questionId,
      issueId: issueId,
      adminRecord: adminRecord,
      onAccessDenied: () => deniedCount++,
      onMissing: () => missingCount++,
    );
    addTearDown(draft.dispose);
    return draft;
  }

  test('repeated submit and load taps share a single frozen create', () async {
    final delayed = Completer<String>();
    repository.createResponse = (_, _, _) => delayed.future;
    final draft = makeDraft()
      ..reason = ExchangeIssueReason.answerProblem
      ..text = '  original description  ';
    final first = draft.submit();
    final duplicate = draft.submit();
    final load = draft.load();
    expect(identical(first, duplicate), isTrue);
    expect(identical(first, load), isTrue);
    expect(draft.busy, isTrue);
    expect(draft.frozen, isTrue);
    expect(draft.canEdit, isFalse);
    expect(draft.canSubmit, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(repository.createCalls, [
      (
        questionId: 'question',
        reason: ExchangeIssueReason.answerProblem,
        details: 'original description',
      ),
    ]);
    delayed.complete('created-issue');
    await first;
    expect(repository.ownCalls, ['created-issue']);
    expect(draft.record?.id, 'created-issue');
    expect(draft.text, isEmpty);
    expect(draft.busy, isFalse);
    expect(draft.canSubmit, isFalse);
  });

  for (final failure in [
    const ApiException('offline'),
    const ApiException('timeout', status: 408),
    const ApiException('rate limited', status: 429, code: 'ISSUE_LIMIT'),
    const ApiException('server error', status: 500),
    const ApiException('uncertain conflict', status: 409),
  ]) {
    test(
      'uncertain ${failure.status ?? failure.code} keeps the original intent across reopen',
      () async {
        repository.createResponse = (_, _, _) async => throw failure;
        final retainedDraft = makeDraft()
          ..reason = ExchangeIssueReason.cannotContinue
          ..text = '  original private description  ';
        await retainedDraft.submit();
        expect(retainedDraft.frozen, isTrue);
        expect(retainedDraft.canEdit, isFalse);
        expect(retainedDraft.canSubmit, isTrue);
        expect(retainedDraft.issueId, isNull);
        expect(retainedDraft.error, same(failure));
        // Closing a dialog leaves its page-owned draft intact; reopening gets
        // the same object, including the uncertain submission intent.
        final reopenedDraft = retainedDraft;
        expect(reopenedDraft, same(retainedDraft));
        reopenedDraft
          ..reason = ExchangeIssueReason.other
          ..text = 'changed controller value';
        repository.createResponse = (_, _, _) async => 'created-issue';
        await reopenedDraft.submit();
        expect(repository.createCalls, hasLength(2));
        expect(repository.createCalls.last, repository.createCalls.first);
        expect(
          repository.createCalls.last.details,
          'original private description',
        );
        expect(reopenedDraft.record?.id, 'created-issue');
      },
    );
  }

  test(
    'reopening while create is pending keeps one request and its result',
    () async {
      final delayed = Completer<String>();
      repository.createResponse = (_, _, _) => delayed.future;
      final retainedDraft = makeDraft()..text = 'description';
      final pending = retainedDraft.submit();
      await Future<void>.delayed(Duration.zero);
      final reopenedDraft = retainedDraft;
      final retry = reopenedDraft.submit();
      expect(retry, same(pending));
      expect(repository.createCalls, hasLength(1));
      delayed.complete('created-issue');
      await retry;
      expect(reopenedDraft.record?.id, 'created-issue');
      expect(repository.createCalls, hasLength(1));
    },
  );

  for (final status in [400, 422]) {
    test(
      'explicit $status validation rejection permits editing unsent intent',
      () async {
        repository.createResponse = (_, _, _) async =>
            throw ApiException('invalid', code: 'VALIDATION', status: status);
        final draft = makeDraft()..text = 'rejected description';
        await draft.submit();
        expect(draft.frozen, isFalse);
        expect(draft.canEdit, isTrue);
        expect(draft.text, 'rejected description');
        draft
          ..reason = ExchangeIssueReason.other
          ..text = 'corrected description';
        repository.createResponse = (_, _, _) async => 'created-issue';
        await draft.submit();
        expect(repository.createCalls.last.reason, ExchangeIssueReason.other);
        expect(repository.createCalls.last.details, 'corrected description');
      },
    );
  }

  for (final text in [
    List.filled(1001, 'a').join(),
    List.filled(501, '😀').join(),
    'description\u0000hidden suffix',
  ]) {
    test(
      'invalid text is editable and never transmitted (${text.length} code units)',
      () async {
        final draft = makeDraft()..text = text;
        await draft.submit();
        expect(repository.createCalls, isEmpty);
        expect(draft.frozen, isFalse);
        expect(draft.canEdit, isTrue);
        expect(
          draft.error,
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'VALIDATION',
          ),
        );
      },
    );
  }

  test('1000 UTF-16 code units after trimming remains valid', () async {
    final details = List.filled(500, '😀').join();
    final draft = makeDraft()..text = '  $details  ';
    await draft.submit();
    expect(repository.createCalls.single.details, details);
    expect(draft.record?.id, 'created-issue');
  });

  test(
    'acknowledged create with failed direct GET can never post again',
    () async {
      repository.ownResponse = (_) async => throw const ApiException('offline');
      final draft = makeDraft()..text = 'private details';
      await draft.submit();
      expect(draft.issueId, 'created-issue');
      expect(draft.record, isNull);
      expect(draft.error, isA<ApiException>());
      expect(draft.text, isEmpty);
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isFalse);
      await draft.submit();
      expect(repository.createCalls, hasLength(1));
      expect(repository.ownCalls, ['created-issue']);
      repository.ownResponse = (id) async => exchangeIssue(id);
      await draft.load();
      expect(repository.createCalls, hasLength(1));
      expect(repository.ownCalls, ['created-issue', 'created-issue']);
      expect(draft.record?.id, 'created-issue');
      expect(draft.error, isNull);
    },
  );

  test(
    'existing issue loads exact reference even beyond the first own page',
    () async {
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: List.generate(25, (index) => exchangeIssue('other-$index')),
        nextCursor: 'another-page',
      );
      repository.ownResponse = (id) async =>
          exchangeIssue(id, questionId: 'hidden-question');
      final draft = makeDraft(
        questionId: 'hidden-question',
        issueId: 'own-issue-on-later-page',
      );
      await draft.load();
      expect(repository.pageCalls, isEmpty);
      expect(repository.ownCalls, ['own-issue-on-later-page']);
      expect(repository.createCalls, isEmpty);
      expect(draft.record?.questionId, 'hidden-question');
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isFalse);
    },
  );

  for (final mismatch in ['id', 'question']) {
    test(
      'direct GET rejects mismatched $mismatch without displaying data',
      () async {
        repository.ownResponse = (id) async => exchangeIssue(
          mismatch == 'id' ? 'another-issue' : id,
          questionId: mismatch == 'question' ? 'another-question' : 'question',
        );
        final draft = makeDraft(issueId: 'own-issue');
        await draft.load();
        expect(draft.record, isNull);
        expect(draft.error, isA<ApiException>());
        expect(draft.issueId, 'own-issue');
        expect(repository.createCalls, isEmpty);
      },
    );
  }

  for (final change in ['account', 'role', 'suspended', 'logout']) {
    test('$change revokes participant text and ignores late create', () async {
      final delayed = Completer<String>();
      repository.createResponse = (_, _, _) => delayed.future;
      final draft = makeDraft()..text = 'private draft';
      final pending = draft.submit();
      await Future<void>.delayed(Duration.zero);
      auth.change(switch (change) {
        'account' => exchangeIssueUser(id: 'another'),
        'role' => exchangeIssueUser(isAdmin: true),
        'suspended' => exchangeIssueUser(isSuspended: true),
        _ => null,
      });
      expect(draft.denied, isTrue);
      expect(draft.text, isEmpty);
      expect(draft.issueId, isNull);
      expect(draft.record, isNull);
      expect(draft.error, isNull);
      expect(draft.frozen, isFalse);
      expect(draft.busy, isFalse);
      delayed.complete('late-private-issue');
      await pending;
      await draft.load();
      await draft.submit();
      expect(draft.issueId, isNull);
      expect(repository.ownCalls, isEmpty);
      expect(repository.createCalls, hasLength(1));
    });
  }

  test(
    'scope change during direct GET clears loaded details and late refresh',
    () async {
      final draft = makeDraft(issueId: 'own-issue');
      await draft.load();
      expect(draft.record, isNotNull);
      final delayed = Completer<ExchangeIssueRecord>();
      repository.ownResponse = (_) => delayed.future;
      final pending = draft.load();
      await Future<void>.delayed(Duration.zero);
      auth.change(exchangeIssueUser(id: 'another'));
      expect(draft.record, isNull);
      expect(draft.issueId, isNull);
      delayed.complete(
        exchangeIssue('own-issue', details: 'late private data'),
      );
      await pending;
      expect(draft.record, isNull);
      expect(draft.denied, isTrue);
    },
  );

  for (final failure in [
    const ApiException('unauthenticated', status: 401),
    const ApiException('forbidden', status: 403),
    const ApiException('changed session', code: 'session_changed'),
  ]) {
    test(
      '${failure.status ?? failure.code} revokes a draft and its owning feed',
      () async {
        repository.ownResponse = (_) async => throw failure;
        final draft = makeDraft(issueId: 'own-issue')..text = 'private details';
        await draft.load();
        expect(draft.denied, isTrue);
        expect(draft.text, isEmpty);
        expect(draft.issueId, isNull);
        expect(draft.record, isNull);
        expect(draft.error, isNull);
        expect(deniedCount, 1);
        await draft.load();
        expect(deniedCount, 1);
        expect(repository.ownCalls, hasLength(1));
      },
    );
  }

  test(
    'own record 404 clears only that draft and reports local removal',
    () async {
      final draft = makeDraft(issueId: 'removed-issue');
      await draft.load();
      expect(draft.record, isNotNull);
      draft.text = 'private stale editor';
      repository.ownResponse = (_) async =>
          throw const ApiException('removed record', status: 404);
      await draft.load();
      expect(draft.missing, isTrue);
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isFalse);
      expect(draft.record, isNull);
      expect(draft.adminRecord, isNull);
      expect(draft.issueId, isNull);
      expect(draft.text, isEmpty);
      expect(draft.frozen, isFalse);
      expect(deniedCount, 0);
      expect(missingCount, 1);
      await draft.load();
      await draft.submit();
      expect(repository.ownCalls, ['removed-issue', 'removed-issue']);
      expect(repository.createCalls, isEmpty);
      expect(missingCount, 1);
    },
  );

  test(
    'admin review 404 clears private notes without denying the whole page',
    () async {
      auth.change(exchangeIssueUser(isAdmin: true));
      repository.reviewResponse = (_, _) async =>
          throw const ApiException('removed record', status: 404);
      final draft = makeDraft(
        adminRecord: adminExchangeIssue(
          'removed-issue',
          reviewNote: 'stored private note',
        ),
      )..text = 'pending private note';
      await draft.submit();
      expect(draft.missing, isTrue);
      expect(draft.reviewed, isFalse);
      expect(draft.record, isNull);
      expect(draft.adminRecord, isNull);
      expect(draft.text, isEmpty);
      expect(draft.frozen, isFalse);
      expect(draft.canSubmit, isFalse);
      expect(deniedCount, 0);
      expect(missingCount, 1);
      await draft.submit();
      expect(repository.reviewCalls, hasLength(1));
    },
  );

  test(
    'initial signed out, suspended and non-admin drafts do not mutate',
    () async {
      auth.change(null);
      final signedOut = makeDraft()..text = 'private';
      await signedOut.submit();
      expect(signedOut.denied, isTrue);
      auth.change(exchangeIssueUser(isSuspended: true));
      final suspended = makeDraft()..text = 'private';
      await suspended.submit();
      expect(suspended.denied, isTrue);
      auth.change(exchangeIssueUser());
      final nonAdmin = makeDraft(adminRecord: adminExchangeIssue('issue'))
        ..text = 'note';
      await nonAdmin.submit();
      expect(nonAdmin.denied, isTrue);
      expect(repository.createCalls, isEmpty);
      expect(repository.reviewCalls, isEmpty);
    },
  );

  for (final code in ['ISSUE_ALREADY_EXISTS', 'EXCHANGE_NOT_ELIGIBLE']) {
    test('$code freezes rejected create and prevents another post', () async {
      repository.createResponse = (_, _, _) async =>
          throw ApiException('conflict', status: 409, code: code);
      final draft = makeDraft()..text = 'private description';
      await draft.submit();
      expect(draft.frozen, isTrue);
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isFalse);
      expect(draft.text, 'private description');
      expect(draft.record, isNull);
      expect(
        draft.error,
        isA<ApiException>().having((error) => error.code, 'code', code),
      );
      await draft.submit();
      expect(repository.createCalls, hasLength(1));
      expect(repository.ownCalls, isEmpty);
    });
  }

  test(
    'review conflict freezes private note without claiming success or resubmitting',
    () async {
      auth.change(exchangeIssueUser(isAdmin: true));
      repository.reviewResponse = (_, _) async => throw const ApiException(
        'already reviewed',
        status: 409,
        code: 'ISSUE_ALREADY_REVIEWED',
      );
      final draft = makeDraft(adminRecord: adminExchangeIssue('admin-issue'))
        ..text = '  original private note  ';
      await draft.submit();
      expect(draft.frozen, isTrue);
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isFalse);
      expect(draft.reviewed, isFalse);
      expect(
        draft.error,
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'ISSUE_ALREADY_REVIEWED',
        ),
      );
      expect(draft.text, '  original private note  ');
      await draft.submit();
      expect(repository.reviewCalls, [
        (id: 'admin-issue', note: 'original private note'),
      ]);
      expect(repository.createCalls, isEmpty);
      expect(repository.ownCalls, isEmpty);
      expect(draft.reviewed, isFalse);
    },
  );

  test(
    'uncertain admin review retry preserves note and acknowledges once',
    () async {
      auth.change(exchangeIssueUser(isAdmin: true));
      repository.reviewResponse = (_, _) async =>
          throw const ApiException('timeout', status: 408);
      final draft = makeDraft(adminRecord: adminExchangeIssue('admin-issue'))
        ..text = '  original private note  ';
      await draft.submit();
      expect(draft.frozen, isTrue);
      expect(draft.canEdit, isFalse);
      expect(draft.canSubmit, isTrue);
      expect(draft.reviewed, isFalse);
      draft.text = 'different note after reopening';
      repository.reviewResponse = (_, _) async {};
      await draft.submit();
      expect(repository.reviewCalls, [
        (id: 'admin-issue', note: 'original private note'),
        (id: 'admin-issue', note: 'original private note'),
      ]);
      expect(repository.createCalls, isEmpty);
      expect(repository.ownCalls, isEmpty);
      expect(draft.reviewed, isTrue);
      expect(draft.text, isEmpty);
      expect(draft.canSubmit, isFalse);
      await draft.submit();
      expect(repository.reviewCalls, hasLength(2));
    },
  );

  test('already reviewed admin record cannot be edited or submitted', () async {
    auth.change(exchangeIssueUser(isAdmin: true));
    final draft = makeDraft(
      adminRecord: adminExchangeIssue(
        'issue',
        status: 'reviewed',
        reviewNote: 'existing note',
      ),
    );
    expect(draft.canEdit, isFalse);
    expect(draft.canSubmit, isFalse);
    await draft.load();
    await draft.submit();
    expect(repository.reviewCalls, isEmpty);
    expect(repository.ownCalls, isEmpty);
  });

  for (final change in ['account', 'role', 'suspended', 'logout']) {
    test(
      '$change clears private admin note and ignores pending review',
      () async {
        auth.change(exchangeIssueUser(isAdmin: true));
        final delayed = Completer<void>();
        repository.reviewResponse = (_, _) => delayed.future;
        final draft = makeDraft(
          adminRecord: adminExchangeIssue(
            'issue',
            reviewNote: 'stored private note',
          ),
        )..text = 'pending private note';
        final pending = draft.submit();
        await Future<void>.delayed(Duration.zero);
        auth.change(switch (change) {
          'account' => exchangeIssueUser(id: 'another-admin', isAdmin: true),
          'role' => exchangeIssueUser(),
          'suspended' => exchangeIssueUser(isAdmin: true, isSuspended: true),
          _ => null,
        });
        expect(draft.adminRecord, isNull);
        expect(draft.text, isEmpty);
        expect(draft.denied, isTrue);
        expect(draft.frozen, isFalse);
        delayed.complete();
        await pending;
        expect(draft.reviewed, isFalse);
        expect(repository.reviewCalls, hasLength(1));
      },
    );
  }

  test(
    'disposing retained draft clears sensitive text and ignores late reply',
    () async {
      final delayed = Completer<String>();
      repository.createResponse = (_, _, _) => delayed.future;
      final draft = ExchangeIssueDraft(
        repository: repository,
        auth: auth,
        questionId: 'question',
        onAccessDenied: () {},
      )..text = 'private description';
      final pending = draft.submit();
      await Future<void>.delayed(Duration.zero);
      draft.dispose();
      delayed.complete('late-issue');
      await pending;
      expect(draft.text, isEmpty);
      expect(draft.record, isNull);
      expect(draft.adminRecord, isNull);
      expect(repository.ownCalls, isEmpty);
    },
  );
}
