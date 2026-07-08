create table if not exists public.question_comments (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  body text not null check (
    char_length(trim(body)) between 1 and 600
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists question_comments_question_created_idx
  on public.question_comments (question_id, created_at);

drop trigger if exists question_comments_touch_updated_at
on public.question_comments;

create trigger question_comments_touch_updated_at
before update on public.question_comments
for each row execute function public.touch_updated_at();

alter table public.question_comments enable row level security;

create policy "question comments select participants" on public.question_comments
for select to authenticated using (
  public.can_read_question(question_id, auth.uid())
);

create policy "question comments insert participants" on public.question_comments
for insert to authenticated with check (
  user_id = auth.uid()
  and public.can_read_question(question_id, auth.uid())
);

create policy "question comments update own" on public.question_comments
for update to authenticated using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy "question comments delete own" on public.question_comments
for delete to authenticated using (user_id = auth.uid());
