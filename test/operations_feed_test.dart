import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_qa_concierge/core/geo/city_catalog.g.dart';
import 'package:local_qa_concierge/core/services/api_service.dart';
import 'package:local_qa_concierge/features/admin/operations_feed.dart';
import 'package:local_qa_concierge/features/admin/operations_repository.dart';

import 'operations_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiClient client;
  late OperationsTestAuth auth;
  late OperationsTestRepository repository;
  setUp(() {
    client = ApiClient(baseUrl: 'https://example.test/api');
    auth = OperationsTestAuth(client);
    repository = OperationsTestRepository(client);
  });
  tearDown(() {
    auth.dispose();
    client.dispose();
  });

  OperationsFeed makeFeed() {
    final feed = OperationsFeed(repository: repository, auth: auth);
    addTearDown(feed.dispose);
    return feed;
  }

  test('no admin or suspended account makes no operations request', () async {
    auth.change(operationsUser(isAdmin: false));
    final feed = makeFeed();
    await feed.refresh();
    expect(repository.calls, isEmpty);
    expect(feed.accessDenied, isTrue);
    auth.change(operationsUser(isSuspended: true));
    await feed.refresh();
    expect(repository.calls, isEmpty);
  });

  test(
    'paging retry keeps scoped rows, hides unknown counts and deduplicates',
    () async {
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('first')],
        nextCursor: 'cursor',
        summary: operationsSummary,
      );
      final feed = makeFeed();
      await feed.refresh();
      final delayed = Completer<OperationsPageData>();
      repository.response = (_, _, _) => delayed.future;
      final first = feed.loadMore();
      final duplicate = feed.loadMore();
      await Future<void>.delayed(Duration.zero);
      expect(identical(first, duplicate), isTrue);
      expect(repository.calls, hasLength(2));
      expect(feed.summary, isNull);
      delayed.completeError(const ApiException('offline'));
      await first;
      expect(feed.items.map((q) => q.id), ['first']);
      expect(feed.summary, isNull);
      expect(feed.nextCursor, 'cursor');
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('first'), operationsQuestion('second')],
        summary: operationsSummary,
      );
      await feed.retry();
      expect(repository.calls.last.cursor, 'cursor');
      expect(feed.items.map((q) => q.id), ['first', 'second']);
      expect(feed.summary!.openCount, 42);
    },
  );

  test(
    'city and status changes clear all state and ignore late replies',
    () async {
      repository.response = (_, _, _) async => OperationsPageData(
        items: [operationsQuestion('first')],
        summary: operationsSummary,
      );
      final feed = makeFeed();
      await feed.refresh();
      final old = Completer<OperationsPageData>();
      repository.response = (_, _, _) => old.future;
      final oldRequest = feed.refresh();
      await Future<void>.delayed(Duration.zero);
      final paris = CityCatalog.findCity('France', 'Paris')!;
      final parisResponse = Completer<OperationsPageData>();
      repository.response = (_, _, _) => parisResponse.future;
      final filtered = feed.selectCity(paris);
      expect(feed.items, isEmpty);
      expect(feed.summary, isNull);
      expect(feed.nextCursor, isNull);
      await Future<void>.delayed(Duration.zero);
      repository.response = (status, _, _) async => OperationsPageData(
        items: [operationsQuestion('assigned', status: status)],
        summary: const OperationsSummary(
          openCount: 6,
          assignedCount: 2,
          answeredCount: 1,
        ),
      );
      await feed.selectStatus(OperationsStatus.assigned);
      old.complete(
        OperationsPageData(
          items: [operationsQuestion('late')],
          summary: operationsSummary,
        ),
      );
      parisResponse.complete(
        OperationsPageData(
          items: [operationsQuestion('late-paris')],
          summary: operationsSummary,
        ),
      );
      await Future.wait([oldRequest, filtered]);
      expect(feed.items.map((q) => q.id), ['assigned']);
      expect(feed.summary!.openCount, 6);
      expect(repository.calls.last.city?.id, paris.id);
      expect(repository.calls.last.cursor, isNull);
    },
  );

  for (final change in ['account', 'role', 'suspended', 'logout']) {
    test(
      '$change clears data synchronously and rejects late privileged response',
      () async {
        repository.response = (_, _, _) async => OperationsPageData(
          items: [operationsQuestion('private')],
          nextCursor: 'cursor',
          summary: operationsSummary,
        );
        final feed = makeFeed();
        await feed.refresh();
        final old = Completer<OperationsPageData>();
        repository.response = (_, _, _) => old.future;
        final pending = feed.loadMore();
        await Future<void>.delayed(Duration.zero);
        repository.response = (_, _, _) async =>
            const OperationsPageData(items: [], summary: operationsSummary);
        auth.change(switch (change) {
          'account' => operationsUser(id: 'another'),
          'role' => operationsUser(isAdmin: false),
          'suspended' => operationsUser(isSuspended: true),
          _ => null,
        });
        expect(feed.items, isEmpty);
        expect(feed.summary, isNull);
        expect(feed.nextCursor, isNull);
        old.complete(
          OperationsPageData(
            items: [operationsQuestion('late-private')],
            summary: operationsSummary,
          ),
        );
        await pending;
        await feed.refresh();
        expect(feed.items, isEmpty);
        if (change != 'account') expect(feed.summary, isNull);
      },
    );
  }

  for (final status in [401, 403, 404]) {
    test(
      'authorization $status immediately discards loaded rows and counts',
      () async {
        repository.response = (_, _, _) async => OperationsPageData(
          items: [operationsQuestion('private')],
          nextCursor: 'cursor',
          summary: operationsSummary,
        );
        final feed = makeFeed();
        await feed.refresh();
        repository.response = (_, _, _) async =>
            throw ApiException('denied', status: status);
        await feed.loadMore();
        expect(feed.items, isEmpty);
        expect(feed.summary, isNull);
        expect(feed.nextCursor, isNull);
        expect(feed.hasLoaded, isFalse);
      },
    );
  }

  test('refresh at loaded depth only commits a complete result', () async {
    repository.response = (_, _, cursor) async => OperationsPageData(
      items: [operationsQuestion(cursor == null ? 'first' : 'second')],
      nextCursor: cursor == null ? 'cursor' : null,
      summary: operationsSummary,
    );
    final feed = makeFeed();
    await feed.refresh();
    await feed.loadMore();
    repository.response = (_, _, cursor) async {
      if (cursor != null) throw const ApiException('offline');
      return OperationsPageData(
        items: [operationsQuestion('replacement')],
        nextCursor: 'cursor',
        summary: operationsSummary,
      );
    };
    await feed.refresh();
    expect(feed.items.map((q) => q.id), ['first', 'second']);
    expect(feed.summary, isNull);
    expect(feed.error, isNotNull);
  });

  test('invalid and looping cursor retry starts from first page', () async {
    repository.response = (_, _, _) async => OperationsPageData(
      items: [operationsQuestion('first')],
      nextCursor: 'cursor',
      summary: operationsSummary,
    );
    final feed = makeFeed();
    await feed.refresh();
    await feed.loadMore();
    expect(feed.error, isA<ApiException>());
    repository.response = (_, _, _) async => throw const ApiException(
      'invalid',
      code: 'INVALID_OPERATIONS_CURSOR',
      status: 400,
    );
    await feed.retry();
    expect(repository.calls.last.cursor, isNull);
    repository.response = (_, _, _) async =>
        const OperationsPageData(items: [], summary: operationsSummary);
    await feed.retry();
    expect(repository.calls.last.cursor, isNull);
    expect(feed.items, isEmpty);
  });

  test('out-of-scope records are rejected and never appended', () async {
    final feed = makeFeed();
    await feed.refresh();
    repository.response = (_, _, _) async => OperationsPageData(
      items: [
        operationsQuestion('wrong-city', country: 'Spain', city: 'Malaga'),
      ],
      summary: operationsSummary,
    );
    await feed.selectCity(CityCatalog.findCity('France', 'Paris'));
    expect(feed.items, isEmpty);
    expect(feed.summary, isNull);
    expect(feed.error, isNotNull);
    repository.response = (_, _, _) async => OperationsPageData(
      items: [operationsQuestion('wrong-status')],
      summary: operationsSummary,
    );
    await feed.selectStatus(OperationsStatus.answered);
    expect(feed.items, isEmpty);
    expect(feed.error, isNotNull);
  });
}
