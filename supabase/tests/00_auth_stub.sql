-- Только для локальных SQL-тестов на обычном PostgreSQL.
-- В Supabase схема auth и функция auth.uid() уже существуют, этот файл
-- применять не нужно. Здесь создаётся их минимальная замена.

set search_path = public, extensions;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key,
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

do $do$
begin
  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'uid' and p.pronargs = 0
  ) then
    execute $fn$
      create function auth.uid() returns uuid
      language sql
      stable
      as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
        )::uuid
      $body$
    $fn$;
  end if;
end
$do$;

do $do$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end
$do$;

grant usage on schema public, auth to authenticated, anon, service_role;

-- ——— Помощники тестов ———

create or replace function public.test_as(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', p_user)::text,
    true
  );
end;
$$;

create or replace function public.test_assert(p_ok boolean, p_message text)
returns void
language plpgsql
as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAIL: %', p_message;
  end if;
  raise notice 'OK: %', p_message;
end;
$$;
