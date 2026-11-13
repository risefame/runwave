-- Runwave: сценарии захвата дугой от границы своей территории (0006).
--
-- Запуск: обычный проект Supabase → SQL Editor → New query → вставить файл
-- целиком → Run. Заглушка supabase/tests/00_auth_stub.sql здесь не нужна:
-- в Supabase уже есть auth.users и auth.uid(), а id игрока берётся из
-- request.jwt.claims — ровно так его читает auth.uid().
--
-- Файл не использует psql-команд (\set, \echo) и работает в SQL Editor.
-- Всё выполняется в одной транзакции и заканчивается rollback: данные
-- тестового проекта не меняются. Если сценарий упал, транзакция прервана и
-- тоже не фиксируется — на всякий случай выполни в новом запросе rollback.
--
-- Проверяется:
--   1. дуга с касанием границы засчитывается так же, как на клиенте;
--   2. дуга без касания границы (конец дальше boundary_touch_m) не засчитывается;
--   3. дуга вокруг угла территории: из двух сторон границы выбрана нужная;
--   4. дуга через чужую защищённую территорию: защищённое не отнимается;
--   5. повтор забега идемпотентен и второй раз ничего не начисляет.

begin;
set search_path = public, extensions;

-- ——— Помощники ———

create or replace function public.t6_assert(p_ok boolean, p_message text)
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

create or replace function public.t6_as(p_user uuid)
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

-- Точка в метрах от центра P = (37.60, 55.75) — широта Москвы.
create or replace function public.t6_point(p_x double precision, p_y double precision)
returns geometry
language sql
immutable
as $$
  select st_setsrid(
    st_makepoint(37.60 + p_x / 62600.0, 55.75 + p_y / 111132.0),
    4326
  );
$$;

create or replace function public.t6_square(
  p_x0 double precision,
  p_y0 double precision,
  p_x1 double precision,
  p_y1 double precision
)
returns geometry
language sql
immutable
as $$
  select st_setsrid(
    st_makeenvelope(
      st_x(public.t6_point(p_x0, p_y0)),
      st_y(public.t6_point(p_x0, p_y0)),
      st_x(public.t6_point(p_x1, p_y1)),
      st_y(public.t6_point(p_x1, p_y1)),
      4326
    ),
    4326
  );
$$;

-- Вершина контура из геометрии: [lon, lat].
create or replace function public.t6_rc(p_geom geometry)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_array(st_x(p_geom), st_y(p_geom));
$$;

-- Точки трека вдоль пути. Скорость и шаг «плавают», чтобы трек не попадал
-- под проверку идеально ровных интервалов.
create or replace function public.t6_track_points(
  p_path geometry,
  p_step double precision,
  p_start_t bigint,
  p_speed double precision default 3.3
)
returns jsonb
language sql
as $$
  with d as (
    select greatest(st_length(p_path::geography), 1) as len
  ),
  raw as (
    select
      i,
      st_lineinterpolatepoint(p_path, least(i * p_step / d.len, 1)) as g
    from generate_series(0, ceil(d.len / p_step)::integer) as i, d
  )
  select jsonb_agg(
    jsonb_build_object(
      'lon', st_x(g),
      'lat', st_y(g),
      't', p_start_t
        + (i * p_step / p_speed * 1000)::bigint
        + (i % 3) * 211
        + (i % 5) * 97,
      'accuracy', 5
    )
    order by i
  )
  from raw;
$$;

-- Контур в том виде, в каком его отправляет клиент: точки дуги плюс вершины
-- границы, которыми клиент замкнул захват.
create or replace function public.t6_ring(p_points jsonb, p_boundary jsonb default '[]'::jsonb)
returns jsonb
language sql
immutable
as $$
  select p_points || p_boundary;
$$;

create temp table t6_runs (
  name text primary key,
  payload jsonb not null
);

create temp table t6_before (
  name text primary key,
  area numeric not null
);

-- ——— Фикстура ———

do $$
declare
  v_a uuid := 'a0000006-0006-4006-8006-000000000001';
  v_b uuid := 'b0000006-0006-4006-8006-000000000002';
begin
  begin
    insert into auth.users (
      id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data
    )
    values
      (
        v_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'anna-arc@example.com', now(), '{"display_name":"Аня"}'
      ),
      (
        v_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'boris-arc@example.com', now(), '{"display_name":"Боря"}'
      )
    on conflict (id) do nothing;
  exception
    when others then
      raise exception
        'Не удалось создать тестовых пользователей в auth.users (%): создай двух пользователей в Authentication → Users и подставь их id в supabase/tests/0006_arc_test.sql',
        sqlerrm;
  end;

  insert into public.profiles (user_id)
  values (v_a), (v_b)
  on conflict (user_id) do nothing;
end
$$;

select public.t6_assert(
  (select count(*) from auth.users
   where id in (
     'a0000006-0006-4006-8006-000000000001',
     'b0000006-0006-4006-8006-000000000002'
   )) = 2,
  '0006: тестовые игроки есть в auth.users'
);

create temp table t6_ctx as
select
  'a0000006-0006-4006-8006-000000000001'::uuid as user_a,
  'b0000006-0006-4006-8006-000000000002'::uuid as user_b,
  public.ensure_active_season() as season;

-- Территория Ани — MultiPolygon из двух кусков: 42,4 × 42,4 м у центра
-- и отдельный кусок в 37 м восточнее.
insert into public.territories (
  owner_id, season_id, geom, area_m2, captured_at, protected_until
)
select
  c.user_a,
  c.season,
  g.geom,
  st_area(g.geom::geography),
  now() - interval '2 days',
  now() - interval '1 day'
from t6_ctx c
cross join lateral (
  select st_multi(st_union(
    public.t6_square(-21.2, -21.2, 21.2, 21.2),
    public.t6_square(58.8, -21.2, 101.2, 21.2)
  )) as geom
) g;

-- Территория Бори в 200 м восточнее: 80 × 42,4 м.
insert into public.territories (
  owner_id, season_id, geom, area_m2, captured_at, protected_until
)
select
  c.user_b,
  c.season,
  g.geom,
  st_area(g.geom::geography),
  now() - interval '2 days',
  now() - interval '1 day'
from t6_ctx c
cross join lateral (
  select st_multi(public.t6_square(180, -21.2, 260, 21.2)) as geom
) g;

select public.t6_assert(
  (select count(*) from public.territories
   where owner_id = (select user_a from t6_ctx)
     and archived_at is null) = 1,
  '0006: фикстура создала по территории на игрока'
);

-- ——— 1. Дуга с касанием границы ———

-- Выход из северной стороны, 40 м наружу, 30 м вдоль, возврат на границу:
-- клиент засчитывает такой захват (findBoundaryClosure + captureTerritory).
select public.t6_as((select user_a from t6_ctx));

create temp table t6_s1 as
select public.t6_track_points(
  st_makeline(array[
    public.t6_point(0, 21.2),
    public.t6_point(0, 61.2),
    public.t6_point(30, 61.2),
    public.t6_point(30, 21.2)
  ]),
  5,
  (extract(epoch from now()) - 3600)::bigint * 1000,
  3.3
) as points;

create temp table t6_s1_ring as
select public.t6_ring(
  s.points,
  jsonb_build_array(
    public.t6_rc(public.t6_point(22, 21.2)),
    public.t6_rc(public.t6_point(10, 21.2)),
    public.t6_rc(public.t6_point(0, 21.2))
  )
) as ring
from t6_s1 s;

insert into t6_before (name, area)
select 'a', coalesce(sum(t.area_m2), 0)
from public.territories t
where t.owner_id = (select user_a from t6_ctx)
  and t.archived_at is null;

insert into t6_runs (name, payload)
select
  'arc',
  public.submit_run_v2(
    s.points,
    jsonb_build_array(r.ring),
    'c0000006-0006-4006-8006-000000000001'::uuid
  )
from t6_s1 s, t6_s1_ring r;

select public.t6_assert(
  (select payload ->> 'status' from t6_runs where name = 'arc') = 'accepted',
  '1. дуга с касанием границы: забег принят'
);
select public.t6_assert(
  (select (payload ->> 'ignored_rings')::integer from t6_runs where name = 'arc') = 0,
  '1. дуга с касанием границы: контур не попал в отброшенные'
);
select public.t6_assert(
  (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc')
    between 1100 and 1300,
  '1. дуга с касанием границы: площадь как на клиенте (30 × 40 м ≈ 1200 м²)'
);
select public.t6_assert(
  abs(
    (select area from t6_before where name = 'a')
    + (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc')
    - (select coalesce(sum(t.area_m2), 0)
       from public.territories t
       where t.owner_id = (select user_a from t6_ctx)
         and t.archived_at is null)
  ) < 2,
  '1. дуга: территория выросла ровно на засчитанную площадь'
);
select public.t6_assert(
  (select count(*) from public.territories t
   where t.owner_id = (select user_a from t6_ctx)
     and t.archived_at is null) = 1,
  '1. дуга: новая земля влилась в существующую территорию'
);
select public.t6_assert(
  (select (payload ->> 'points_awarded')::integer from t6_runs where name = 'arc')
    between 1200 and 1600,
  '1. дуга: очки начислены за новую площадь и дистанцию'
);
select public.t6_assert(
  (select count(*) from public.capture_history ch
   where ch.run_id = ((select payload ->> 'run_id' from t6_runs where name = 'arc')::uuid)
     and ch.action = 'claim') = 1,
  '1. дуга: в истории захватов запись claim'
);

-- ——— 5. Повтор забега ———

insert into t6_runs (name, payload)
select
  'arc_repeat',
  public.submit_run_v2(
    s.points,
    jsonb_build_array(r.ring),
    'c0000006-0006-4006-8006-000000000001'::uuid
  )
from t6_s1 s, t6_s1_ring r;

select public.t6_assert(
  (select payload ->> 'run_id' from t6_runs where name = 'arc_repeat')
    = (select payload ->> 'run_id' from t6_runs where name = 'arc'),
  '5. повтор забега: вернулся прежний run_id'
);
select public.t6_assert(
  (select (payload ->> 'idempotent')::boolean from t6_runs where name = 'arc_repeat') is true,
  '5. повтор забега: результат помечен idempotent'
);
select public.t6_assert(
  (select count(*) from public.runs r
   where r.user_id = (select user_a from t6_ctx)
     and r.client_run_id = 'c0000006-0006-4006-8006-000000000001') = 1,
  '5. повтор забега: второй строки в runs нет'
);
select public.t6_assert(
  (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_repeat')
    = (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc'),
  '5. повтор забега: площадь не пересчитана'
);
select public.t6_assert(
  abs(
    (select area from t6_before where name = 'a')
    + (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc')
    - (select coalesce(sum(t.area_m2), 0)
       from public.territories t
       where t.owner_id = (select user_a from t6_ctx)
         and t.archived_at is null)
  ) < 2,
  '5. повтор забега: территория не выросла второй раз'
);

-- ——— 2. Дуга без касания границы ———

-- Выход из южной стороны, 40 м наружу, 30 м вдоль, но конец дуги остаётся
-- в 40 м от границы: дуга не замыкается, захват не засчитывается.
create temp table t6_s2 as
select public.t6_track_points(
  st_makeline(array[
    public.t6_point(0, -21.2),
    public.t6_point(0, -61.2),
    public.t6_point(30, -61.2)
  ]),
  5,
  (extract(epoch from now()) - 3500)::bigint * 1000,
  3.3
) as points;

create temp table t6_s2_ring as
select public.t6_ring(
  s.points,
  jsonb_build_array(public.t6_rc(public.t6_point(15, -21.2)))
) as ring
from t6_s2 s;

insert into t6_before (name, area)
select 'a2', coalesce(sum(t.area_m2), 0)
from public.territories t
where t.owner_id = (select user_a from t6_ctx)
  and t.archived_at is null;

insert into t6_runs (name, payload)
select
  'arc_far',
  public.submit_run_v2(
    s.points,
    jsonb_build_array(r.ring),
    'c0000006-0006-4006-8006-000000000002'::uuid
  )
from t6_s2 s, t6_s2_ring r;

select public.t6_assert(
  (select payload ->> 'status' from t6_runs where name = 'arc_far') = 'accepted',
  '2. дуга без касания: забег не отклонён, просто нет захвата'
);
select public.t6_assert(
  (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_far') = 0,
  '2. дуга без касания: площадь не начислена'
);
select public.t6_assert(
  (select (payload ->> 'ignored_rings')::integer from t6_runs where name = 'arc_far') = 1,
  '2. дуга без касания: контур отброшен'
);
select public.t6_assert(
  (select (r.details -> 'ring_issues') ->> 'ring_boundary_arc'
   from public.runs r
   where r.id = ((select payload ->> 'run_id' from t6_runs where name = 'arc_far')::uuid)) = '1',
  '2. дуга без касания: причина в runs.details — ring_boundary_arc'
);
select public.t6_assert(
  (select coalesce(sum(t.area_m2), 0)
   from public.territories t
   where t.owner_id = (select user_a from t6_ctx)
     and t.archived_at is null)
    = (select area from t6_before where name = 'a2'),
  '2. дуга без касания: территория не изменилась'
);

-- ——— 3. Дуга вокруг угла ———

-- Выход из южной стороны, обход юго-восточного угла и возврат в сам угол:
-- из двух путей по границе сервер должен выбрать южную сторону (21,2 м),
-- а не обход всей территории.
create temp table t6_s3 as
select public.t6_track_points(
  st_makeline(array[
    public.t6_point(0, -21.2),
    public.t6_point(0, -51.2),
    public.t6_point(50, -51.2),
    public.t6_point(50, -21.2),
    public.t6_point(21.2, -21.2)
  ]),
  5,
  (extract(epoch from now()) - 3400)::bigint * 1000,
  3.3
) as points;

create temp table t6_s3_ring as
select public.t6_ring(
  s.points,
  jsonb_build_array(
    public.t6_rc(public.t6_point(15, -21.2)),
    public.t6_rc(public.t6_point(8, -21.2)),
    public.t6_rc(public.t6_point(0, -21.2))
  )
) as ring
from t6_s3 s;

insert into t6_before (name, area)
select 'a3', coalesce(sum(t.area_m2), 0)
from public.territories t
where t.owner_id = (select user_a from t6_ctx)
  and t.archived_at is null;

insert into t6_runs (name, payload)
select
  'arc_corner',
  public.submit_run_v2(
    s.points,
    jsonb_build_array(r.ring),
    'c0000006-0006-4006-8006-000000000003'::uuid
  )
from t6_s3 s, t6_s3_ring r;

select public.t6_assert(
  (select payload ->> 'status' from t6_runs where name = 'arc_corner') = 'accepted',
  '3. дуга вокруг угла: забег принят'
);
select public.t6_assert(
  (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_corner')
    between 1350 and 1650,
  '3. дуга вокруг угла: выбрана короткая сторона границы (≈ 1500 м²)'
);
select public.t6_assert(
  abs(
    (select area from t6_before where name = 'a3')
    + (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_corner')
    - (select coalesce(sum(t.area_m2), 0)
       from public.territories t
       where t.owner_id = (select user_a from t6_ctx)
         and t.archived_at is null)
  ) < 2,
  '3. дуга вокруг угла: территория выросла ровно на засчитанную площадь'
);

-- ——— 4. Дуга через чужую защищённую территорию ———

-- У Ани рядом с территорией Бори защищённый участок 15 × 20 м. Дуга Бори
-- проходит через него: участок не отнимается и очков за него нет.
insert into public.territories (
  owner_id, season_id, geom, area_m2, captured_at, protected_until
)
select
  c.user_a,
  c.season,
  g.geom,
  st_area(g.geom::geography),
  now() - interval '1 hour',
  now() + interval '12 hours'
from t6_ctx c
cross join lateral (
  select st_multi(public.t6_square(225, 25, 240, 45)) as geom
) g;

select public.t6_as((select user_b from t6_ctx));

create temp table t6_s4 as
select public.t6_track_points(
  st_makeline(array[
    public.t6_point(200, 21.2),
    public.t6_point(200, 61.2),
    public.t6_point(240, 61.2),
    public.t6_point(240, 21.2)
  ]),
  5,
  (extract(epoch from now()) - 3300)::bigint * 1000,
  3.3
) as points;

create temp table t6_s4_ring as
select public.t6_ring(
  s.points,
  jsonb_build_array(
    public.t6_rc(public.t6_point(232, 21.2)),
    public.t6_rc(public.t6_point(210, 21.2)),
    public.t6_rc(public.t6_point(200, 21.2))
  )
) as ring
from t6_s4 s;

insert into t6_before (name, area)
select 'b', coalesce(sum(t.area_m2), 0)
from public.territories t
where t.owner_id = (select user_b from t6_ctx)
  and t.archived_at is null;

insert into t6_before (name, area)
select 'protected', coalesce(sum(t.area_m2), 0)
from public.territories t
where t.owner_id = (select user_a from t6_ctx)
  and t.archived_at is null
  and t.protected_until > now();

insert into t6_runs (name, payload)
select
  'arc_protected',
  public.submit_run_v2(
    s.points,
    jsonb_build_array(r.ring),
    'c0000006-0006-4006-8006-000000000004'::uuid
  )
from t6_s4 s, t6_s4_ring r;

select public.t6_assert(
  (select payload ->> 'status' from t6_runs where name = 'arc_protected') = 'accepted',
  '4. защищённая территория: забег принят'
);
select public.t6_assert(
  (select (payload ->> 'stolen_area_m2')::numeric from t6_runs where name = 'arc_protected') = 0,
  '4. защищённая территория: ничего не отнято'
);
select public.t6_assert(
  (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_protected')
    between 1150 and 1450,
  '4. защищённая территория: засчитано 1600 − 300 м² чужой защиты'
);
select public.t6_assert(
  abs(
    (select coalesce(sum(t.area_m2), 0)
     from public.territories t
     where t.owner_id = (select user_a from t6_ctx)
       and t.archived_at is null
       and t.protected_until > now())
    - (select area from t6_before where name = 'protected')
  ) < 1,
  '4. защищённая территория: участок Ани не изменился'
);
select public.t6_assert(
  abs(
    (select area from t6_before where name = 'b')
    + (select (payload ->> 'area_m2')::numeric from t6_runs where name = 'arc_protected')
    - (select coalesce(sum(t.area_m2), 0)
       from public.territories t
       where t.owner_id = (select user_b from t6_ctx)
         and t.archived_at is null)
  ) < 2,
  '4. защищённая территория: Боре засчитана только свободная часть'
);
select public.t6_assert(
  (select ch.action
   from public.capture_history ch
   where ch.run_id = ((select payload ->> 'run_id' from t6_runs where name = 'arc_protected')::uuid)) = 'claim',
  '4. защищённая территория: захват записан как claim, а не steal'
);

-- ——— Итог ———

select public.t6_assert(
  (select count(*) from public.runs r
   where r.user_id = (select user_a from t6_ctx)
     and r.status = 'accepted') = 3,
  '0006: у Ани три принятых забега (дуга, дуга без касания, угол)'
);

do $$
begin
  raise notice '=== Все сценарии 0006 прошли ===';
end
$$;

rollback;
