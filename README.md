# 지역 기반 1:1 유료 Q&A 컨시어지 MVP

Flutter, Riverpod, GoRouter, Supabase로 만든 모바일 우선 MVP입니다.

## 포함된 범위

- 이메일 회원가입/로그인
- 사용자 프로필 자동 생성 및 mock 포인트 지급
- 질문 등록, 목록, 상세
- Supabase Storage 기반 질문 이미지 업로드
- 답변자 신청 및 관리자 승인/거절
- 승인 답변자만 가능한 1:1 질문 수락
- 근거 URL 필수 답변 제출
- 질문자 답변 채택 및 mock 포인트 보상
- 포인트 거래 내역

## Supabase 설정

1. Supabase 프로젝트를 생성합니다.
2. `supabase/migrations/202607040001_initial_mvp.sql`을 SQL Editor에서 실행합니다.
3. 실제 스페인 지도 좌표를 쓰려면 `supabase/migrations/202607070001_spain_map_coordinates.sql`도 이어서 실행합니다.
4. 첫 관리자 계정으로 로그인한 뒤 SQL Editor에서 해당 사용자를 관리자로 지정합니다.

```sql
update public.users
set is_admin = true
where email = 'admin@example.com';
```

## 실행

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

## 검증

```bash
flutter analyze
flutter test
```
# DaisyOne-Malaga
