import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/services/api_service.dart';
import '../auth/auth_repository.dart';
import 'exchange_issue_draft.dart';
import 'exchange_issue_feed.dart';
import 'exchange_issue_repository.dart';

class ExchangeIssuesPage extends ConsumerStatefulWidget {
  const ExchangeIssuesPage({super.key, this.admin = false, this.questionId});
  final bool admin;
  final String? questionId;

  @override
  ConsumerState<ExchangeIssuesPage> createState() => _ExchangeIssuesPageState();
}

class _ExchangeIssuesPageState extends ConsumerState<ExchangeIssuesPage> {
  late final AuthRepository _auth;
  late ExchangeIssueScope _scope;
  late ExchangeIssueView _view;
  final _drafts = <String, ExchangeIssueDraft>{};
  final _retiredDrafts = <ExchangeIssueDraft>[];
  final _feeds = <ExchangeIssueFeed>{};
  bool _dialogOpen = false;
  DialogRoute<void>? _dialogRoute;
  NavigatorState? _dialogNavigator;
  bool _finding = false;
  bool _selectedMissing = false;
  Object? _selectedError;
  bool _denying = false;
  String? _selectedQuestionId;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _scope = exchangeIssueScope(_auth);
    _selectedQuestionId = widget.questionId;
    _view = widget.admin
        ? ExchangeIssueView.adminOpen
        : ExchangeIssueView.eligible;
    _auth.addListener(_accountChanged);
    if (!widget.admin && widget.questionId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _findSelected());
    }
  }

  void _clearDrafts() {
    _revision++;
    for (final draft in _drafts.values) {
      draft.revoke();
      _retiredDrafts.add(draft);
    }
    _drafts.clear();
    _finding = false;
  }

  void _accountChanged() {
    final scope = exchangeIssueScope(_auth);
    if (!mounted || scope == _scope) return;
    _scope = scope;
    _selectedQuestionId = null;
    _clearDrafts();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ExchangeIssuesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questionId == widget.questionId &&
        oldWidget.admin == widget.admin) {
      return;
    }
    final revision = ++_revision;
    _finding = false;
    _selectedQuestionId = widget.questionId;
    _selectedMissing = false;
    _selectedError = null;
    if (oldWidget.admin != widget.admin) {
      _view = widget.admin
          ? ExchangeIssueView.adminOpen
          : ExchangeIssueView.eligible;
    }
    final route = _dialogRoute;
    final navigator = _dialogNavigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      // Route updates run during build; clearing an open editor notifies its
      // sibling dialog. Do that after this frame, before opening the new one.
      _clearDrafts();
      if (route != null && route.isActive && navigator?.mounted == true) {
        navigator!.removeRoute(route);
        if (identical(_dialogRoute, route)) {
          _dialogOpen = false;
          _dialogRoute = null;
          _dialogNavigator = null;
        }
      }
      if (!widget.admin && _selectedQuestionId != null) {
        unawaited(_findSelected());
      }
    });
  }

  void _accessChanged() {
    if (_feeds.any((feed) => feed.accessDenied)) _denyAccess();
  }

  void _denyAccess() {
    if (_denying) return;
    _denying = true;
    _selectedQuestionId = null;
    _clearDrafts();
    for (final feed in _feeds) {
      feed.denyAccess();
    }
    _denying = false;
  }

  @override
  void dispose() {
    _auth.removeListener(_accountChanged);
    for (final feed in _feeds) {
      feed.removeListener(_accessChanged);
    }
    for (final draft in {..._drafts.values, ..._retiredDrafts}) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _findSelected() async {
    if (!mounted || _finding || _selectedQuestionId == null) return;
    final feed = ref.read(
      exchangeIssueFeedProvider(ExchangeIssueView.eligible),
    );
    if (!feed.canRead) return;
    final revision = _revision;
    final questionId = _selectedQuestionId!;
    setState(() {
      _finding = true;
      _selectedMissing = false;
      _selectedError = null;
    });
    try {
      final selected = await ref
          .read(exchangeIssueRepositoryProvider)
          .fetchEligible(questionId);
      if (!mounted || revision != _revision || !feed.canRead) return;
      if (selected.questionId != questionId) {
        throw const ApiException('진행 참조를 확인하지 못했습니다.');
      }
      setState(() => _finding = false);
      await _open(selected);
    } catch (error) {
      if (!mounted || revision != _revision) return;
      if (exchangeIssueAccessFailure(error)) {
        _denyAccess();
      } else {
        setState(() {
          _finding = false;
          _selectedMissing = true;
          _selectedError = error;
        });
      }
    }
  }

  Future<void> _refreshFeeds() async {
    await Future.wait(_feeds.map((feed) => feed.refresh()));
  }

  Future<void> _open(ExchangeIssueEntry entry) async {
    if (_dialogOpen || !mounted) return;
    final feed = ref.read(exchangeIssueFeedProvider(_view));
    if (!feed.canRead) return;
    final key = entry is EligibleExchange
        ? 'question:${entry.id}'
        : 'issue:${entry.id}';
    final draft = _drafts.putIfAbsent(
      key,
      () => ExchangeIssueDraft(
        repository: ref.read(exchangeIssueRepositoryProvider),
        auth: _auth,
        questionId: entry.questionId,
        issueId: entry is EligibleExchange ? entry.ownIssueId : entry.id,
        adminRecord: entry is AdminExchangeIssueRecord ? entry : null,
        onAccessDenied: _denyAccess,
        onMissing: () {
          for (final page in _feeds) {
            page.removeQuestion(entry.questionId);
          }
          unawaited(_refreshFeeds());
        },
      ),
    );
    if (!draft.busy) {
      if (entry is EligibleExchange && entry.ownIssueId != null) {
        draft.issueId = entry.ownIssueId;
      } else if (entry is AdminExchangeIssueRecord) {
        draft.adminRecord = entry;
      }
    }
    if (!draft.isAdmin && draft.issueId != null) unawaited(draft.load());
    _dialogOpen = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      builder: (_) =>
          _ExchangeIssueDialog(draft: draft, onChanged: _refreshFeeds),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    );
    _dialogRoute = route;
    _dialogNavigator = navigator;
    try {
      await navigator.push(route);
    } finally {
      if (identical(_dialogRoute, route)) {
        _dialogOpen = false;
        _dialogRoute = null;
        _dialogNavigator = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final views = widget.admin
        ? [ExchangeIssueView.adminOpen, ExchangeIssueView.adminReviewed]
        : [ExchangeIssueView.eligible, ExchangeIssueView.mine];
    // Both private tabs stay in the same in-memory page scope.
    final currentFeeds = {
      for (final view in views) ref.watch(exchangeIssueFeedProvider(view)),
    };
    for (final old in _feeds.difference(currentFeeds)) {
      old.removeListener(_accessChanged);
    }
    for (final added in currentFeeds.difference(_feeds)) {
      added.addListener(_accessChanged);
    }
    _feeds
      ..clear()
      ..addAll(currentFeeds);
    final feed = ref.watch(exchangeIssueFeedProvider(_view));
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(widget.admin ? '진행 문제 검토' : '진행 문제 기록'),
          leading: BackButton(
            onPressed: () {
              final router = GoRouter.of(context);
              if (router.canPop()) {
                router.pop();
              } else {
                router.go(widget.admin ? '/admin' : '/account');
              }
            },
          ),
          actions: [
            IconButton(
              tooltip: '기록 새로고침',
              onPressed: feed.isLoading || !feed.canRead ? null : _refreshFeeds,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: RefreshIndicator(
                onRefresh: _refreshFeeds,
                child: ListView(
                  key: ValueKey('exchange-issues-${_view.name}'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(exchangeIssueDisclosure),
                    const SizedBox(height: 8),
                    Text(
                      widget.admin
                          ? '검토 표시는 내부 확인 기록입니다. 작성자에게 메모나 검토자 정보가 공개되지 않습니다.'
                          : '참여자마다 질문 하나에 기록 하나를 남길 수 있습니다. 내 기록은 상대 참여자에게 공개되지 않습니다.',
                    ),
                    const SizedBox(height: 16),
                    for (final view in views)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton(
                          key: ValueKey('exchange-issues-view-${view.name}'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            backgroundColor: view == _view
                                ? Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer
                                : null,
                          ),
                          onPressed: feed.canRead
                              ? () => setState(() => _view = view)
                              : null,
                          child: Text(view.label, textAlign: TextAlign.center),
                        ),
                      ),
                    if (_selectedQuestionId != null && !widget.admin) ...[
                      Text('선택한 질문 참조 · $_selectedQuestionId'),
                      if (_finding) const Text('선택한 진행을 찾고 있어요'),
                      if (_selectedMissing) ...[
                        Text(
                          _selectedError is ApiException &&
                                  (_selectedError as ApiException).status == 404
                              ? '선택한 진행을 더 이상 열 수 없습니다. 이미 남긴 내용은 내 기록에서 확인할 수 있습니다.'
                              : '선택한 진행을 확인하지 못했습니다. 연결을 확인한 뒤 다시 시도해주세요.',
                        ),
                        OutlinedButton(
                          onPressed: feed.canRead ? _findSelected : null,
                          child: const Text('선택한 진행 다시 찾기'),
                        ),
                      ],
                      const SizedBox(height: 16),
                    ],
                    Text(
                      _view == ExchangeIssueView.mine
                          ? '최근 기록부터 표시합니다'
                          : '오래된 순으로 표시합니다',
                    ),
                    const SizedBox(height: 16),
                    if (feed.accessDenied)
                      const Text(
                        '이 기록에 접근할 수 없습니다. 로그인과 계정 권한을 확인해주세요. 이용 제한 중에는 새 기록을 남길 수 없습니다.',
                      ),
                    if (feed.error != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(exchangeIssueErrorText(feed.error!)),
                              if (feed.items.isNotEmpty)
                                const Text('표시된 목록은 이전에 불러온 내용입니다.'),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: feed.isLoading ? null : feed.retry,
                                child: const Text('다시 시도'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (feed.isLoading)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: CircularProgressIndicator(
                            semanticsLabel: '기록 불러오는 중',
                          ),
                        ),
                      ),
                    if (feed.hasLoaded &&
                        feed.items.isEmpty &&
                        !feed.isLoading &&
                        feed.error == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(switch (_view) {
                          ExchangeIssueView.eligible =>
                            '기록할 수 있는 진행 중 질문이 없습니다.',
                          ExchangeIssueView.mine => '아직 남긴 기록이 없습니다.',
                          _ => '이 상태의 기록이 없습니다.',
                        }, textAlign: TextAlign.center),
                      ),
                    for (final entry in feed.items)
                      _IssueEntryCard(entry: entry, onOpen: () => _open(entry)),
                    if (feed.nextCursor != null && feed.error == null)
                      OutlinedButton(
                        key: const ValueKey('exchange-issues-more'),
                        onPressed: feed.isLoading ? null : feed.loadMore,
                        child: const Text('더 보기'),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _date(DateTime date) =>
    DateFormat('yyyy.MM.dd HH:mm').format(date.toLocal());

class _IssueEntryCard extends StatelessWidget {
  const _IssueEntryCard({required this.entry, required this.onOpen});
  final ExchangeIssueEntry entry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('exchange-issue-${entry.id}'),
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry case final EligibleExchange row) ...[
            Text(row.status == 'assigned' ? '가이드 답변 대기' : '여행자 검토 대기'),
            const SizedBox(height: 8),
            Text(
              row.title ?? '내용을 표시할 수 없는 질문',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (!row.contentAvailable)
              const Text('질문 내용은 열 수 없어도 진행 문제를 기록할 수 있습니다.'),
            const SizedBox(height: 8),
            Text('질문 참조 · ${row.questionId}'),
            Text('${row.roleLabel}로 참여 · 등록 ${_date(row.createdAt)}'),
            Text('최근 변경 · ${_date(row.updatedAt)}'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onOpen,
              child: Text(row.ownIssueId == null ? '문제 기록하기' : '내 기록 열기'),
            ),
          ] else if (entry case final ExchangeIssueRecord row) ...[
            Text(row.statusLabel),
            const SizedBox(height: 8),
            Text(
              row.reason.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('질문 참조 · ${row.questionId}'),
            Text('${row.roleLabel} · 기록 ${_date(row.createdAt)}'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onOpen, child: const Text('기록 자세히 보기')),
          ],
        ],
      ),
    ),
  );
}

class _ExchangeIssueDialog extends StatefulWidget {
  const _ExchangeIssueDialog({required this.draft, required this.onChanged});
  final ExchangeIssueDraft draft;
  final Future<void> Function() onChanged;
  @override
  State<_ExchangeIssueDialog> createState() => _ExchangeIssueDialogState();
}

class _ExchangeIssueDialogState extends State<_ExchangeIssueDialog> {
  late final TextEditingController _text;
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.draft.text);
    widget.draft.addListener(_changed);
  }

  void _changed() {
    if (widget.draft.denied ||
        widget.draft.reviewed ||
        widget.draft.record != null) {
      _text.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.draft.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final draft = widget.draft;
    await draft.submit();
    if (draft.issueId != null || draft.reviewed || draft.error != null) {
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final record = draft.adminRecord ?? draft.record;
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        draft.missing
            ? '기록을 찾을 수 없음'
            : draft.denied
            ? '접근할 수 없음'
            : draft.isAdmin
            ? '진행 문제 검토'
            : '내 진행 문제 기록',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (draft.missing)
              const Text('기록이 삭제되었거나 더 이상 열 수 없습니다. 목록을 새로고침해 확인해주세요.')
            else if (draft.denied)
              const Text('로그인이나 계정 권한이 변경되어 기록과 입력 내용을 지웠습니다.')
            else ...[
              Text('질문 참조 · ${draft.questionId}'),
              const SizedBox(height: 12),
              if (record != null) ...[
                Text(draft.reviewed ? '검토 표시됨' : record.statusLabel),
                Text(record.reason.label),
                Text('${record.roleLabel} · 기록 ${_date(record.createdAt)}'),
                if (record.reviewedAt != null)
                  Text('검토 표시 · ${_date(record.reviewedAt!)}'),
                const SizedBox(height: 12),
                Text(record.details ?? '추가 내용 없음'),
                if (record case final AdminExchangeIssueRecord admin) ...[
                  const SizedBox(height: 12),
                  Text('작성자 참조 · ${admin.reporterId}'),
                  Text('상대 참여자 참조 · ${admin.otherParticipantId}'),
                  if (admin.reviewedBy != null)
                    Text('검토자 참조 · ${admin.reviewedBy}'),
                  if (admin.reviewNote != null)
                    Text('내부 메모 · ${admin.reviewNote}'),
                ],
              ],
              if (draft.issueId == null ||
                  (draft.isAdmin &&
                      record?.status == 'open' &&
                      !draft.reviewed)) ...[
                const SizedBox(height: 12),
                if (!draft.isAdmin) ...[
                  const Text('어떤 문제인가요?'),
                  const SizedBox(height: 8),
                  for (final reason in ExchangeIssueReason.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: OutlinedButton(
                        key: ValueKey('exchange-issue-reason-${reason.code}'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: draft.reason == reason
                              ? Theme.of(context).colorScheme.secondaryContainer
                              : null,
                        ),
                        onPressed: draft.canEdit
                            ? () => setState(() => draft.reason = reason)
                            : null,
                        child: Text(reason.label, textAlign: TextAlign.center),
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('exchange-issue-details'),
                  controller: _text,
                  enabled: draft.canEdit,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 1000,
                  onChanged: (value) => draft.text = value,
                  decoration: InputDecoration(
                    labelText: draft.isAdmin ? '내부 검토 메모 (선택)' : '추가 내용 (선택)',
                    helperText: draft.isAdmin
                        ? '작성자에게 공개되지 않습니다'
                        : '개인 연락처나 민감한 정보는 적지 마세요',
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(exchangeIssueDisclosure),
                if (draft.frozen) ...[
                  const SizedBox(height: 12),
                  const Text('요청한 내용을 유지하고 있습니다. 결과가 불확실하면 같은 내용으로 다시 확인합니다.'),
                ],
              ],
              if (draft.reviewed)
                const Text('검토 표시를 남겼습니다. 질문 상태와 가상 포인트는 변경되지 않았습니다.'),
              if (draft.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(semanticsLabel: '기록 요청 중'),
                ),
              if (draft.error != null) ...[
                const SizedBox(height: 12),
                Text(exchangeIssueErrorText(draft.error!)),
              ],
              if (draft.issueId != null &&
                  !draft.isAdmin &&
                  draft.record == null &&
                  !draft.busy) ...[
                const SizedBox(height: 12),
                const Text('기록 참조가 있습니다. 정확한 내 기록을 다시 불러옵니다.'),
                OutlinedButton(
                  onPressed: draft.load,
                  child: const Text('내 기록 다시 불러오기'),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
        if (draft.canSubmit || draft.busy && draft.issueId == null)
          FilledButton(
            key: const ValueKey('exchange-issue-submit'),
            onPressed: draft.canSubmit ? _submit : null,
            child: Text(
              draft.frozen
                  ? '같은 내용으로 다시 시도'
                  : draft.isAdmin
                  ? '검토 표시'
                  : '기록 남기기',
            ),
          ),
      ],
    );
  }
}
