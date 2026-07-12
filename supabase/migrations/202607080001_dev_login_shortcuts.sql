create extension if not exists pgcrypto;

-- Local development only. The debug app uses this same shortcut password.
select set_config(
  'app.dev_login_password',
  'daisy-dev-1234',
  false
);

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'identities'
      and column_name = 'provider_id'
  ) then
    with dev_accounts(id, email) as (
      values
        ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
        ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
        ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
        ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
        ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
    )
    delete from auth.identities
    using dev_accounts
    where auth.identities.user_id = dev_accounts.id
       or (
         auth.identities.provider = 'email'
         and (
           auth.identities.provider_id = dev_accounts.id::text
           or auth.identities.identity_data ->> 'email' = dev_accounts.email
         )
       );
  else
    with dev_accounts(id, email) as (
      values
        ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
        ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
        ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
        ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
        ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
    )
    delete from auth.identities
    using dev_accounts
    where auth.identities.user_id = dev_accounts.id
       or (
         auth.identities.provider = 'email'
         and (
           auth.identities.id = dev_accounts.id::text
           or auth.identities.identity_data ->> 'email' = dev_accounts.email
         )
       );
  end if;
end $$;

with dev_accounts(id, email) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
    ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
    ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
)
delete from auth.users
using dev_accounts
where auth.users.id = dev_accounts.id
   or lower(auth.users.email) = lower(dev_accounts.email);

with dev_accounts(id, email, name) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com', '질문자1'),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com', '질문자2'),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com', '질문자3'),
    ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com', '답변자1'),
    ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com', '답변자2')
)
insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  confirmation_token,
  recovery_sent_at,
  recovery_token,
  email_change,
  email_change_token_current,
  email_change_token_new,
  phone_change,
  phone_change_token,
  reauthentication_token,
  last_sign_in_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  id,
  'authenticated',
  'authenticated',
  email,
  crypt(current_setting('app.dev_login_password', true), gen_salt('bf')),
  now(),
  '',
  now(),
  '',
  '',
  '',
  '',
  '',
  '',
  '',
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('name', name),
  now(),
  now()
from dev_accounts;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'identities'
      and column_name = 'provider_id'
  ) then
    with dev_accounts(id, email) as (
      values
        ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
        ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
        ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
        ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
        ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
    )
    insert into auth.identities (
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    )
    select
      id::text,
      id,
      jsonb_build_object(
        'sub', id::text,
        'email', email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      now(),
      now(),
      now()
    from dev_accounts;
  else
    with dev_accounts(id, email) as (
      values
        ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
        ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
        ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
        ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
        ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
    )
    insert into auth.identities (
      id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    )
    select
      id::text,
      id,
      jsonb_build_object(
        'sub', id::text,
        'email', email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      now(),
      now(),
      now()
    from dev_accounts;
  end if;
end $$;

with dev_accounts(id, email, name) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com', '질문자1'),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com', '질문자2'),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com', '질문자3'),
    ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com', '답변자1'),
    ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com', '답변자2')
)
insert into public.users (
  id,
  email,
  name,
  current_country,
  current_city,
  point_balance
)
select id, email, name, 'Spain', 'Málaga', 5000
from dev_accounts
on conflict (id) do update
set
  email = excluded.email,
  name = excluded.name,
  current_country = excluded.current_country,
  current_city = excluded.current_city,
  point_balance = greatest(public.users.point_balance, excluded.point_balance);

with helper_accounts(id, name) as (
  values
    ('00000000-0000-0000-0000-000000000201'::uuid, '답변자1'),
    ('00000000-0000-0000-0000-000000000202'::uuid, '답변자2')
)
insert into public.helper_applications (
  user_id,
  status,
  languages,
  introduction,
  experience_description,
  reviewed_at,
  reject_reason
)
select
  id,
  'approved',
  array['ko', 'es', 'en'],
  name || ' 테스트 계정입니다.',
  'Málaga 지역 테스트 답변자입니다.',
  now(),
  null
from helper_accounts
on conflict (user_id) do update
set
  status = 'approved',
  languages = excluded.languages,
  introduction = excluded.introduction,
  experience_description = excluded.experience_description,
  reviewed_at = now(),
  reject_reason = null;

delete from public.helper_regions
where helper_user_id in (
  '00000000-0000-0000-0000-000000000201'::uuid,
  '00000000-0000-0000-0000-000000000202'::uuid
);

with helper_accounts(id) as (
  values
    ('00000000-0000-0000-0000-000000000201'::uuid),
    ('00000000-0000-0000-0000-000000000202'::uuid)
)
insert into public.helper_regions (helper_user_id, country, city, region_name)
select id, 'Spain', city, null
from helper_accounts
cross join (values ('Málaga'), ('Malaga')) as helper_cities(city);

with dev_accounts(id) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid),
    ('00000000-0000-0000-0000-000000000102'::uuid),
    ('00000000-0000-0000-0000-000000000103'::uuid),
    ('00000000-0000-0000-0000-000000000201'::uuid),
    ('00000000-0000-0000-0000-000000000202'::uuid)
)
insert into public.point_transactions (user_id, type, amount)
select id, 'charge_mock', 5000
from dev_accounts
where not exists (
  select 1
  from public.point_transactions
  where point_transactions.user_id = dev_accounts.id
    and point_transactions.type = 'charge_mock'
    and point_transactions.amount = 5000
);

with dev_accounts(id, email) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'questioner1@example.com'),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'questioner2@example.com'),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'questioner3@example.com'),
    ('00000000-0000-0000-0000-000000000201'::uuid, 'answerer1@example.com'),
    ('00000000-0000-0000-0000-000000000202'::uuid, 'answerer2@example.com')
)
select
  dev_accounts.email,
  auth.users.id is not null as auth_user_created,
  exists (
    select 1
    from auth.identities
    where auth.identities.user_id = dev_accounts.id
      and auth.identities.provider = 'email'
  ) as email_identity_created,
  public.users.id is not null as public_profile_created
from dev_accounts
left join auth.users on auth.users.id = dev_accounts.id
left join public.users on public.users.id = dev_accounts.id
order by dev_accounts.email;

with dev_accounts(id) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid),
    ('00000000-0000-0000-0000-000000000102'::uuid),
    ('00000000-0000-0000-0000-000000000103'::uuid),
    ('00000000-0000-0000-0000-000000000201'::uuid),
    ('00000000-0000-0000-0000-000000000202'::uuid)
)
select
  auth.users.email,
  auth.users.confirmation_token is not null as confirmation_token_not_null,
  auth.users.recovery_token is not null as recovery_token_not_null,
  auth.users.email_change is not null as email_change_not_null,
  auth.users.email_change_token_current is not null as email_change_token_current_not_null,
  auth.users.email_change_token_new is not null as email_change_token_new_not_null,
  auth.users.phone_change is not null as phone_change_not_null,
  auth.users.phone_change_token is not null as phone_change_token_not_null,
  auth.users.reauthentication_token is not null as reauthentication_token_not_null
from auth.users
join dev_accounts on dev_accounts.id = auth.users.id
order by auth.users.email;
