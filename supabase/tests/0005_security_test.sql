\set ON_ERROR_STOP on
\echo '=== Runwave: сценарии защиты забега (0005) ==='

-- Сценарии применяются после 00_auth_stub.sql и миграций 0001–0005.
-- Всё выполняется в одной транзакции и откатывается.

begin;
set search_path = public, extensions;

-- Круг с плавающим шагом по времени: реальный трек не попадает под проверку
-- «идеально ровных интервалов», поэтому тестовый тоже не должен.
create or replace function public.test5_points(
  p_lon double precision,
  p_lat double precision,
  p_radius_m double precision,
  p_start_t bigint,
  p_speed_mps double precision default 4
)
returns jsonb
language sql
as $$
  with ring as (
    select (st_dumppoints(
      st_exteriorring(
        st_buffer(
          st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
          p_radius_m,
          128
        )::geometry
      )
    )).geom as g
  ),
  pts as (
    select
      g,
      lag(g) over () as prev,
      row_number() over () as i
    from ring
  ),
  without_duplicate as (
    select g, prev, i
    from pts
    where i = 1
       or st_distance(prev::geography, g::geography) > 1
  ),
  timed as (
    select
      g,
      i,
      p_start_t + (
        sum(
          case
            when prev is null then 0
            else st_distance(prev::geography, g::geography)
                 / (p_speed_mps * (0.8 + 0.4 * random()))
          end
        ) over (order by i) * 1000
      )::bigint as t
    from without_duplicate
  )
  select jsonb_agg(
    jsonb_build_object(
      'lon', st_x(g),
      'lat', st_y(g),
      't', t,
      'accuracy', 5
    )
    order by i
  )
  from timed;
$$;

-- Контур из тех же точек в порядке трека: [lon, lat].
create or replace function public.test5_ring(p_points jsonb)
returns jsonb
language sql
as $$
  select jsonb_agg(
    jsonb_build_array(
      (point ->> 'lon')::double precision,
      (point ->> 'lat')::double precision
    )
    order by ord
  )
  from jsonb_array_elements(p_points) with ordinality as t(point, ord);
$$;

create temp table test_results (
  name text primary key,
  payload jsonb not null
);

-- ——— Фикстура ———

insert into auth.users (id, email, raw_user_meta_data) values
  ('a1111111-1111-4111-8111-111111111111', 'anna5@example.com', '{"display_name":"Аня"}'),
  ('b1111111-1111-4111-8111-111111111111', 'boris5@example.com', '{"display_name":"Боря"}');

select public.test_assert(
  (select count(*) from public.profiles) = 2,
  '0005: фикстура создала два профиля'
);

-- Час назад: забег проходит окно отправки и не выглядит пришедшим из будущего.
create temp table test_clock as
select (extract(epoch from now()) * 1000)::bigint - 3600000 as base;

create temp table test_track as
select public.test5_points(37.60, 55.75, 100, c.base, 4) as points
from test_clock c;

-- ——— 1. Дубль забега: идемпотентность ———

select public.test_as('a1111111-1111-4111-8111-111111111111');

insert into test_results (name, payload)
select 'first', public.submit_run_v2(
  t.points,
  jsonb_build_array(public.test5_ring(t.points)),
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid
)
from test_track t;

insert into test_results (name, payload)
select 'duplicate', public.submit_run_v2(
  t.points,
  jsonb_build_array(public.test5_ring(t.points)),
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid
)
from test_track t;

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'first') = 'accepted',
  'дубль: первый забег принят'
);
select public.test_assert(
  (select payload ->> 'run_id' from test_results where name = 'duplicate')
    = (select payload ->> 'run_id' from test_results where name = 'first'),
  'дубль: повторная отправка вернула прежний run_id'
);
select public.test_assert(
  (select (payload ->> 'idempotent')::boolean from test_results where name = 'duplicate') is true,
  'дубль: повтор помечен idempotent'
);
select public.test_assert(
  (select count(*) from public.runs
   where user_id = 'a1111111-1111-4111-8111-111111111111') = 1,
  'дубль: второй забег не создан'
);
select public.test_assert(
  (select points from public.season_scores
   where user_id = 'a1111111-1111-4111-8111-111111111111')
    = (select (payload ->> 'points_awarded')::integer from test_results where name = 'first'),
  'дубль: очки начислены один раз'
);
select public.test_assert(
  (select count(*) from public.territories
   where owner_id = 'a1111111-1111-4111-8111-111111111111' and archived_at is null) = 1,
  'дубль: территория создана один раз'
);

-- ——— 2. Фальшивый контур ———

insert into test_results (name, payload)
select 'fake_ring', public.submit_run_v2(
  t.points,
  jsonb_build_array(jsonb_build_array(
    jsonb_build_array(37.70, 55.70),
    jsonb_build_array(37.72, 55.70),
    jsonb_build_array(37.72, 55.72),
    jsonb_build_array(37.70, 55.70)
  )),
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd'::uuid
)
from test_track t;

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'fake_ring') = 'rejected',
  'контур: чужой контур не засчитан'
);
select public.test_assert(
  (select payload ->> 'reason' from test_results where name = 'fake_ring') = 'ring_off_track',
  'контур: причина — вершины не из трека'
);
select public.test_assert(
  (select (payload ->> 'points_awarded')::integer from test_results where name = 'fake_ring') = 0,
  'контур: очков за фальшивый контур нет'
);
select public.test_assert(
  (select status from public.runs
   where id = ((select payload ->> 'run_id' from test_results where name = 'fake_ring')::uuid)) = 'rejected',
  'контур: забег сохранён со статусом rejected'
);
select public.test_assert(
  (select reason_code from public.runs
   where id = ((select payload ->> 'run_id' from test_results where name = 'fake_ring')::uuid)) = 'ring_off_track',
  'контур: в runs.reason_code записана причина'
);
select public.test_assert(
  (select count(*) from public.territories
   where owner_id = 'a1111111-1111-4111-8111-111111111111' and archived_at is null) = 1,
  'контур: новая территория не появилась'
);

insert into test_results (name, payload)
select 'fake_ring_again', public.submit_run_v2(
  t.points,
  jsonb_build_array(jsonb_build_array(
    jsonb_build_array(37.70, 55.70),
    jsonb_build_array(37.72, 55.70),
    jsonb_build_array(37.72, 55.72),
    jsonb_build_array(37.70, 55.70)
  )),
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd'::uuid
)
from test_track t;

select public.test_assert(
  (select payload ->> 'run_id' from test_results where name = 'fake_ring_again')
    = (select payload ->> 'run_id' from test_results where name = 'fake_ring'),
  'контур: повтор отклонённого забега вернул тот же отказ'
);

-- ——— 3. Слишком большая площадь ———

-- Квадрат 100 × 100 м (10 000 м²) при треке длиной 100 м физически невозможен:
-- максимум для 100 м — 100² / (4π) ≈ 796 м².
select public.test_assert(
  public.claim_plausible(
    st_setsrid(st_makeenvelope(37.60, 55.75, 37.6012, 55.7509, 4326), 4326),
    100
  ) = false,
  'площадь: квадрат больше, чем позволяет дистанция, отклонён'
);
select public.test_assert(
  public.claim_plausible(
    st_multi(
      st_buffer(
        st_setsrid(st_makepoint(37.60, 55.75), 4326)::geography,
        15
      )::geometry
    ),
    100
  ) = true,
  'площадь: круг в пределах дистанции принят'
);

-- ——— 4. Чужие треки недоступны ———

select public.test_as('b1111111-1111-4111-8111-111111111111');
set local role authenticated;

select public.test_assert(
  (select count(*) from public.runs) = 0,
  'RLS: чужие забеги не видны'
);
select public.test_assert(
  (select count(*) from public.runs
   where user_id = 'a1111111-1111-4111-8111-111111111111') = 0,
  'RLS: чужие raw_points и track не читаются'
);

reset role;

select public.test_as('a1111111-1111-4111-8111-111111111111');
set local role authenticated;

select public.test_assert(
  (select count(*) from public.runs) = 2,
  'RLS: свои забеги видны (принятый и отклонённый)'
);

reset role;

-- ——— 5. Старая сигнатура продолжает работать ———

select public.test_as('b1111111-1111-4111-8111-111111111111');

insert into test_results (name, payload)
select 'legacy', public.submit_run(t.points)
from test_track t;

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'legacy') = 'accepted',
  'совместимость: submit_run(p_points) без ключа идемпотентности принят'
);
select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'legacy') = 0,
  'совместимость: защищённую территорию Ани забрать нельзя'
);

\echo '=== Все сценарии 0005 прошли ==='
rollback;
