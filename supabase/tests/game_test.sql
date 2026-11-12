\set ON_ERROR_STOP on
\echo '=== Runwave: SQL-сценарии ==='

begin;
set search_path = public, extensions;

-- Замкнутое кольцо вокруг точки. Точки идут по кругу с шагом по времени,
-- рассчитанным из длины сегмента и скорости, чтобы пройти проверку 7 м/с.
create or replace function public.test_ring(
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
          p_radius_m
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
  timed as (
    select
      g,
      i,
      p_start_t + (
        sum(
          case
            when prev is null then 0
            else st_distance(prev::geography, g::geography) / p_speed_mps
          end
        ) over (order by i) * 1000
      )::bigint as t
    from pts
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

create temp table test_results (
  name text primary key,
  payload jsonb not null
);

-- ——— Фикстура ———

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-4111-8111-111111111111', 'alice@example.com', '{"display_name":"Алиса"}'),
  ('22222222-2222-4222-8222-222222222222', 'bob@example.com', '{"display_name":"Боб"}'),
  ('33333333-3333-4333-8333-333333333333', 'carol@example.com', '{"display_name":"Кэрол"}'),
  ('44444444-4444-4444-8444-444444444444', 'dave@example.com', '{"display_name":"Дэйв"}'),
  ('55555555-5555-4555-8555-555555555555', 'eve@example.com', '{"display_name":"Ева"}');

insert into public.cities (id, name, geom) values
  (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'Москва',
    st_multi(st_makeenvelope(37.30, 55.50, 38.00, 56.00, 4326))
  );

insert into public.districts (id, city_id, name, geom) values
  (
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'Тверской',
    st_multi(st_makeenvelope(37.50, 55.70, 37.75, 55.80, 4326))
  );

select public.test_assert(
  (select count(*) from public.profiles) = 5,
  'фикстура: триггер auth.users создал 5 профилей'
);

-- ——— 1. Захват нейтральной земли ———

select public.test_as('11111111-1111-4111-8111-111111111111');
insert into test_results (name, payload)
values ('a_capture', public.submit_run(public.test_ring(37.60, 55.75, 100, 1700000000000, 4)));

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'a_capture') = 'accepted',
  'A: забег принят'
);
select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'a_capture') between 30000 and 33000,
  'A: площадь новой территории ≈ 31 400 м²'
);
select public.test_assert(
  (select (payload ->> 'points_awarded')::integer from test_results where name = 'a_capture') >= 32000,
  'A: очки за площадь и бонус за дистанцию'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '11111111-1111-4111-8111-111111111111' and archived_at is null) = 1,
  'A: территория создана'
);
select public.test_assert(
  (select protected_until > now() + interval '11 hours' from public.territories
   where owner_id = '11111111-1111-4111-8111-111111111111') is true,
  'A: новая территория защищена на 12 часов'
);
select public.test_assert(
  (select protected_until - captured_at from public.territories
   where owner_id = '11111111-1111-4111-8111-111111111111') = interval '12 hours',
  'A: защита ровно 12 часов'
);
select public.test_assert(
  (select ends_at - starts_at from public.seasons where status = 'active') = interval '28 days',
  'сезон длится 4 недели'
);
select public.test_assert(
  (select city_id from public.territories where owner_id = '11111111-1111-4111-8111-111111111111')
    = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'A: город определён по точке старта'
);
select public.test_assert(
  (select district_id from public.territories where owner_id = '11111111-1111-4111-8111-111111111111')
    = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'A: район определён по точке старта'
);

-- ——— 2. Защита 12 часов ———

select public.test_as('22222222-2222-4222-8222-222222222222');
insert into test_results (name, payload)
values ('b_protected', public.submit_run(public.test_ring(37.60, 55.75, 100, 1700000100000, 4)));

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'b_protected') = 'accepted',
  'B: забег по защищённой земле принят как трек'
);
select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'b_protected') = 0,
  'B: защищённую территорию взять нельзя'
);
select public.test_assert(
  (select (payload ->> 'points_awarded')::integer from test_results where name = 'b_protected') < 2000,
  'B: начислен только бонус за дистанцию'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '22222222-2222-4222-8222-222222222222' and archived_at is null) = 0,
  'B: новая территория не создана'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '11111111-1111-4111-8111-111111111111' and archived_at is null) = 1,
  'A: территория не тронута'
);

-- ——— 3. Перехват после истечения защиты ———

update public.territories
set protected_until = captured_at
where owner_id = '11111111-1111-4111-8111-111111111111';

select public.test_as('22222222-2222-4222-8222-222222222222');
insert into test_results (name, payload)
values ('b_steal', public.submit_run(public.test_ring(37.60, 55.75, 100, 1700000200000, 4)));

select public.test_assert(
  (select (payload ->> 'stolen_area_m2')::numeric from test_results where name = 'b_steal') between 30000 and 33000,
  'B: отнята вся чужая территория'
);
select public.test_assert(
  (select (payload ->> 'points_awarded')::integer from test_results where name = 'b_steal') >= 60000,
  'B: двойные очки за отнятую землю'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '11111111-1111-4111-8111-111111111111' and archived_at is null) = 0,
  'A: территория вычтена у прежнего владельца'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '22222222-2222-4222-8222-222222222222' and archived_at is null) = 1,
  'B: территория перешла к последнему захватчику'
);
select public.test_assert(
  (select action from public.capture_history
   where actor_id = '22222222-2222-4222-8222-222222222222'
   order by created_at desc limit 1) = 'steal',
  'B: в истории записан перехват'
);
select public.test_assert(
  (select previous_owner_id from public.capture_history
   where actor_id = '22222222-2222-4222-8222-222222222222'
   order by created_at desc limit 1) = '11111111-1111-4111-8111-111111111111',
  'B: в истории указан прежний владелец'
);

-- ——— 4. Частичное наложение ———

update public.territories
set protected_until = captured_at
where owner_id = '22222222-2222-4222-8222-222222222222';

select public.test_as('33333333-3333-4333-8333-333333333333');
insert into test_results (name, payload)
values (
  'c_overlap',
  public.submit_run(public.test_ring(
    37.60 + 100.0 / (111320.0 * cos(radians(55.75))),
    55.75,
    100,
    1700000300000,
    4
  ))
);

select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'c_overlap') between 30000 and 33000,
  'C: захвачена площадь двух перекрывающихся кругов'
);
select public.test_assert(
  (select (payload ->> 'stolen_area_m2')::numeric from test_results where name = 'c_overlap') between 11000 and 13500,
  'C: отнята только зона наложения'
);
select public.test_assert(
  (select area_m2 from public.territories
   where owner_id = '22222222-2222-4222-8222-222222222222' and archived_at is null) between 17500 and 20500,
  'B: у прежнего владельца вычтена только зона наложения'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '33333333-3333-4333-8333-333333333333' and archived_at is null) = 1,
  'C: создана своя территория'
);

-- ——— 5. Скрытая домашняя зона ———

select public.test_as('44444444-4444-4444-8444-444444444444');
select public.set_home_zone(37.65, 55.75, 300);
select public.test_assert(
  (select radius_m from public.home_zones where user_id = '44444444-4444-4444-8444-444444444444') = 300,
  'D: домашняя зона сохранена'
);

insert into test_results (name, payload)
values (
  'd_capture',
  public.submit_run(public.test_ring(37.65, 55.75, 100, 1700000400000, 4))
);

select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'd_capture') between 30000 and 33000,
  'D: в своей домашней зоне захватывать можно'
);

-- Своя территория расширяется, а не создаётся второй раз.
insert into test_results (name, payload)
values (
  'd_merge',
  public.submit_run(public.test_ring(
    37.65 + 150.0 / (111320.0 * cos(radians(55.75))),
    55.75,
    100,
    1700000450000,
    4
  ))
);

select public.test_assert(
  (select (payload ->> 'status') from test_results where name = 'd_merge') = 'accepted',
  'D: расширение своей территории принято'
);
select public.test_assert(
  (select count(*) from public.territories
   where owner_id = '44444444-4444-4444-8444-444444444444' and archived_at is null) = 1,
  'D: своя территория объединена в одну запись'
);
select public.test_assert(
  (select area_m2 from public.territories
   where owner_id = '44444444-4444-4444-8444-444444444444' and archived_at is null) > 55000,
  'D: площадь объединённой территории выросла'
);
select public.test_assert(
  (select (payload ->> 'stolen_area_m2')::numeric from test_results where name = 'd_merge') = 0,
  'D: при расширении своей земли чужих очков нет'
);

select public.test_as('55555555-5555-4555-8555-555555555555');
insert into test_results (name, payload)
values (
  'e_hidden',
  public.submit_run(public.test_ring(37.65, 55.75, 100, 1700000500000, 4))
);

select public.test_assert(
  (select (payload ->> 'area_m2')::numeric from test_results where name = 'e_hidden') = 0,
  'E: чужую скрытую зону захватить нельзя'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '55555555-5555-4555-8555-555555555555' and archived_at is null) = 0,
  'E: территория в скрытой зоне не создана'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '44444444-4444-4444-8444-444444444444' and archived_at is null) = 1,
  'D: территория в своей зоне не тронута'
);

-- ——— 6. RLS: скрытая зона не видна чужим ———

select public.test_as('11111111-1111-4111-8111-111111111111');
set local role authenticated;

select public.test_assert(
  (select count(*) from public.territories
   where owner_id = '44444444-4444-4444-8444-444444444444') = 0,
  'RLS: чужая территория в скрытой зоне не видна'
);
select public.test_assert(
  (select count(*) from public.territories_in_bbox(37.64, 55.74, 37.66, 55.76)
   where owner_id = '44444444-4444-4444-8444-444444444444') = 0,
  'RLS: bbox тоже не показывает скрытую зону'
);
select public.test_assert(
  (select count(*) from public.territories_in_bbox(37.59, 55.74, 37.61, 55.76)
   where owner_id = '22222222-2222-4222-8222-222222222222') = 1,
  'bbox: обычная чужая территория видна'
);

reset role;

select public.test_as('44444444-4444-4444-8444-444444444444');
set local role authenticated;

select public.test_assert(
  (select count(*) from public.territories
   where owner_id = '44444444-4444-4444-8444-444444444444') = 1,
  'RLS: свою территорию в своей зоне видно'
);

reset role;

-- ——— 7. Рейтинг по городу ———

select public.test_as('11111111-1111-4111-8111-111111111111');
set local role authenticated;

select public.test_assert(
  (select count(*) from public.season_leaderboard('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')) = 5,
  'рейтинг: все пять игроков в таблице города'
);
select public.test_assert(
  (select user_id from public.season_leaderboard('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
   order by rank limit 1) = '22222222-2222-4222-8222-222222222222',
  'рейтинг: Боб первый по очкам'
);

reset role;

-- ——— 8. Отклонение подозрительных треков ———

select public.test_as('55555555-5555-4555-8555-555555555555');
insert into test_results (name, payload)
values (
  'e_jump',
  public.submit_run('[
    {"lon": 37.60, "lat": 55.75, "t": 1700000600000, "accuracy": 5},
    {"lon": 37.70, "lat": 55.75, "t": 1700000601000, "accuracy": 5}
  ]'::jsonb)
);

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'e_jump') = 'rejected',
  'E: скачок отклонён'
);
select public.test_assert(
  (select payload ->> 'reason' from test_results where name = 'e_jump') = 'jump',
  'E: причина — скачок'
);

insert into test_results (name, payload)
values (
  'e_accuracy',
  public.submit_run((
    select jsonb_agg(jsonb_set(point, '{accuracy}', '100'::jsonb))
    from jsonb_array_elements(public.test_ring(37.66, 55.76, 60, 1700000700000, 4)) as point
  ))
);

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'e_accuracy') = 'rejected',
  'E: плохая точность отклонена'
);
select public.test_assert(
  (select payload ->> 'reason' from test_results where name = 'e_accuracy') = 'accuracy',
  'E: причина — точность хуже 25 м'
);
select public.test_assert(
  (select count(*) from public.territories where owner_id = '55555555-5555-4555-8555-555555555555' and archived_at is null) = 0,
  'E: после отклонённых треков территории нет'
);
select public.test_assert(
  (select status from public.runs where id = ((select payload ->> 'run_id' from test_results where name = 'e_jump')::uuid)) = 'rejected',
  'E: отклонённый забег сохранён со статусом rejected'
);

-- Трек без accuracy — тоже недоверенный.
insert into test_results (name, payload)
values (
  'e_no_accuracy',
  public.submit_run('[
    {"lon": 37.66, "lat": 55.76, "t": 1700000750000},
    {"lon": 37.661, "lat": 55.761, "t": 1700000760000}
  ]'::jsonb)
);

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'e_no_accuracy') = 'rejected',
  'E: трек без точности отклонён'
);
select public.test_assert(
  (select payload ->> 'reason' from test_results where name = 'e_no_accuracy') = 'accuracy_missing',
  'E: причина — отсутствует accuracy'
);

-- Забег вне города: город/район = NULL, очки всё равно пишутся в сезон.
insert into test_results (name, payload)
values (
  'e_out_1',
  public.submit_run(public.test_ring(38.50, 55.75, 80, 1700000900000, 4))
);
insert into test_results (name, payload)
values (
  'e_out_2',
  public.submit_run(public.test_ring(38.50, 55.75, 80, 1700001000000, 4))
);

select public.test_assert(
  (select (payload ->> 'city_id') from test_results where name = 'e_out_1') is null,
  'E: вне города город не определён'
);
select public.test_assert(
  (select count(*) from public.territories
   where owner_id = '55555555-5555-4555-8555-555555555555'
     and city_id is null and archived_at is null) = 1,
  'E: территория вне города создана'
);
select public.test_assert(
  (select count(*) from public.season_scores
   where user_id = '55555555-5555-4555-8555-555555555555' and city_id is null) = 1,
  'E: очки вне города пишутся в одну строку сезона'
);
select public.test_assert(
  (select runs_count from public.season_scores
   where user_id = '55555555-5555-4555-8555-555555555555' and city_id is null) = 2,
  'E: два забега вне города учтены в одной строке'
);

-- ——— 9. Архивирование сезона и трофеи ———

select public.archive_season((select id from public.seasons where status = 'active'));

select public.test_assert(
  (select status from public.seasons order by number desc limit 1) = 'archived',
  'архив: сезон закрыт'
);
select public.test_assert(
  (select count(*) from public.territories where archived_at is null) = 0,
  'архив: все территории архивированы'
);
select public.test_assert(
  (select bool_and(trophies = points and rank is not null) from public.season_scores) is true,
  'архив: рейтинг сохранён как трофеи'
);

-- ——— 10. Новый сезон создаётся автоматически ———

select public.test_as('55555555-5555-4555-8555-555555555555');
insert into test_results (name, payload)
values (
  'new_season',
  public.submit_run(public.test_ring(37.66, 55.76, 60, 1700000800000, 4))
);

select public.test_assert(
  (select payload ->> 'status' from test_results where name = 'new_season') = 'accepted',
  'новый сезон: забег принят'
);
select public.test_assert(
  (select (payload ->> 'season_id')::uuid from test_results where name = 'new_season')
    <> (select id from public.seasons order by number desc limit 1 offset 1),
  'новый сезон: забег попал в новый сезон'
);
select public.test_assert(
  (select count(*) from public.seasons where status = 'active') = 1,
  'новый сезон: активен ровно один сезон'
);

\echo '=== Все SQL-сценарии прошли ==='
rollback;
