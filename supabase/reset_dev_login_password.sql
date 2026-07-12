create extension if not exists pgcrypto;

update auth.users
set
  encrypted_password = crypt('daisy-dev-1234', gen_salt('bf')),
  updated_at = now()
where lower(email) in (
  'questioner1@example.com',
  'questioner2@example.com',
  'questioner3@example.com',
  'answerer1@example.com',
  'answerer2@example.com'
)
returning email;
