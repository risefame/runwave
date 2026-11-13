-- Runwave 0005: серверная защита забега.
-- Применять после 0004_api.sql.
--
-- Совместимость: старый вызов public.submit_run(p_points, p_rings) остаётся
-- и делегирует в public.submit_run_v2 без ключа идемпотентности. Новый клиент
-- вызывает submit_run_v2(p_points, p_rings, p_client_run_id).
--
-- Что закрывает миграция:
--   1. идемпотентность по (user_id, client_run_id): повтор возвращает прежний
--      результат и ничего не начисляет;
--   2. контуры p_rings больше не истина: сервер сам строит полигон из вершин
--      контура и проверяет, что контур собирается из точек трека по правилам
--      замыкания web/src/territory.ts;
--   3. правдоподобие: площадь, скорость, время отправки, дубли точек, ровные
--      интервалы, лимит забегов и потолок очков в сутки;
--   4. отклонённые забеги сохраняются со статусом rejected и reason_code;
--   5. приватность: чужие runs.raw_points и runs.track не читаются.

set search_path = public, extensions;

-- ——— 1. Идемпотентность и журнал отказов ———

alter table public.runs
  add column if not exists client_run_id uuid,
  add column if not exists reason_code text,
  add column if not exists result_json jsonb,
  add column if not exists details jsonb not null default '{}'::jsonb,
  add column if not exists submitted_at timestamptz not null default now();

update public.runs
set reason_code = rejection_reason
where reason_code is null
  and rejection_reason is not null;

create unique index if not exists runs_user_client_run_idx
  on public.runs (user_id, client_run_id)
  where client_run_id is not null;

create index if not exists runs_status_reason_idx
  on public.runs (status, reason_code);

create index if not exists runs_user_submitted_idx
  on public.runs (user_id, submitted_at desc);

-- ——— 2. Новые параметры игры ———

insert into public.game_config (key, value, description) values
  ('submit_window_minutes', 180, 'Сколько минут после финиша забег ещё принимается'),
  ('max_runs_per_day', 40, 'Максимум принятых забегов игрока в сутки'),
  ('daily_points_cap', 150000, 'Потолок очков игрока в сутки'),
  ('min_point_spacing_m', 0.5, 'Расстояние, ниже которого шаг считается дублем, м'),
  ('duplicate_share', 0.5, 'Доля шагов-дублей, при которой трек отклоняется'),
  ('regular_interval_share', 0.9, 'Доля полностью одинаковых шагов (время и длина), при которой трек считается синтетическим'),
  ('regular_interval_tolerance_ms', 100, 'Округление интервалов времени при поиске ровных шагов, мс'),
  ('regular_distance_tolerance_m', 5, 'Округление длин шагов при поиске ровных шагов, м'),
  ('area_tolerance', 1.05, 'Допуск к изопериметрической оценке площади'),
  ('clock_skew_s', 600, 'Допустимое расхождение часов устройства, с'),
  ('ring_tolerance_m', 5, 'Допуск «вершина контура лежит на треке», м'),
  ('boundary_touch_m', 12, 'Допуск касания границы своей территории, м')
on conflict (key) do nothing;

-- ——— 3. Помощники ———

-- Сохранение отклонённого забега: причина видна в runs.reason_code и details,
-- очки не начисляются, результат пишется в result_json для идемпотентности.
create or replace function public.save_rejected_run(
  p_user uuid,
  p_season uuid,
  p_client_run_id uuid,
  p_reason text,
  p_points jsonb,
  p_track geometry,
  p_started_at timestamptz,
  p_finished_at timestamptz,
  p_distance double precision,
  p_duration double precision,
  p_details jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run_id uuid;
  v_result jsonb;
begin
  insert into public.runs (
    user_id, season_id, client_run_id, started_at, finished_at,
    distance_m, duration_s, track, raw_points, status,
    rejection_reason, reason_code, details
  ) values (
    p_user,
    p_season,
    p_client_run_id,
    coalesce(p_started_at, now()),
    coalesce(p_finished_at, p_started_at, now()),
    coalesce(p_distance, 0),
    coalesce(p_duration, 0),
    p_track,
    coalesce(p_points, '[]'::jsonb),
    'rejected',
    p_reason,
    p_reason,
    coalesce(p_details, '{}'::jsonb)
  )
  returning id into v_run_id;

  v_result := jsonb_build_object(
    'status', 'rejected',
    'reason', p_reason,
    'reason_code', p_reason,
    'run_id', v_run_id,
    'season_id', p_season,
    'client_run_id', p_client_run_id,
    'points_awarded', 0,
    'area_m2', 0,
    'details', coalesce(p_details, '{}'::jsonb)
  );

  update public.runs set result_json = v_result where id = v_run_id;

  return v_result;
end;
$$;

revoke all on function public.save_rejected_run(
  uuid, uuid, uuid, text, jsonb, geometry, timestamptz, timestamptz,
  double precision, double precision, jsonb
) from public;

-- Проверка присланного контура.
--
-- Контур — не истина и не набор произвольных точек: он должен быть замкнутой
-- петлёй, целиком собранной из точек трека в порядке прохождения.
--   ring_off_track    — вершина дальше 50 м от трека и не на границе своей
--                       территории: явная подделка, забег отклоняется;
--   ring_boundary_arc — вершина на границе своей территории (замыкание дугой,
--                       механика Paper.io): сервер такой контур не засчитывает,
--                       как и до 0005, но и не считает подделкой;
--   ring_untracked    — вершина рядом с треком, но не в допуске 5 м: контур
--                       не засчитывается, забег остаётся принятым (так бывает
--                       у контура, привязанного к территории, которую игрок
--                       захватил в этом же забеге);
--   ring_not_ordered  — вершины идут не в порядке трека (контур собран
--                       из далёких друг от друга участков);
--   ring_not_closed   — замыкание не по правилам: замыкающее ребро не лежит
--                       на треке и его длина больше радиуса замыкания;
--   ring_format / ring_degenerate — битые данные или нулевая площадь.
--
-- Возвращает полигон, построенный сервером из вершин контура, либо null.
create or replace function public.check_run_ring(
  p_ring jsonb,
  p_track geometry,
  p_own geometry,
  p_loop_radius numeric,
  p_track_length double precision,
  p_ring_tolerance double precision,
  p_boundary_tolerance double precision,
  out claim geometry,
  out issue text
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_count integer;
  v_i integer;
  v_point jsonb;
  v_lon double precision;
  v_lat double precision;
  v_vertex geometry;
  v_vertices geometry[] := array[]::geometry[];
  v_first geometry;
  v_last geometry;
  v_frac double precision;
  v_prev_frac double precision := -1;
  v_step double precision;
  v_on_boundary boolean;
  v_dist double precision;
  v_line geometry;
  v_poly geometry;
begin
  claim := null;
  issue := null;

  if p_track is null
     or p_ring is null
     or jsonb_typeof(p_ring) is distinct from 'array' then
    issue := 'ring_format';
    return;
  end if;

  v_count := jsonb_array_length(p_ring);
  if v_count < 3 or v_count > 2000 then
    issue := 'ring_format';
    return;
  end if;

  for v_i in 0 .. v_count - 1 loop
    v_point := p_ring -> v_i;

    if jsonb_typeof(v_point) is distinct from 'array'
       or jsonb_array_length(v_point) < 2
       or jsonb_typeof(v_point -> 0) is distinct from 'number'
       or jsonb_typeof(v_point -> 1) is distinct from 'number' then
      issue := 'ring_format';
      return;
    end if;

    v_lon := (v_point ->> 0)::double precision;
    v_lat := (v_point ->> 1)::double precision;

    if v_lon < -180 or v_lon > 180
       or v_lat < -85.0511 or v_lat > 85.0511 then
      issue := 'ring_format';
      return;
    end if;

    v_vertices := v_vertices || st_setsrid(st_makepoint(v_lon, v_lat), 4326);
  end loop;

  v_first := v_vertices[1];
  v_last := v_vertices[array_length(v_vertices, 1)];

  -- Каждая вершина должна быть точкой трека; исключение — замыкание по
  -- границе своей территории, которое сервер пока не засчитывает.
  for v_i in 1 .. array_length(v_vertices, 1) loop
    v_vertex := v_vertices[v_i];

    if st_dwithin(p_track::geography, v_vertex::geography, p_ring_tolerance) then
      continue;
    end if;

    v_on_boundary := p_own is not null
      and not st_isempty(p_own)
      and st_dwithin(
        st_boundary(p_own)::geography,
        v_vertex::geography,
        p_boundary_tolerance
      );

    if v_on_boundary then
      issue := 'ring_boundary_arc';
      return;
    end if;

    -- 50 м — предел правдоподобного смещения вершины от трека. Дальше
    -- контур собран не из трека: это подделка, забег отклоняется.
    v_dist := st_distance(p_track::geography, v_vertex::geography);

    if v_dist > 50 then
      issue := 'ring_off_track';
    else
      issue := 'ring_untracked';
    end if;

    return;
  end loop;

  -- Вершины идут вдоль трека: контур собирается из одного прохода, а не
  -- из отдельных далёких участков.
  v_step := 3.0 / greatest(coalesce(p_track_length, 1), 1);

  for v_i in 1 .. array_length(v_vertices, 1) loop
    v_frac := st_linelocatepoint(p_track, v_vertices[v_i]);

    if v_frac + v_step < v_prev_frac then
      issue := 'ring_not_ordered';
      return;
    end if;

    if v_frac > v_prev_frac then
      v_prev_frac := v_frac;
    end if;
  end loop;

  -- Замыкание: либо возврат к началу в радиусе замыкания, либо замыкающее
  -- ребро лежит на треке (самопересечение петли).
  if st_distance(v_first::geography, v_last::geography) > coalesce(p_loop_radius, 15)
     and not st_dwithin(st_makeline(v_first, v_last), p_track, p_ring_tolerance) then
    issue := 'ring_not_closed';
    return;
  end if;

  if not st_equals(v_first, v_last) then
    v_vertices := v_vertices || v_first;
  end if;

  if array_length(v_vertices, 1) < 4 then
    issue := 'ring_degenerate';
    return;
  end if;

  v_line := st_makeline(v_vertices);

  begin
    v_poly := st_makevalid(st_makepolygon(v_line));
  exception
    when others then
      issue := 'ring_degenerate';
      return;
  end;

  if v_poly is null then
    issue := 'ring_degenerate';
    return;
  end if;

  if geometrytype(v_poly) not in ('POLYGON', 'MULTIPOLYGON') then
    v_poly := st_collectionextract(v_poly, 3);
  end if;

  if v_poly is null or st_isempty(v_poly) then
    issue := 'ring_degenerate';
    return;
  end if;

  if st_area(v_poly::geography) <= 0 or st_perimeter(v_poly::geography) <= 0 then
    issue := 'ring_degenerate';
    return;
  end if;

  claim := st_multi(v_poly);
end;
$$;

revoke all on function public.check_run_ring(
  jsonb, geometry, geometry, numeric, double precision, double precision, double precision
) from public;

-- Правдоподобие площади: изопериметрическая оценка самого контура и предел,
-- который позволяет пройденная дистанция.
create or replace function public.claim_plausible(
  p_claim geometry,
  p_track_length double precision,
  p_tolerance double precision default 1.05
)
returns boolean
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_claim is null or st_isempty(p_claim) then true
    else
      st_area(p_claim::geography)
        <= power(st_perimeter(p_claim::geography), 2) / (4 * pi()) * p_tolerance
      and st_area(p_claim::geography)
        <= power(greatest(coalesce(p_track_length, 0), 0) + 30, 2)
           / (4 * pi()) * p_tolerance
  end;
$$;

revoke all on function public.claim_plausible(geometry, double precision, double precision) from public;

-- ——— 4. Приём забега ———

create or replace function public.submit_run_v2(
  p_points jsonb,
  p_rings jsonb default '[]'::jsonb,
  p_client_run_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_season uuid;
  v_city uuid;
  v_district uuid;
  v_existing jsonb;
  v_count integer;
  v_i integer;
  v_ring_index integer;
  v_ring jsonb;
  v_pt jsonb;
  v_lon double precision;
  v_lat double precision;
  v_t double precision;
  v_acc double precision;
  v_prev_t double precision;
  v_prev_lon double precision;
  v_prev_lat double precision;
  v_first_t double precision;
  v_last_t double precision;
  v_dist double precision;
  v_dt double precision;
  v_total_dist double precision := 0;
  v_duration double precision := 0;
  v_points geometry[] := array[]::geometry[];
  v_intervals integer[] := array[]::integer[];
  v_dist_buckets integer[] := array[]::integer[];
  v_track geometry;
  v_start geometry;
  v_end geometry;
  v_speed double precision := 0;
  v_max_speed numeric;
  v_max_acc numeric;
  v_max_jump numeric;
  v_max_points integer;
  v_min_area numeric;
  v_min_perimeter numeric;
  v_min_gain numeric;
  v_loop_radius numeric;
  v_points_per_m2 numeric;
  v_stolen_multiplier numeric;
  v_distance_bonus numeric;
  v_protection_hours numeric;
  v_submit_window numeric;
  v_max_runs_per_day numeric;
  v_daily_cap numeric;
  v_min_spacing numeric;
  v_duplicate_share numeric;
  v_regular_share numeric;
  v_regular_ms numeric;
  v_regular_m numeric;
  v_area_tolerance numeric;
  v_clock_skew numeric;
  v_ring_tolerance numeric;
  v_boundary_tolerance numeric;
  v_duplicates integer := 0;
  v_mode_count integer := 0;
  v_duplicate_share_actual numeric := 0;
  v_regular_share_actual numeric := 0;
  v_daily_runs integer := 0;
  v_daily_points numeric := 0;
  v_cap_left integer := 0;
  v_started_at timestamptz;
  v_finished_at timestamptz;
  v_reason text;
  v_issue_key text;
  v_details jsonb := '{}'::jsonb;
  v_issue_counts jsonb := '{}'::jsonb;
  v_ignored_rings integer := 0;
  v_ring_claim geometry;
  v_ring_issue text;
  v_claim_union geometry;
  v_claim geometry;
  v_forbidden geometry;
  v_own geometry;
  v_enemy geometry;
  v_protected_geom geometry;
  v_stealable geometry;
  v_owned geometry;
  v_neutral geometry;
  v_stolen geometry;
  v_capture geometry;
  v_merged geometry;
  v_own_union geometry;
  v_remaining geometry;
  v_base_id uuid;
  v_territory_id uuid;
  v_area_new double precision := 0;
  v_area_stolen double precision := 0;
  v_area_capture double precision := 0;
  v_points_award integer := 0;
  v_run_id uuid;
  v_prev_owner uuid;
  v_rec record;
  v_protected_until timestamptz;
  v_result jsonb;
begin
  if v_user is null then
    raise exception 'Требуется авторизация' using errcode = '28000';
  end if;

  if p_points is null or jsonb_typeof(p_points) is distinct from 'array' then
    raise exception 'p_points должен быть JSON-массивом' using errcode = '22023';
  end if;

  -- Идемпотентность: повторная отправка того же client_run_id возвращает
  -- прежний результат и ничего не начисляет. Блокировка снимает гонку
  -- двух одновременных отправок одного забега.
  if p_client_run_id is not null then
    perform pg_advisory_xact_lock(
      hashtext(v_user::text || ':' || p_client_run_id::text)
    );

    select r.result_json into v_existing
    from public.runs r
    where r.user_id = v_user
      and r.client_run_id = p_client_run_id;

    if found then
      if v_existing is not null then
        return v_existing || jsonb_build_object('idempotent', true);
      end if;

      select jsonb_build_object(
        'status', r.status,
        'reason', coalesce(r.reason_code, r.rejection_reason),
        'reason_code', coalesce(r.reason_code, r.rejection_reason),
        'run_id', r.id,
        'season_id', r.season_id,
        'client_run_id', r.client_run_id,
        'points_awarded', r.points_awarded,
        'area_m2', r.area_m2,
        'idempotent', true
      ) into v_existing
      from public.runs r
      where r.user_id = v_user
        and r.client_run_id = p_client_run_id;

      return v_existing;
    end if;
  end if;

  insert into public.profiles (user_id)
  values (v_user)
  on conflict (user_id) do nothing;

  v_season := public.ensure_active_season();

  v_max_speed := coalesce(public.config_num('max_speed_mps'), 7);
  v_max_acc := coalesce(public.config_num('max_accuracy_m'), 25);
  v_max_jump := coalesce(public.config_num('max_jump_m'), 500);
  v_max_points := coalesce(public.config_num('max_run_points'), 10000)::integer;
  v_min_area := coalesce(public.config_num('min_area_m2'), 500);
  v_min_perimeter := coalesce(public.config_num('min_perimeter_m'), 40);
  v_min_gain := coalesce(public.config_num('min_gain_m2'), 1);
  v_loop_radius := coalesce(public.config_num('loop_close_radius_m'), 15);
  v_points_per_m2 := coalesce(public.config_num('points_per_m2'), 1);
  v_stolen_multiplier := coalesce(public.config_num('stolen_points_multiplier'), 2);
  v_protection_hours := coalesce(public.config_num('protection_hours'), 12);
  v_submit_window := coalesce(public.config_num('submit_window_minutes'), 180);
  v_max_runs_per_day := coalesce(public.config_num('max_runs_per_day'), 40);
  v_daily_cap := coalesce(public.config_num('daily_points_cap'), 150000);
  v_min_spacing := coalesce(public.config_num('min_point_spacing_m'), 0.5);
  v_duplicate_share := coalesce(public.config_num('duplicate_share'), 0.5);
  v_regular_share := coalesce(public.config_num('regular_interval_share'), 0.9);
  v_regular_ms := greatest(coalesce(public.config_num('regular_interval_tolerance_ms'), 100), 1);
  v_regular_m := greatest(coalesce(public.config_num('regular_distance_tolerance_m'), 5), 1);
  v_area_tolerance := coalesce(public.config_num('area_tolerance'), 1.05);
  v_clock_skew := coalesce(public.config_num('clock_skew_s'), 600);
  v_ring_tolerance := coalesce(public.config_num('ring_tolerance_m'), 5);
  v_boundary_tolerance := coalesce(public.config_num('boundary_touch_m'), 12);

  v_count := jsonb_array_length(p_points);

  if v_count < 2 then
    raise exception 'Нужно минимум две точки' using errcode = '22023';
  end if;

  if v_count > v_max_points then
    v_reason := 'too_many_points';
  end if;

  if v_reason is null then
    for v_i in 0 .. v_count - 1 loop
      v_pt := p_points -> v_i;

      if jsonb_typeof(v_pt) is distinct from 'object' then
        raise exception 'Точка % должна быть объектом', v_i using errcode = '22023';
      end if;

      if jsonb_typeof(v_pt -> 'lon') is distinct from 'number'
         or jsonb_typeof(v_pt -> 'lat') is distinct from 'number'
         or jsonb_typeof(v_pt -> 't') is distinct from 'number' then
        raise exception 'Точка %: нужны числовые lon, lat и t', v_i using errcode = '22023';
      end if;

      if jsonb_typeof(v_pt -> 'accuracy') is distinct from 'number' then
        v_reason := 'accuracy_missing';
        exit;
      end if;

      v_lon := (v_pt ->> 'lon')::double precision;
      v_lat := (v_pt ->> 'lat')::double precision;
      v_t := (v_pt ->> 't')::double precision;
      v_acc := (v_pt ->> 'accuracy')::double precision;

      if v_lon < -180 or v_lon > 180
         or v_lat < -85.0511 or v_lat > 85.0511 then
        raise exception 'Точка %: координаты вне диапазона', v_i using errcode = '22023';
      end if;

      if v_acc < 0 or v_acc > v_max_acc then
        v_reason := 'accuracy';
        exit;
      end if;

      if v_first_t is null then
        v_first_t := v_t;
      elsif v_t <= v_prev_t then
        v_reason := 'timestamps';
        exit;
      end if;

      if v_prev_t is not null then
        v_dt := (v_t - v_prev_t) / 1000.0;
        v_dist := st_distance(
          st_setsrid(st_makepoint(v_prev_lon, v_prev_lat), 4326)::geography,
          st_setsrid(st_makepoint(v_lon, v_lat), 4326)::geography
        );

        if v_dt <= 0 then
          v_reason := 'timestamps';
          exit;
        end if;

        if v_dist > v_max_jump then
          v_reason := 'jump';
          exit;
        end if;

        if v_dist / v_dt > v_max_speed then
          v_reason := 'speed';
          exit;
        end if;

        v_total_dist := v_total_dist + v_dist;

        if v_dist < v_min_spacing then
          v_duplicates := v_duplicates + 1;
        end if;

        v_intervals := v_intervals
          || (round(v_dt * 1000 / v_regular_ms) * v_regular_ms)::integer;
        v_dist_buckets := v_dist_buckets
          || (floor(v_dist / v_regular_m) * v_regular_m)::integer;
      end if;

      v_points := v_points || st_setsrid(st_makepoint(v_lon, v_lat), 4326);
      v_prev_lon := v_lon;
      v_prev_lat := v_lat;
      v_prev_t := v_t;
      v_last_t := v_t;
    end loop;
  end if;

  if v_reason is null and coalesce(array_length(v_intervals, 1), 0) > 0 then
    v_duplicate_share_actual :=
      v_duplicates::numeric / array_length(v_intervals, 1);

    if v_duplicate_share_actual > v_duplicate_share then
      v_reason := 'duplicate_points';
    end if;
  end if;

  -- Идеально ровные шаги: одинаковые и по времени, и по длине. У реального
  -- трека интервалы и скорость плавают, у сгенерированного — нет.
  if v_reason is null and coalesce(array_length(v_intervals, 1), 0) >= 30 then
    select max(g.c) into v_mode_count
    from (
      select count(*) as c
      from unnest(v_intervals, v_dist_buckets) as s(dt, dist)
      group by s.dt, s.dist
    ) g;

    v_regular_share_actual :=
      coalesce(v_mode_count, 0)::numeric / array_length(v_intervals, 1);

    if v_regular_share_actual >= v_regular_share then
      v_reason := 'regular_intervals';
    end if;
  end if;

  if v_reason is null then
    v_started_at := to_timestamp(v_first_t / 1000.0);
    v_finished_at := to_timestamp(v_last_t / 1000.0);
    v_duration := greatest(0, (v_last_t - v_first_t) / 1000.0);

    if v_duration <= 0 then
      v_reason := 'timestamps';
    elsif v_total_dist <= 0 then
      v_reason := 'duplicate_points';
    end if;
  end if;

  if v_reason is null then
    v_speed := v_total_dist / v_duration;

    if v_speed > v_max_speed * 1.001 then
      v_reason := 'speed';
    end if;
  end if;

  -- Метки времени: не из будущего (с поправкой на часы устройства) и забег
  -- отправлен не позже окна после финиша.
  if v_reason is null then
    if v_finished_at > now() + make_interval(secs => v_clock_skew::integer)
       or v_started_at > now() + make_interval(secs => v_clock_skew::integer) then
      v_reason := 'future_timestamp';
    elsif now() > v_finished_at
          + make_interval(secs => v_clock_skew::integer)
          + make_interval(mins => v_submit_window::integer) then
      v_reason := 'late_submission';
    end if;
  end if;

  select count(*), coalesce(sum(r.points_awarded), 0)
  into v_daily_runs, v_daily_points
  from public.runs r
  where r.user_id = v_user
    and r.status = 'accepted'
    and r.submitted_at >= date_trunc('day', now());

  v_cap_left := greatest(0, (v_daily_cap - v_daily_points)::integer);

  if v_reason is null and v_daily_runs >= v_max_runs_per_day then
    v_reason := 'too_many_runs';
  end if;

  if coalesce(array_length(v_points, 1), 0) >= 2 then
    v_track := st_setsrid(st_makeline(v_points), 4326);
  end if;

  if v_reason is not null then
    v_details := jsonb_build_object(
      'points', v_count,
      'distance_m', round(coalesce(v_total_dist, 0)::numeric, 1),
      'duration_s', round(coalesce(v_duration, 0)::numeric, 1),
      'speed_mps', round(coalesce(v_speed, 0)::numeric, 2),
      'duplicate_share', round(coalesce(v_duplicate_share_actual, 0), 3),
      'regular_share', round(coalesce(v_regular_share_actual, 0), 3)
    );

    return public.save_rejected_run(
      v_user,
      v_season,
      p_client_run_id,
      v_reason,
      p_points,
      v_track,
      case when v_first_t is null then null else to_timestamp(v_first_t / 1000.0) end,
      case when v_last_t is null then null else to_timestamp(v_last_t / 1000.0) end,
      v_total_dist,
      v_duration,
      v_details
    );
  end if;

  v_track := st_setsrid(st_makeline(v_points), 4326);
  v_total_dist := coalesce(st_length(v_track::geography), 0);
  v_start := st_startpoint(v_track);
  v_end := st_endpoint(v_track);
  v_duration := greatest(0, (v_last_t - v_first_t) / 1000.0);

  select c.id into v_city
  from public.cities c
  where st_intersects(c.geom, v_start)
  order by st_area(c.geom::geography) asc
  limit 1;

  if v_city is not null then
    select d.id into v_district
    from public.districts d
    where d.city_id = v_city
      and st_intersects(d.geom, v_start)
    order by st_area(d.geom::geography) asc
    limit 1;
  end if;

  v_distance_bonus := coalesce(public.config_num('distance_bonus_per_meter'), 2);
  v_points_award := least(
    round(v_total_dist * v_distance_bonus)::integer,
    v_cap_left
  );

  select st_union(t.geom) into v_own
  from public.territories t
  where t.owner_id = v_user
    and t.season_id = v_season
    and t.archived_at is null;

  -- Территорию считает сервер: контуры клиента проверяются и превращаются
  -- в полигон здесь же, площадь из клиента не принимается.
  v_claim_union := null;

  if p_rings is not null
     and jsonb_typeof(p_rings) = 'array'
     and jsonb_array_length(p_rings) > 0 then
    for v_ring_index in 0 .. jsonb_array_length(p_rings) - 1 loop
      v_ring := p_rings -> v_ring_index;

      select c.claim, c.issue
      into v_ring_claim, v_ring_issue
      from public.check_run_ring(
        v_ring,
        v_track,
        v_own,
        v_loop_radius,
        v_total_dist,
        v_ring_tolerance,
        v_boundary_tolerance
      ) c;

      if v_ring_issue = 'ring_off_track' then
        v_reason := 'ring_off_track';
        exit;
      end if;

      if v_ring_claim is null then
        v_ignored_rings := v_ignored_rings + 1;
        v_issue_key := coalesce(v_ring_issue, 'ring_degenerate');
        v_issue_counts := jsonb_set(
          v_issue_counts,
          array[v_issue_key],
          to_jsonb(
            coalesce((v_issue_counts ->> v_issue_key)::integer, 0) + 1
          ),
          true
        );
        continue;
      end if;

      if not public.claim_plausible(v_ring_claim, v_total_dist, v_area_tolerance) then
        v_reason := 'area_implausible';
        exit;
      end if;

      v_claim_union := case
        when v_claim_union is null then v_ring_claim
        else st_union(v_claim_union, v_ring_claim)
      end;
    end loop;
  end if;

  -- Клиент не прислал валидных контуров: замыкание по возврату к началу
  -- сервер строит сам.
  if v_reason is null
     and (v_claim_union is null or st_isempty(v_claim_union))
     and v_count >= 3
     and st_distance(v_start::geography, v_end::geography) <= v_loop_radius then
    begin
      if st_equals(v_start, v_end) then
        v_claim_union := st_makevalid(st_makepolygon(v_track));
      else
        v_claim_union := st_makevalid(st_makepolygon(st_addpoint(v_track, v_start)));
      end if;
    exception
      when others then
        v_claim_union := null;
    end;
  end if;

  if v_reason is null and v_claim_union is not null and not st_isempty(v_claim_union) then
    if geometrytype(v_claim_union) not in ('POLYGON', 'MULTIPOLYGON') then
      v_claim_union := st_collectionextract(v_claim_union, 3);
    end if;

    if v_claim_union is null or st_isempty(v_claim_union) then
      v_claim_union := null;
    else
      v_claim_union := st_multi(v_claim_union);

      if not public.claim_plausible(v_claim_union, v_total_dist, v_area_tolerance) then
        v_reason := 'area_implausible';
      end if;
    end if;
  end if;

  if v_reason is not null then
    v_details := jsonb_build_object(
      'points', v_count,
      'ignored_rings', v_ignored_rings,
      'ring_issues', v_issue_counts,
      'claim_area_m2', case
        when v_claim_union is null then 0
        else round(st_area(v_claim_union::geography)::numeric, 1)
      end
    );

    return public.save_rejected_run(
      v_user,
      v_season,
      p_client_run_id,
      v_reason,
      p_points,
      v_track,
      to_timestamp(v_first_t / 1000.0),
      to_timestamp(v_last_t / 1000.0),
      v_total_dist,
      v_duration,
      v_details
    );
  end if;

  insert into public.runs (
    user_id, season_id, city_id, district_id, started_at, finished_at,
    distance_m, duration_s, track, raw_points, status, points_awarded,
    client_run_id, details
  ) values (
    v_user,
    v_season,
    v_city,
    v_district,
    to_timestamp(v_first_t / 1000.0),
    to_timestamp(v_last_t / 1000.0),
    v_total_dist,
    v_duration,
    v_track,
    p_points,
    'accepted',
    v_points_award,
    p_client_run_id,
    jsonb_build_object('ignored_rings', v_ignored_rings, 'ring_issues', v_issue_counts)
  )
  returning id into v_run_id;

  if v_claim_union is not null
     and not st_isempty(v_claim_union)
     and st_area(v_claim_union::geography) >= v_min_area
     and st_perimeter(v_claim_union::geography) >= v_min_perimeter then
    v_claim := v_claim_union;

    -- Территории внутри чужой домашней зоны не отдаются.
    select st_union(hz.area) into v_forbidden
    from public.home_zones hz
    where hz.user_id <> v_user;

    if v_forbidden is not null and not st_isempty(v_forbidden) then
      v_claim := st_makevalid(st_difference(v_claim, v_forbidden));
      v_claim := st_multi(st_collectionextract(v_claim, 3));
    end if;

    if v_claim is not null and not st_isempty(v_claim) then
      select st_union(t.geom) into v_enemy
      from public.territories t
      where t.owner_id <> v_user
        and t.season_id = v_season
        and t.archived_at is null;

      select st_union(t.geom) into v_protected_geom
      from public.territories t
      where t.owner_id <> v_user
        and t.season_id = v_season
        and t.archived_at is null
        and t.protected_until > now();

      v_stealable := null;
      if v_enemy is not null and not st_isempty(v_enemy) then
        v_stealable := st_difference(
          v_enemy,
          coalesce(v_protected_geom, st_setsrid('POLYGON EMPTY'::geometry, 4326))
        );
        v_stealable := st_multi(st_collectionextract(st_makevalid(v_stealable), 3));
      end if;

      v_owned := st_union(
        coalesce(v_own, st_setsrid('POLYGON EMPTY'::geometry, 4326)),
        coalesce(v_enemy, st_setsrid('POLYGON EMPTY'::geometry, 4326))
      );

      v_neutral := st_makevalid(st_difference(v_claim, v_owned));
      v_neutral := st_multi(st_collectionextract(v_neutral, 3));

      v_stolen := null;
      if v_stealable is not null and not st_isempty(v_stealable) then
        v_stolen := st_makevalid(st_intersection(v_claim, v_stealable));
        v_stolen := st_multi(st_collectionextract(v_stolen, 3));
      end if;

      v_capture := st_union(
        coalesce(v_neutral, st_setsrid('POLYGON EMPTY'::geometry, 4326)),
        coalesce(v_stolen, st_setsrid('POLYGON EMPTY'::geometry, 4326))
      );
      v_capture := st_multi(st_collectionextract(st_makevalid(v_capture), 3));

      if v_capture is not null and not st_isempty(v_capture) then
        v_area_new := coalesce(st_area(v_neutral::geography), 0);
        v_area_stolen := coalesce(st_area(v_stolen::geography), 0);
        v_area_capture := v_area_new + v_area_stolen;

        if v_area_capture >= v_min_gain then
          -- Потолок очков в сутки: лишнее не начисляется.
          v_points_award := least(
            round(
              v_area_new * v_points_per_m2
              + v_area_stolen * v_points_per_m2 * v_stolen_multiplier
              + v_total_dist * v_distance_bonus
            )::integer,
            v_cap_left
          );

          select t.owner_id into v_prev_owner
          from public.territories t
          where t.owner_id <> v_user
            and t.season_id = v_season
            and t.archived_at is null
            and v_stolen is not null
            and st_intersects(t.geom, v_stolen)
          order by st_area(st_intersection(t.geom, v_stolen)::geography) desc
          limit 1;

          -- Пересекающийся участок вычитается у прежнего владельца.
          for v_rec in
            select t.id, t.owner_id, t.geom
            from public.territories t
            where t.owner_id <> v_user
              and t.season_id = v_season
              and t.archived_at is null
              and st_intersects(t.geom, v_capture)
          loop
            v_remaining := st_makevalid(st_difference(v_rec.geom, v_capture));
            v_remaining := st_multi(st_collectionextract(v_remaining, 3));

            if v_remaining is null
               or st_isempty(v_remaining)
               or st_area(v_remaining::geography) < v_min_gain then
              delete from public.territories where id = v_rec.id;
            else
              update public.territories
              set geom = v_remaining,
                  area_m2 = st_area(v_remaining::geography),
                  updated_at = now()
              where id = v_rec.id;
            end if;
          end loop;

          v_protected_until := now()
            + make_interval(hours => v_protection_hours::integer);

          -- Своя территория расширяется, чужая — не трогается.
          select t.id into v_base_id
          from public.territories t
          where t.owner_id = v_user
            and t.season_id = v_season
            and t.archived_at is null
            and st_intersects(t.geom, v_capture)
          order by t.captured_at asc
          limit 1;

          if v_base_id is not null then
            select st_union(t.geom) into v_own_union
            from public.territories t
            where t.owner_id = v_user
              and t.season_id = v_season
              and t.archived_at is null
              and st_intersects(t.geom, v_capture);

            v_merged := st_multi(st_collectionextract(
              st_makevalid(st_union(v_own_union, v_capture)),
              3
            ));

            update public.territories
            set geom = v_merged,
                area_m2 = st_area(v_merged::geography),
                protected_until = v_protected_until,
                updated_at = now()
            where id = v_base_id;

            delete from public.territories
            where owner_id = v_user
              and season_id = v_season
              and archived_at is null
              and id <> v_base_id
              and st_intersects(geom, v_capture);

            v_territory_id := v_base_id;
          else
            insert into public.territories (
              owner_id, season_id, city_id, district_id, geom, area_m2,
              captured_at, protected_until
            ) values (
              v_user,
              v_season,
              v_city,
              v_district,
              v_capture,
              st_area(v_capture::geography),
              now(),
              v_protected_until
            )
            returning id into v_territory_id;
          end if;

          insert into public.capture_history (
            season_id, run_id, territory_id, actor_id, previous_owner_id,
            action, geom, area_new_m2, area_stolen_m2, points
          ) values (
            v_season,
            v_run_id,
            v_territory_id,
            v_user,
            v_prev_owner,
            case when v_area_stolen > 0 then 'steal' else 'claim' end,
            v_capture,
            v_area_new,
            v_area_stolen,
            v_points_award
          );

          update public.runs
          set points_awarded = v_points_award,
              area_m2 = v_area_capture,
              stolen_area_m2 = v_area_stolen,
              territory_id = v_territory_id
          where id = v_run_id;
        else
          v_area_new := 0;
          v_area_stolen := 0;
          v_area_capture := 0;
        end if;
      end if;
    end if;
  end if;

  insert into public.season_scores as ss (
    season_id, user_id, city_id, district_id, points, distance_m, area_m2,
    runs_count, updated_at
  ) values (
    v_season,
    v_user,
    v_city,
    v_district,
    v_points_award,
    v_total_dist,
    v_area_capture,
    1,
    now()
  )
  on conflict (season_id, user_id, city_id, district_id) do update
  set points = ss.points + excluded.points,
      distance_m = ss.distance_m + excluded.distance_m,
      area_m2 = ss.area_m2 + excluded.area_m2,
      runs_count = ss.runs_count + 1,
      updated_at = now();

  v_result := jsonb_build_object(
    'status', 'accepted',
    'run_id', v_run_id,
    'season_id', v_season,
    'client_run_id', p_client_run_id,
    'city_id', v_city,
    'district_id', v_district,
    'distance_m', round(v_total_dist::numeric, 1),
    'duration_s', round(v_duration::numeric, 1),
    'points_awarded', v_points_award,
    'area_m2', round(v_area_capture::numeric, 1),
    'stolen_area_m2', round(v_area_stolen::numeric, 1),
    'territory_id', v_territory_id,
    'protected_until', v_protected_until,
    'ignored_rings', v_ignored_rings,
    'idempotent', false
  );

  update public.runs set result_json = v_result where id = v_run_id;

  return v_result;
end;
$$;

revoke all on function public.submit_run_v2(jsonb, jsonb, uuid) from public;
grant execute on function public.submit_run_v2(jsonb, jsonb, uuid) to authenticated;

-- Старая сигнатура сохраняется: старые сборки клиента продолжают работать,
-- все новые проверки применяются и к ним. Идемпотентности у них нет.
create or replace function public.submit_run(
  p_points jsonb,
  p_rings jsonb default '[]'::jsonb
)
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
  select public.submit_run_v2(p_points, p_rings, null);
$$;

revoke all on function public.submit_run(jsonb, jsonb) from public;
grant execute on function public.submit_run(jsonb, jsonb) to authenticated;

-- ——— 5. Приватность забегов ———

-- Чужие забеги не читаются вообще: ни трек, ни сырые точки.
-- runs.raw_points и runs.track доступны только владельцу строки; anon
-- не имеет ни политики, ни прав.
alter table public.runs enable row level security;

drop policy if exists runs_select_own on public.runs;
create policy runs_select_own on public.runs
  for select to authenticated
  using (user_id = auth.uid());

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.runs from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke insert, update, delete on public.runs from authenticated';
    execute 'grant select on public.runs to authenticated';
  end if;
end
$$;

comment on column public.runs.raw_points is
  'Сырые GPS-точки. Читаются только владельцем строки (RLS runs_select_own).';
comment on column public.runs.track is
  'Трек LineString. Читается только владельцем строки (RLS runs_select_own).';
