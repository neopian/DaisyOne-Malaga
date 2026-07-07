alter table public.questions
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

create index if not exists questions_spain_coordinates_idx
on public.questions (latitude, longitude)
where country = 'Spain' and latitude is not null and longitude is not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'questions_spain_country_check'
      and conrelid = 'public.questions'::regclass
  ) then
    alter table public.questions
      add constraint questions_spain_country_check
      check (country = 'Spain') not valid;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'questions_spain_coordinates_check'
      and conrelid = 'public.questions'::regclass
  ) then
    alter table public.questions
      add constraint questions_spain_coordinates_check
      check (
        latitude is null
        or longitude is null
        or (
          latitude between 27.5 and 44.4
          and longitude between -18.4 and 4.5
        )
      ) not valid;
  end if;
end $$;

drop function if exists public.create_question_with_hold(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  integer,
  timestamptz
);

create or replace function public.create_question_with_hold(
  p_country text,
  p_city text,
  p_region_name text,
  p_category text,
  p_urgency text,
  p_title text,
  p_body text,
  p_reward_points integer,
  p_latitude double precision,
  p_longitude double precision,
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

  if trim(coalesce(p_country, '')) <> 'Spain' then
    raise exception 'Only Spain questions are supported';
  end if;

  if p_latitude is null or p_longitude is null then
    raise exception 'Spain map coordinates are required';
  end if;

  if p_latitude < 27.5
     or p_latitude > 44.4
     or p_longitude < -18.4
     or p_longitude > 4.5 then
    raise exception 'Question location must be in Spain';
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
    latitude,
    longitude,
    expires_at
  )
  values (
    requester,
    'Spain',
    trim(p_city),
    nullif(trim(coalesce(p_region_name, '')), ''),
    p_category,
    p_urgency,
    trim(p_title),
    trim(p_body),
    p_reward_points,
    p_latitude,
    p_longitude,
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

notify pgrst, 'reload schema';
