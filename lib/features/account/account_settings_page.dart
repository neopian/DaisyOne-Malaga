import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../auth/account_flow_widgets.dart';
import '../auth/auth_repository.dart';
import 'account_repository.dart';
import 'export_file.dart';

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});
  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  late final AuthRepository _auth;
  String? _owner;
  String? _export;
  String? _notice;
  bool _error = false;
  bool _busy = false;
  bool _includeImages = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _owner = _auth.currentUser?.id;
    _auth.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (_owner != _auth.currentUser?.id) {
      _owner = _auth.currentUser?.id;
      _generation++;
      _export = null;
      _includeImages = true;
      _notice = null;
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _auth.removeListener(_sessionChanged);
    _export = null;
    super.dispose();
  }

  Future<void> _prepareExport() async {
    if (_busy || _owner == null) return;
    final generation = _generation;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _ReauthenticationDialog(),
    );
    if (!mounted || password == null || generation != _generation) return;
    setState(() {
      _busy = true;
      _notice = null;
      _export = null;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .exportData(password, includeImages: _includeImages);
      if (!mounted || generation != _generation) return;
      setState(() {
        _export = const JsonEncoder.withIndent('  ').convert(result);
        _error = false;
        _notice = '내 데이터가 준비되었습니다. 아래에서 JSON 파일을 저장하거나 공유할 수 있습니다.';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = true;
          _notice = accountErrorText(error);
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    if (_busy || _export == null) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    final generation = _generation;
    final json = _export!;
    setState(() => _busy = true);
    try {
      final result = await shareAccountExport(json, origin);
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = false;
        _notice = result.status == ShareResultStatus.dismissed
            ? '저장 / 공유를 취소했습니다. 데이터는 이 화면에서 다시 열 수 있습니다.'
            : '저장 / 공유 창을 열었습니다. 선택한 위치에서 파일을 확인해주세요.';
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = true;
          _notice = '파일 저장 / 공유를 완료하지 못했습니다. 다시 시도하거나 JSON을 복사해주세요.';
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy || _owner == null) return;
    final generation = _generation;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _ReauthenticationDialog(deleting: true),
    );
    if (!mounted || password == null || generation != _generation) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _notice = null;
      _export = null;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .deleteAccount(password: password, confirmation: 'DELETE');
      // Deletion signs out and may dispose this page before cleanup finishes.
      final message = result.cleanupPending
          ? '계정을 삭제했습니다. 사진 접근은 차단되었으며 서버의 비공개 파일 정리가 진행 중입니다.'
          : '계정과 서버의 계정 데이터를 삭제했습니다.';
      if (messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 12),
            content: Text(
              result.localCleanupComplete
                  ? message
                  : '$message 이 기기의 임시 저장을 지우지 못했습니다. 기기의 앱 저장 공간을 확인해주세요.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = true;
          _notice = accountErrorText(error);
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    return AccountFlowScaffold(
      title: '계정 및 개인정보',
      backFallback: user?.isSuspended == true ? '/profile' : '/home',
      children: [
        if (user?.isSuspended == true) ...[
          const AccountNotice(
            '현재 계정의 질문 / 답변 이용이 제한되어 있습니다. 계정 확인, 데이터 내보내기와 삭제는 계속 이용할 수 있습니다. 문의 방법은 개인정보 · 이용 안내에서 확인해주세요.',
            isError: true,
          ),
          const SizedBox(height: 20),
        ],
        if (_notice != null) ...[
          AccountNotice(_notice!, isError: _error),
          const SizedBox(height: 20),
        ],
        if (_busy) ...[
          const LinearProgressIndicator(semanticsLabel: '계정 요청 처리 중'),
          const SizedBox(height: 16),
        ],
        AccountSection(
          children: [
            Text('내 계정', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(user?.name ?? '로그인이 필요합니다.'),
            Text(user?.email ?? ''),
            const SizedBox(height: 12),
            Text(user?.isEmailVerified == true ? '이메일 인증 완료' : '이메일 미인증'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy || user == null
                  ? null
                  : () => context.push('/account/verify'),
              icon: const Icon(Icons.verified_user_outlined),
              label: Text(
                user?.isEmailVerified == true ? '이메일 인증 확인' : '이메일 인증하기',
              ),
            ),
            TextButton(
              onPressed: _busy || user == null || user.isSuspended
                  ? null
                  : () => context.push('/account/exchange-issues'),
              child: const Text('진행 문제 기록'),
            ),
            TextButton(
              onPressed: _busy || user == null
                  ? null
                  : () => context.push('/account/blocked'),
              child: const Text('차단한 사용자'),
            ),
            TextButton(
              onPressed: _busy ? null : () => context.push('/about'),
              child: const Text('개인정보 · 이용 안내'),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 12),
              const Text(
                '이 브라우저에서 로그인 정보 기억하기를 선택하면 로그인 토큰이 브라우저 저장 공간에 보관됩니다. 공용 기기에서는 사용 후 로그아웃해주세요.',
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        AccountSection(
          children: [
            Text('내 데이터 내보내기', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '현재 비밀번호를 확인한 뒤 서버에 보관된 내 계정 데이터를 JSON으로 준비합니다. 파일에 개인 정보가 포함될 수 있으니 저장 / 공유 위치를 직접 확인해주세요.',
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _includeImages,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _includeImages = value ?? true;
                      _export = null;
                      _notice = null;
                    }),
              title: const Text('저장된 사진 포함'),
              subtitle: const Text('해제하면 사진 정보만 포함하며 사진 파일 내용은 제외합니다.'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            OutlinedButton.icon(
              onPressed: _busy || user == null ? null : _prepareExport,
              icon: const Icon(Icons.download_outlined),
              label: const Text('비밀번호 확인 후 준비'),
            ),
            if (_export != null) ...[
              const SizedBox(height: 12),
              Builder(
                builder: (buttonContext) => FilledButton.icon(
                  onPressed: _busy ? null : () => _share(buttonContext),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('JSON 저장 / 공유'),
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: _export!));
                        if (mounted) {
                          setState(() {
                            _error = false;
                            _notice = 'JSON을 클립보드에 복사했습니다.';
                          });
                        }
                      },
                child: const Text('JSON 복사'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _export = null;
                        _notice = null;
                      }),
                child: const Text('준비한 데이터 닫기'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        AccountSection(
          children: [
            Text('계정 삭제', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('계정을 삭제하면 다시 복구할 수 없습니다. 필요한 데이터는 먼저 내보내기 해주세요.'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy || user == null ? null : _delete,
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('계정 삭제 안내'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReauthenticationDialog extends StatefulWidget {
  const _ReauthenticationDialog({this.deleting = false});
  final bool deleting;
  @override
  State<_ReauthenticationDialog> createState() =>
      _ReauthenticationDialogState();
}

class _ReauthenticationDialogState extends State<_ReauthenticationDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.deleting ? '계정을 영구 삭제할까요?' : '현재 비밀번호 확인'),
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.deleting) ...[
            const Text(
              '프로필, 내가 만든 질문과 연결된 대화 / 사진, 내 답변과 댓글, 가이드 신청 / 지역, 포인트 기록, 모든 로그인이 삭제됩니다.\n\n진행 중인 가이드 배정은 취소되며 남아 있는 질문자의 보류 포인트가 환불됩니다. 이미 지급된 보상은 되돌리지 않습니다.\n\n받은 이메일이나 외부에 저장한 사본, 백업은 즉시 삭제되지 않을 수 있습니다. 이 작업은 취소하거나 복구할 수 없습니다.',
            ),
            const SizedBox(height: 20),
          ] else ...[
            const Text('내 계정 데이터에 접근하기 위해 비밀번호를 한 번 더 확인합니다.'),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: !widget.deleting,
            decoration: const InputDecoration(labelText: '현재 비밀번호'),
            validator: (value) =>
                (value?.isEmpty ?? true) ? '현재 비밀번호를 입력해주세요.' : null,
          ),
          if (widget.deleting) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmation,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'DELETE 입력'),
              validator: (value) =>
                  value != 'DELETE' ? '삭제하려면 DELETE를 정확히 입력해주세요.' : null,
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        style: widget.deleting
            ? FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              )
            : null,
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _password.text);
          }
        },
        child: Text(widget.deleting ? '영구 삭제' : '내 데이터 준비'),
      ),
    ],
  );
}
