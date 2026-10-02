import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_feed.dart';
import 'package:local_qa_concierge/features/exchange_issues/exchange_issue_repository.dart';

import 'exchange_issue_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient client;
  late ExchangeIssueTestAuth auth;
  late ExchangeIssueTestRepository repository;

  setUp(() {
    client = ApiClient(baseUrl: 'https://example.test/api');
    auth = ExchangeIssueTestAuth(client);
    repository = ExchangeIssueTestRepository(client);
  });

  tearDown(() {
    auth.dispose();
    client.dispose();
  });

  ExchangeIssueFeed makeFeed([
    ExchangeIssueView view = ExchangeIssueView.mine,
  ]) {
    final feed = ExchangeIssueFeed(
      repository: repository,
      auth: auth,
      view: view,
    );
    addTearDown(feed.dispose);
    return feed;
  }

  test(
    'removing a missing detail ignores a previously started list response',
    () async {
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [
          exchangeIssue('deleted', questionId: 'deleted-question'),
          exchangeIssue('other', questionId: 'other-question'),
        ],
      );
      final feed = makeFeed();
      await feed.refresh();
      final pending = Completer<ExchangeIssuePageData>();
      repository.pageResponse = (_, _) => pending.future;
      final oldRequest = feed.refresh();
      await Future<void>.delayed(Duration.zero);
      feed.removeQuestion('deleted-question');
      expect(feed.items.map((row) => row.id), ['other']);
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [exchangeIssue('other', questionId: 'other-question')],
      );
      await feed.refresh();
      pending.complete(
        ExchangeIssuePageData(
          items: [exchangeIssue('deleted', questionId: 'deleted-question')],
        ),
      );
      await oldRequest;
      expect(feed.items.map((row) => row.id), ['other']);
      expect(feed.canRead, isTrue);
    },
  );

  test(
    'signed out and suspended accounts do not request participant rows',
    () async {
      auth.change(null);
      final feed = makeFeed();
      await feed.refresh();
      expect(feed.accessDenied, isTrue);
      auth.change(exchangeIssueUser(isSuspended: true));
      await feed.refresh();
      expect(feed.accessDenied, isTrue);
      expect(repository.pageCalls, isEmpty);
    },
  );

  for (final view in [
    ExchangeIssueView.adminOpen,
    ExchangeIssueView.adminReviewed,
  ]) {
    test('${view.name} requires current unsuspended admin access', () async {
      final feed = makeFeed(view);
      await feed.refresh();
      expect(feed.accessDenied, isTrue);
      expect(repository.pageCalls, isEmpty);
      auth.change(exchangeIssueUser(isAdmin: true, isSuspended: true));
      await feed.refresh();
      expect(repository.pageCalls, isEmpty);
      auth.change(exchangeIssueUser(isAdmin: true));
      await feed.refresh();
      expect(feed.accessDenied, isFalse);
      expect(repository.pageCalls.single.view, view);
    });
  }

  test('initial fetch and repeated refresh taps share one request', () async {
    final delayed = Completer<ExchangeIssuePageData>();
    repository.pageResponse = (_, _) => delayed.future;
    final feed = makeFeed();
    final first = feed.refresh();
    final duplicate = feed.refresh();
    final retry = feed.retry();
    await Future<void>.delayed(Duration.zero);
    expect(identical(first, duplicate), isTrue);
    expect(identical(first, retry), isTrue);
    expect(repository.pageCalls, hasLength(1));
    expect(feed.isLoading, isTrue);
    delayed.complete(ExchangeIssuePageData(items: [exchangeIssue('first')]));
    await first;
    expect(feed.isLoading, isFalse);
    expect(feed.hasLoaded, isTrue);
    expect(feed.items.single.id, 'first');
  });

  test(
    'paging failure retains rows and retries identical cursor once',
    () async {
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [exchangeIssue('first')],
        nextCursor: 'opaque-cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      final delayed = Completer<ExchangeIssuePageData>();
      repository.pageResponse = (_, _) => delayed.future;
      final first = feed.loadMore();
      final duplicate = feed.loadMore();
      await Future<void>.delayed(Duration.zero);
      expect(identical(first, duplicate), isTrue);
      expect(repository.pageCalls, hasLength(2));
      delayed.completeError(const ApiException('offline'));
      await first;
      expect(feed.items.map((row) => row.id), ['first']);
      expect(feed.nextCursor, 'opaque-cursor');
      expect(feed.error, isA<ApiException>());
      expect(feed.hasLoaded, isTrue);
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [
          exchangeIssue('first', status: 'reviewed'),
          exchangeIssue('second'),
        ],
      );
      await feed.retry();
      expect(repository.pageCalls.last.cursor, 'opaque-cursor');
      expect(feed.items.map((row) => row.id), ['first', 'second']);
      expect((feed.items.first as ExchangeIssueRecord).status, 'reviewed');
      expect(feed.nextCursor, isNull);
      expect(feed.error, isNull);
      await feed.loadMore();
      expect(repository.pageCalls, hasLength(3));
    },
  );

  for (final change in ['account', 'role', 'suspended', 'logout']) {
    test(
      '$change removes admin data immediately and ignores late response',
      () async {
        auth.change(exchangeIssueUser(isAdmin: true));
        repository.pageResponse = (_, _) async => ExchangeIssuePageData(
          items: [
            adminExchangeIssue('private', reviewNote: 'private operator note'),
          ],
          nextCursor: 'private-cursor',
        );
        final feed = makeFeed(ExchangeIssueView.adminOpen);
        await feed.refresh();
        final old = Completer<ExchangeIssuePageData>();
        repository.pageResponse = (_, _) => old.future;
        final pending = feed.loadMore();
        await Future<void>.delayed(Duration.zero);
        repository.pageResponse = (_, _) async =>
            const ExchangeIssuePageData(items: []);
        auth.change(switch (change) {
          'account' => exchangeIssueUser(id: 'another-admin', isAdmin: true),
          'role' => exchangeIssueUser(isAdmin: false),
          'suspended' => exchangeIssueUser(isAdmin: true, isSuspended: true),
          _ => null,
        });
        expect(feed.items, isEmpty);
        expect(feed.nextCursor, isNull);
        expect(feed.error, isNull);
        expect(feed.hasLoaded, isFalse);
        old.complete(
          ExchangeIssuePageData(items: [adminExchangeIssue('late-private')]),
        );
        await pending;
        await feed.refresh();
        expect(feed.items, isEmpty);
        if (change == 'account') {
          expect(repository.pageCalls.last.cursor, isNull);
          expect(feed.accessDenied, isFalse);
        } else {
          expect(repository.pageCalls, hasLength(2));
          expect(feed.accessDenied, isTrue);
        }
      },
    );
  }

  test('late account failure cannot deny the replacement account', () async {
    final old = Completer<ExchangeIssuePageData>();
    repository.pageResponse = (_, _) => old.future;
    final feed = makeFeed();
    final pending = feed.refresh();
    await Future<void>.delayed(Duration.zero);
    repository.pageResponse = (_, _) async =>
        ExchangeIssuePageData(items: [exchangeIssue('new-account')]);
    auth.change(exchangeIssueUser(id: 'new-account'));
    await feed.refresh();
    old.completeError(const ApiException('expired old account', status: 401));
    await pending;
    expect(feed.accessDenied, isFalse);
    expect(feed.items.single.id, 'new-account');
    expect(feed.error, isNull);
  });

  for (final failure in [
    const ApiException('unauthenticated', status: 401),
    const ApiException('forbidden', status: 403),
    const ApiException('changed session', code: 'session_changed'),
  ]) {
    test(
      '${failure.status ?? failure.code} revokes cached rows until scope changes',
      () async {
        repository.pageResponse = (_, _) async => ExchangeIssuePageData(
          items: [exchangeIssue('private')],
          nextCursor: 'private-cursor',
        );
        final feed = makeFeed();
        await feed.refresh();
        repository.pageResponse = (_, _) async => throw failure;
        await feed.loadMore();
        expect(feed.items, isEmpty);
        expect(feed.nextCursor, isNull);
        expect(feed.error, isNull);
        expect(feed.hasLoaded, isFalse);
        expect(feed.isLoading, isFalse);
        expect(feed.accessDenied, isTrue);
        await feed.retry();
        await feed.refresh();
        expect(repository.pageCalls, hasLength(2));
        repository.pageResponse = (_, _) async =>
            const ExchangeIssuePageData(items: []);
        auth.change(exchangeIssueUser(id: 'new-account'));
        await feed.refresh();
        expect(feed.accessDenied, isFalse);
        expect(repository.pageCalls, hasLength(3));
      },
    );
  }

  test(
    'list 404 preserves readable rows and retries its page normally',
    () async {
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [exchangeIssue('readable')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      repository.pageResponse = (_, _) async =>
          throw const ApiException('missing page', status: 404);
      await feed.loadMore();
      expect(feed.accessDenied, isFalse);
      expect(feed.items.single.id, 'readable');
      expect(feed.nextCursor, 'cursor');
      expect(feed.hasLoaded, isTrue);
      expect(
        feed.error,
        isA<ApiException>().having((error) => error.status, 'status', 404),
      );
      repository.pageResponse = (_, _) async =>
          ExchangeIssuePageData(items: [exchangeIssue('another-readable')]);
      await feed.retry();
      expect(repository.pageCalls.last.cursor, 'cursor');
      expect(feed.items.map((row) => row.id), ['readable', 'another-readable']);
      expect(feed.error, isNull);
    },
  );

  test('explicit denial invalidates an in-flight page', () async {
    final delayed = Completer<ExchangeIssuePageData>();
    repository.pageResponse = (_, _) => delayed.future;
    final feed = makeFeed();
    final pending = feed.refresh();
    await Future<void>.delayed(Duration.zero);
    feed.denyAccess();
    delayed.complete(ExchangeIssuePageData(items: [exchangeIssue('late')]));
    await pending;
    expect(feed.accessDenied, isTrue);
    expect(feed.items, isEmpty);
    expect(feed.isLoading, isFalse);
  });

  test('refresh loaded depth commits only after every page succeeds', () async {
    repository.pageResponse = (_, cursor) async => ExchangeIssuePageData(
      items: [exchangeIssue(cursor == null ? 'first' : 'second')],
      nextCursor: cursor == null ? 'cursor' : null,
    );
    final feed = makeFeed();
    await feed.refresh();
    await feed.loadMore();
    repository.pageResponse = (_, cursor) async {
      if (cursor != null) throw const ApiException('offline');
      return ExchangeIssuePageData(
        items: [exchangeIssue('replacement')],
        nextCursor: 'new-cursor',
      );
    };
    await feed.refresh();
    expect(feed.items.map((row) => row.id), ['first', 'second']);
    expect(repository.pageCalls.last.cursor, 'new-cursor');
    expect(feed.error, isNotNull);
    repository.pageResponse = (_, cursor) async => ExchangeIssuePageData(
      items: [exchangeIssue(cursor == null ? 'replacement' : 'final')],
      nextCursor: cursor == null ? 'new-cursor' : null,
    );
    await feed.retry();
    expect(
      repository.pageCalls[repository.pageCalls.length - 2].cursor,
      isNull,
    );
    expect(feed.items.map((row) => row.id), ['replacement', 'final']);
    expect(feed.error, isNull);
  });

  for (final invalid in ['backend', 'loop']) {
    test('$invalid invalid cursor restarts retry from first page', () async {
      repository.pageResponse = (_, _) async => ExchangeIssuePageData(
        items: [exchangeIssue('first')],
        nextCursor: 'cursor',
      );
      final feed = makeFeed();
      await feed.refresh();
      repository.pageResponse = (_, _) async {
        if (invalid == 'backend') {
          throw const ApiException(
            'invalid',
            code: 'INVALID_EXCHANGE_ISSUES_CURSOR',
            status: 400,
          );
        }
        return ExchangeIssuePageData(
          items: [exchangeIssue('must-not-append')],
          nextCursor: 'cursor',
        );
      };
      await feed.loadMore();
      expect(feed.items.map((row) => row.id), ['first']);
      expect(
        feed.error,
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_EXCHANGE_ISSUES_CURSOR',
        ),
      );
      repository.pageResponse = (_, _) async =>
          const ExchangeIssuePageData(items: []);
      await feed.retry();
      expect(repository.pageCalls.last.cursor, isNull);
      expect(feed.items, isEmpty);
      expect(feed.error, isNull);
    });
  }

  for (final view in ExchangeIssueView.values) {
    test('${view.name} rejects records from the wrong list scope', () async {
      auth.change(exchangeIssueUser(isAdmin: true));
      final wrong = switch (view) {
        ExchangeIssueView.eligible => exchangeIssue('issue'),
        ExchangeIssueView.mine => eligibleExchange('question'),
        ExchangeIssueView.adminOpen => adminExchangeIssue(
          'issue',
          status: 'reviewed',
        ),
        ExchangeIssueView.adminReviewed => adminExchangeIssue('issue'),
      };
      repository.pageResponse = (_, _) async =>
          ExchangeIssuePageData(items: [wrong]);
      final feed = makeFeed(view);
      await feed.refresh();
      expect(feed.items, isEmpty);
      expect(feed.error, isA<ApiException>());
      expect(feed.hasLoaded, isFalse);
    });
  }

  test('disposed feed clears its memory and ignores pending rows', () async {
    final delayed = Completer<ExchangeIssuePageData>();
    repository.pageResponse = (_, _) => delayed.future;
    final feed = ExchangeIssueFeed(
      repository: repository,
      auth: auth,
      view: ExchangeIssueView.mine,
    );
    final pending = feed.refresh();
    await Future<void>.delayed(Duration.zero);
    feed.dispose();
    delayed.complete(
      ExchangeIssuePageData(items: [exchangeIssue('late-private')]),
    );
    await pending;
    auth.change(exchangeIssueUser(id: 'another'));
    expect(feed.items, isEmpty);
    expect(feed.nextCursor, isNull);
    expect(feed.accessDenied, isTrue);
    expect(repository.pageCalls, hasLength(1));
  });
}
