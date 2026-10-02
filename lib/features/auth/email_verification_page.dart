import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_flow_widgets.dart';
import 'auth_repository.dart';

class EmailVerificationPage extends ConsumerStatefulWidget {
  const EmailVerificationPage({super.key});
  @override
  ConsumerState<EmailVerificationPage> createState() =>
      _EmailVerificationPageState();
}

class _EmailVerificationPageState extends ConsumerState<EmailVerificationPage> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  late final AuthRepository _auth;
  String? _owner;
  String? _notice;
  String? _demoToken;
  bool _error = false;
  bool _busy = false;
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
      _token.clear();
      _notice = null;
      _demoToken = null;
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _auth.removeListener(_sessionChanged);
    _token.dispose();
    super.dispose();
  }

  Future<void> _request({bool confirm = false}) async {
    if (_busy || _owner == null) return;
    if (confirm && !_form.currentState!.validate()) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _notice = null;
      _demoToken = null;
    });
    try {
      if (confirm) {
        await _auth.confirmEmailVerification(
          accountTokenFromInput(_token.text),
        );
        if (!mounted || generation != _generation) return;
        _token.clear();
        setState(() {
          _error = false;
          _notice = '이메일 인증을 완료했습니다.';
        });
      } else {
        final result = await _auth.requestEmailVerification();
        if (!mounted || generation != _generation) return;
        setState(() {
          _error = false;
          _demoToken = result.demonstrationToken;
          _notice = result.isDemonstration
              ? '미리보기: 실제 이메일은 전송되지 않습니다. 테스트 코드를 사용해주세요.'
              : '요청을 접수했습니다. 이메일을 받을 수 있는 주소라면 인증 안내가 발송 대기 중입니다. 받은편지함과 스팸함을 확인해주세요.';
        });
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
      title: '이메일 인증',
      children: [
        if (_notice != null) ...[
          AccountNotice(_notice!, isError: _error),
          const SizedBox(height: 20),
        ],
        AccountSection(
          children: [
            Icon(
              user?.isEmailVerified == true
                  ? Icons.verified_outlined
                  : Icons.mark_email_unread_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              user?.isEmailVerified == true ? '인증된 이메일' : '이메일을 인증해주세요',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(user?.email ?? '로그인이 필요합니다.'),
            if (user != null && !user.isEmailVerified) ...[
              const SizedBox(height: 16),
              const Text('인증 안내를 요청한 뒤 이메일에 있는 코드 또는 링크를 입력해주세요.'),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _busy ? null : () => _request(),
                child: const Text('인증 메일 받기'),
              ),
              if (_demoToken != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _token.text = _demoToken!),
                  child: const Text('미리보기 코드 사용'),
                ),
              const SizedBox(height: 20),
              Form(
                key: _form,
                child: TextFormField(
                  controller: _token,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '인증 코드 또는 링크'),
                  validator: (value) =>
                      (value?.trim().isEmpty ?? true) ? '인증 코드를 입력해주세요.' : null,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : () => _request(confirm: true),
                child: const Text('이메일 인증 완료하기'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(semanticsLabel: '이메일 인증 처리 중'),
            ],
          ],
        ),
      ],
    );
  }
}
