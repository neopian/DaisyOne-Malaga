import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_config.dart';

/// Accessible before sign-in. Operator policy URLs are explicit build settings;
/// development text never pretends to be a final legal policy or support SLA.
class AppInfoPage extends StatelessWidget {
  const AppInfoPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('링크를 열지 못했습니다. 다시 시도해주세요.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('링크를 열지 못했습니다. 다시 시도해주세요.')),
        );
      }
    }
  }

  Widget _link(BuildContext context, String label, String url) {
    if (url.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('$label: 개발 설정에서 준비 중'),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => _open(context, url),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('개인정보 · 이용 안내'),
      leading: IconButton(
        tooltip: '돌아가기',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => context.canPop() ? context.pop() : context.go('/auth'),
      ),
    ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '여행 중 필요한 정보를 현지 답변으로',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                '여행 질문을 올리고 가이드가 확인한 근거와 함께 답변합니다. 답변 도착 시간이나 내용의 정확성을 보장하지 않습니다. 긴급 상황에서는 이 앱의 답변을 기다리지 말고 현지 긴급 구조기관에 연락하세요.',
              ),
              const SizedBox(height: 20),
              _section(context, '정보와 권한', const [
                Text(
                  '계정에는 이메일과 이름을 사용합니다. 작성한 질문·답변·댓글과 첨부 사진은 화면에 안내된 공개 범위와 참여자 권한에 따라 표시됩니다.',
                ),
                SizedBox(height: 10),
                Text(
                  '위치는 선택 사항입니다. 위치 권한 없이 도시를 직접 선택할 수 있습니다. 질문에 선택한 지도 위치가 포함될 수 있으므로 숙소나 정확한 개인 위치를 공유하기 전 확인하세요.',
                ),
                SizedBox(height: 10),
                Text(
                  '사진은 직접 선택한 경우에만 첨부합니다. 사진 속 얼굴, 연락처, 예약 번호 등 불필요한 개인정보를 올리지 마세요.',
                ),
                SizedBox(height: 10),
                Text(
                  '지도 이미지를 불러올 때 지도 제공자에게 네트워크 요청이 전송됩니다. 외부 근거 링크는 해당 사이트에서 열립니다.',
                ),
              ]),
              const SizedBox(height: 12),
              _section(context, '내 계정과 안전', const [
                Text(
                  '계정 설정에서 이메일 확인, 데이터 내보내기와 계정 삭제를 시작할 수 있습니다. 삭제 전 현재 비밀번호로 본인 여부를 확인합니다.',
                ),
                SizedBox(height: 10),
                Text(
                  '콘텐츠 옆 더 보기에서 신고하거나 작성자를 차단할 수 있습니다. 차단은 계정 설정에서 해제합니다. 개인정보 노출, 스팸, 괴롭힘이나 위협을 게시하지 마세요.',
                ),
                SizedBox(height: 10),
                Text('현재 포인트는 테스트용 가상 값입니다. 결제, 환전, 현금 인출 기능은 없습니다.'),
              ]),
              if (AppConfig.demoMode) ...[
                const SizedBox(height: 12),
                _section(context, '이 브라우저 미리보기', const [
                  Text(
                    '테스트 데이터가 이 브라우저에만 저장됩니다. 다른 사람이나 기기에 동기화되지 않고 실제 이메일을 보내지 않습니다. 실제 개인정보를 입력하지 마세요.',
                  ),
                ]),
              ],
              const SizedBox(height: 20),
              _link(context, '개인정보 처리방침', AppConfig.privacyPolicyUrl),
              _link(context, '이용약관', AppConfig.termsUrl),
              _link(context, '커뮤니티 이용 기준', AppConfig.communityGuidelinesUrl),
              _link(context, '지원 및 문의', AppConfig.supportUrl),
              if (AppConfig.supportEmail.isNotEmpty)
                SelectableText('문의 이메일: ${AppConfig.supportEmail}'),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => showLicensePage(context: context),
                child: const Text('오픈소스 라이선스'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _section(BuildContext context, String title, List<Widget> body) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ...body,
            ],
          ),
        ),
      );
}
