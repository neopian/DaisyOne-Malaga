with temp_answerers(id, email, name) as (
  values
    (
      '00000000-0000-0000-0000-000000000201'::uuid,
      'answerer1@example.com',
      '답변자1'
    ),
    (
      '00000000-0000-0000-0000-000000000202'::uuid,
      'answerer2@example.com',
      '답변자2'
    )
),
existing_answerers as (
  select users.id, users.email, temp_answerers.name
  from public.users
  join temp_answerers
    on lower(users.email) = lower(temp_answerers.email)
    or users.id = temp_answerers.id
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
from existing_answerers
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
  select users.id
  from public.users
  where lower(users.email) in (
    'answerer1@example.com',
    'answerer2@example.com'
  )
);

with temp_answerers(email) as (
  values
    ('answerer1@example.com'),
    ('answerer2@example.com')
),
existing_answerers as (
  select users.id
  from public.users
  join temp_answerers
    on lower(users.email) = lower(temp_answerers.email)
)
insert into public.helper_regions (helper_user_id, country, city, region_name)
select id, 'Spain', city, null
from existing_answerers
cross join (values ('Málaga'), ('Malaga')) as helper_cities(city);

select
  users.email,
  helper_applications.status,
  count(helper_regions.id) as region_count
from public.users
left join public.helper_applications
  on helper_applications.user_id = users.id
left join public.helper_regions
  on helper_regions.helper_user_id = users.id
where lower(users.email) in (
  'answerer1@example.com',
  'answerer2@example.com'
)
group by users.email, helper_applications.status
order by users.email;
