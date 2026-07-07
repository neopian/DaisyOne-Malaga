create extension if not exists pgcrypto;

create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null,
  avatar_url text,
  current_country text,
  current_city text,
  point_balance integer not null default 0 check (point_balance >= 0),
  questioner_rating_avg numeric(3, 2) not null default 0,
  helper_rating_avg numeric(3, 2) not null default 0,
  questioner_rating_count integer not null default 0,
  helper_rating_count integer not null default 0,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.helper_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  languages text[] not null default '{}',
  introduction text not null,
  experience_description text not null,
  applied_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.users(id),
  reject_reason text
);

create table if not exists public.helper_regions (
  id uuid primary key default gen_random_uuid(),
  helper_user_id uuid not null references public.users(id) on delete cascade,
  country text not null,
  city text not null,
  region_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  assigned_helper_user_id uuid references public.users(id),
  country text not null,
  city text not null,
  region_name text,
  category text not null
    check (category in ('교통', '번역', '생활', '쇼핑', '식당', '긴급도움', '기타')),
  urgency text not null
    check (urgency in ('보통', '빠름', '매우 급함')),
  title text not null,
  body text not null,
  reward_points integer not null check (reward_points > 0),
  status text not null default 'open'
    check (status in ('open', 'assigned', 'answered', 'accepted', 'disputed', 'cancelled', 'expired', 'reported')),
  accepted_answer_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz
);

create table if not exists public.question_images (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  image_url text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.answers (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  helper_user_id uuid not null references public.users(id) on delete cascade,
  body text not null,
  evidence_summary text not null,
  verification_method text not null,
  status text not null default 'submitted'
    check (status in ('submitted', 'accepted', 'disputed', 'rejected', 'reported')),
  is_rewarded boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.questions
  add constraint questions_accepted_answer_id_fkey
  foreign key (accepted_answer_id) references public.answers(id);

create table if not exists public.answer_evidence_links (
  id uuid primary key default gen_random_uuid(),
  answer_id uuid not null references public.answers(id) on delete cascade,
  url text not null,
  title text,
  description text,
  source_type text not null default 'other'
    check (source_type in ('official', 'map', 'transport', 'store', 'local_info', 'other')),
  created_at timestamptz not null default now()
);

create table if not exists public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  question_id uuid references public.questions(id) on delete set null,
  answer_id uuid references public.answers(id) on delete set null,
  type text not null
    check (type in ('charge_mock', 'hold', 'reward', 'refund', 'penalty', 'admin_adjustment')),
  amount integer not null,
  created_at timestamptz not null default now()
);

create index if not exists helper_regions_location_idx
  on public.helper_regions (country, city, region_name);
create index if not exists questions_status_location_idx
  on public.questions (status, country, city, region_name);
create index if not exists answers_question_idx on public.answers (question_id);
create index if not exists point_transactions_user_idx
  on public.point_transactions (user_id, created_at desc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists questions_touch_updated_at on public.questions;
create trigger questions_touch_updated_at
before update on public.questions
for each row execute function public.touch_updated_at();

drop trigger if exists answers_touch_updated_at on public.answers;
create trigger answers_touch_updated_at
before update on public.answers
for each row execute function public.touch_updated_at();

create or replace function public.is_admin(user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select is_admin from public.users where id = user_id), false);
$$;

create or replace function public.is_approved_helper(user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.helper_applications
    where helper_applications.user_id = user_id
      and status = 'approved'
  );
$$;

create or replace function public.helper_matches_question(helper_id uuid, question_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.questions q
    join public.helper_regions r
      on r.helper_user_id = helper_id
     and lower(r.country) = lower(q.country)
     and lower(r.city) = lower(q.city)
     and (
       coalesce(q.region_name, '') = ''
       or coalesce(r.region_name, '') = ''
       or lower(r.region_name) = lower(q.region_name)
     )
    where q.id = question_id
  );
$$;

create or replace function public.can_read_question(question_id uuid, reader_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.questions q
    where q.id = question_id
      and (
        q.status = 'open'
        or q.user_id = reader_id
        or q.assigned_helper_user_id = reader_id
        or public.is_admin(reader_id)
      )
  );
$$;

create or replace function public.create_question_with_hold(
  p_country text,
  p_city text,
  p_region_name text,
  p_category text,
  p_urgency text,
  p_title text,
  p_body text,
  p_reward_points integer,
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  requester uuid := auth.uid();
  new_question_id uuid;
begin
  if requester is null then
    raise exception 'Authentication required';
  end if;

  if p_reward_points <= 0 then
    raise exception 'Reward points must be positive';
  end if;

  update public.users
     set point_balance = point_balance - p_reward_points
   where id = requester
     and point_balance >= p_reward_points;

  if not found then
    raise exception 'Not enough points';
  end if;

  insert into public.questions (
    user_id,
    country,
    city,
    region_name,
    category,
    urgency,
    title,
    body,
    reward_points,
    expires_at
  )
  values (
    requester,
    trim(p_country),
    trim(p_city),
    nullif(trim(coalesce(p_region_name, '')), ''),
    p_category,
    p_urgency,
    trim(p_title),
    trim(p_body),
    p_reward_points,
    p_expires_at
  )
  returning id into new_question_id;

  insert into public.point_transactions (
    user_id,
    question_id,
    type,
    amount
  )
  values (requester, new_question_id, 'hold', -p_reward_points);

  return new_question_id;
end;
$$;

create or replace function public.accept_question(p_question_id uuid)
returns public.questions
language plpgsql
security definer
set search_path = public
as $$
declare
  helper uuid := auth.uid();
  accepted_question public.questions;
begin
  if helper is null then
    raise exception 'Authentication required';
  end if;

  if not public.is_approved_helper(helper) then
    raise exception 'Only approved helpers can accept questions';
  end if;

  if not public.helper_matches_question(helper, p_question_id) then
    raise exception 'Helper region does not match this question';
  end if;

  update public.questions
     set assigned_helper_user_id = helper,
         status = 'assigned'
   where id = p_question_id
     and status = 'open'
     and assigned_helper_user_id is null
  returning * into accepted_question;

  if accepted_question.id is null then
    raise exception 'Question is no longer open';
  end if;

  return accepted_question;
end;
$$;

create or replace function public.submit_answer_with_evidence(
  p_question_id uuid,
  p_body text,
  p_evidence_summary text,
  p_verification_method text,
  p_links jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  helper uuid := auth.uid();
  new_answer_id uuid;
  link_item jsonb;
begin
  if helper is null then
    raise exception 'Authentication required';
  end if;

  if jsonb_typeof(p_links) <> 'array' or jsonb_array_length(p_links) < 1 then
    raise exception 'At least one evidence URL is required';
  end if;

  if not exists (
    select 1 from public.questions
    where id = p_question_id
      and assigned_helper_user_id = helper
      and status = 'assigned'
  ) then
    raise exception 'Only the assigned helper can answer this question';
  end if;

  insert into public.answers (
    question_id,
    helper_user_id,
    body,
    evidence_summary,
    verification_method
  )
  values (
    p_question_id,
    helper,
    trim(p_body),
    trim(p_evidence_summary),
    trim(p_verification_method)
  )
  returning id into new_answer_id;

  for link_item in select * from jsonb_array_elements(p_links)
  loop
    insert into public.answer_evidence_links (
      answer_id,
      url,
      title,
      description,
      source_type
    )
    values (
      new_answer_id,
      link_item ->> 'url',
      nullif(link_item ->> 'title', ''),
      nullif(link_item ->> 'description', ''),
      coalesce(nullif(link_item ->> 'source_type', ''), 'other')
    );
  end loop;

  update public.questions
     set status = 'answered'
   where id = p_question_id;

  return new_answer_id;
end;
$$;

create or replace function public.accept_answer(p_question_id uuid, p_answer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requester uuid := auth.uid();
  answer_helper uuid;
  reward_amount integer;
begin
  if requester is null then
    raise exception 'Authentication required';
  end if;

  select a.helper_user_id, q.reward_points
    into answer_helper, reward_amount
    from public.answers a
    join public.questions q on q.id = a.question_id
   where q.id = p_question_id
     and a.id = p_answer_id
     and q.user_id = requester
     and q.status = 'answered'
     and a.status = 'submitted'
     and a.is_rewarded = false;

  if answer_helper is null then
    raise exception 'Answer cannot be accepted';
  end if;

  update public.answers
     set status = 'accepted',
         is_rewarded = true
   where id = p_answer_id;

  update public.questions
     set status = 'accepted',
         accepted_answer_id = p_answer_id
   where id = p_question_id;

  update public.users
     set point_balance = point_balance + reward_amount
   where id = answer_helper;

  insert into public.point_transactions (
    user_id,
    question_id,
    answer_id,
    type,
    amount
  )
  values (answer_helper, p_question_id, p_answer_id, 'reward', reward_amount);
end;
$$;

alter table public.users enable row level security;
alter table public.helper_applications enable row level security;
alter table public.helper_regions enable row level security;
alter table public.questions enable row level security;
alter table public.question_images enable row level security;
alter table public.answers enable row level security;
alter table public.answer_evidence_links enable row level security;
alter table public.point_transactions enable row level security;

create policy "users select authenticated" on public.users
for select to authenticated using (true);

create policy "users insert self" on public.users
for insert to authenticated with check (id = auth.uid());

create policy "users update self or admin" on public.users
for update to authenticated using (id = auth.uid() or public.is_admin(auth.uid()))
with check (id = auth.uid() or public.is_admin(auth.uid()));

create policy "helper applications select own or admin" on public.helper_applications
for select to authenticated using (user_id = auth.uid() or public.is_admin(auth.uid()));

create policy "helper applications insert own" on public.helper_applications
for insert to authenticated with check (user_id = auth.uid());

create policy "helper applications update admin" on public.helper_applications
for update to authenticated using (public.is_admin(auth.uid()))
with check (public.is_admin(auth.uid()));

create policy "helper regions select authenticated" on public.helper_regions
for select to authenticated using (true);

create policy "helper regions insert own" on public.helper_regions
for insert to authenticated with check (helper_user_id = auth.uid());

create policy "helper regions update own or admin" on public.helper_regions
for update to authenticated using (helper_user_id = auth.uid() or public.is_admin(auth.uid()))
with check (helper_user_id = auth.uid() or public.is_admin(auth.uid()));

create policy "helper regions delete own or admin" on public.helper_regions
for delete to authenticated using (helper_user_id = auth.uid() or public.is_admin(auth.uid()));

create policy "questions select visible" on public.questions
for select to authenticated using (
  status = 'open'
  or user_id = auth.uid()
  or assigned_helper_user_id = auth.uid()
  or public.is_admin(auth.uid())
);

create policy "question images select authenticated" on public.question_images
for select to authenticated using (true);

create policy "question images insert question owner" on public.question_images
for insert to authenticated with check (
  exists (
    select 1 from public.questions
    where questions.id = question_id
      and questions.user_id = auth.uid()
  )
);

create policy "answers select participants" on public.answers
for select to authenticated using (
  public.can_read_question(question_id, auth.uid())
);

create policy "evidence links select participants" on public.answer_evidence_links
for select to authenticated using (
  exists (
    select 1 from public.answers
    where answers.id = answer_id
      and public.can_read_question(answers.question_id, auth.uid())
  )
);

create policy "point transactions select own or admin" on public.point_transactions
for select to authenticated using (user_id = auth.uid() or public.is_admin(auth.uid()));

create policy "point transactions insert own mock charge" on public.point_transactions
for insert to authenticated with check (
  user_id = auth.uid()
  and type in ('charge_mock', 'admin_adjustment')
);

create or replace function public.refund_question(
  p_user_id uuid,
  p_question_id uuid,
  p_amount integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) and auth.uid() <> p_user_id then
    raise exception 'Not allowed';
  end if;

  update public.users
     set point_balance = point_balance + p_amount
   where id = p_user_id;

  insert into public.point_transactions (
    user_id,
    question_id,
    type,
    amount
  )
  values (p_user_id, p_question_id, 'refund', p_amount);
end;
$$;

insert into storage.buckets (id, name, public)
values ('question-images', 'question-images', true)
on conflict (id) do nothing;

create policy "question image files read authenticated" on storage.objects
for select to authenticated using (bucket_id = 'question-images');

create policy "question image files upload authenticated" on storage.objects
for insert to authenticated with check (bucket_id = 'question-images');
