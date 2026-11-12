-- Игровые функции: сезоны, домашняя зона, приём забега, запросы карты и рейтинга.

set search_path = public, extensions;

create or replace function public.config_num(p_key text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select value from public.game_config where key = p_key;
$$;

revoke all on function public.config_num(text) from public;

-- ——— Сезоны ———

create or replace function public.archive_season(p_season_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_territories integer;
  v_scores integer;
begin
  select status into v_status
  from public.seasons
  where id = p_season_id
  for update;

  if v_status is null then
    raise exception 'Сезон % не найден', p_season_id using errcode = 'P0002';
  end if;

  if v_status = 'archived' then
    return jsonb_build_object(
      'status', 'archived',
      'season_id', p_season_id,
      'already_archived', true
    );
  end if;

  -- Рейтинг фиксируется как трофеи; ранг считается отдельно по каждому
  -- городу и району.
  with ranked as (
    select
      id,
      row_number() over (
        partition by city_id, district_id
        order by points desc, updated_at asc
      ) as rn
    from public.season_scores
    where season_id = p_season_id
  )
  update public.season_scores s
  set rank = r.rn,
      trophies = s.points,
      updated_at = now()
  from ranked r
  where r.id = s.id;

  update public.territories
  set archived_at = now()
  where season_id = p_season_id and archived_at is null;
  get diagnostics v_territories = row_count;

  update public.seasons
  set status = 'archived', archived_at = now()
  where id = p_season_id;

  select count(*) into v_scores
  from public.season_scores
  where season_id = p_season_id;

  return jsonb_build_object(
    'status', 'archived',
    'season_id', p_season_id,
    'territories_archived', v_territories,
    'scores', v_scores
  );
end;
$$;

revoke all on function public.archive_season(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.archive_season(uuid) to service_role';
  end if;
end;
$$;

create or replace function public.ensure_active_season()
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_expired uuid;
  v_weeks numeric;
begin
  -- Один активный сезон на всю игру; блокировка защищает от гонки забегов.
  perform pg_advisory_xact_lock(hashtext('runwave.active_season'));

  select id into v_id
  from public.seasons
  where status = 'active' and now() >= starts_at and now() < ends_at
  order by number desc
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  -- Завершившиеся сезоны архивируем, затем открываем следующий.
  for v_expired in
    select id from public.seasons where status = 'active' and now() >= ends_at
  loop
    perform public.archive_season(v_expired);
  end loop;

  select id into v_id
  from public.seasons
  where status = 'active' and now() < ends_at
  order by number desc
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  v_weeks := coalesce(public.config_num('season_weeks'), 4);

  insert into public.seasons (number, starts_at, ends_at, status)
  values (
    coalesce((select max(number) from public.seasons), 0) + 1,
    now(),
    now() + make_interval(days => (v_weeks * 7)::integer),
    'active'
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.ensure_active_season() from public;

-- ——— Домашняя зона ———

create or replace function public.set_home_zone(
  p_lon double precision,
  p_lat double precision,
  p_radius_m double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_radius double precision;
  v_center geometry;
begin
  if v_user is null then
    raise exception 'Требуется авторизация' using errcode = '28000';
  end if;

  if p_lon is null or p_lat is null
     or p_lon < -180 or p_lon > 180
     or p_lat < -85.0511 or p_lat > 85.0511 then
    raise exception 'Некорректные координаты домашней зоны' using errcode = '22023';
  end if;

  v_radius := coalesce(p_radius_m, public.config_num('home_zone_radius_m'), 300);
  if v_radius < 50 or v_radius > 2000 then
    raise exception 'Радиус домашней зоны должен быть от 50 до 2000 м' using errcode = '22023';
  end if;

  v_center := st_setsrid(st_makepoint(p_lon, p_lat), 4326);

  insert into public.home_zones (user_id, center, radius_m, area)
  values (
    v_user,
    v_center,
    v_radius,
    st_buffer(v_center::geography, v_radius)::geometry
  )
  on conflict (user_id) do update
  set center = excluded.center,
      radius_m = excluded.radius_m,
      area = excluded.area,
      updated_at = now();

  return jsonb_build_object(
    'center', st_asgeojson(v_center)::jsonb,
    'radius_m', v_radius
  );
end;
$$;

revoke all on function public.set_home_zone(double precision, double precision, double precision) from public;
grant execute on function public.set_home_zone(double precision, double precision, double precision) to authenticated;

-- ——— Приём забега ———

create or replace function public.submit_run(
  p_points jsonb,
  p_rings jsonb default '[]'::jsonb
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
  v_count integer;
  v_i integer;
  v_pt jsonb;
  v_lon double precision;
  v_lat double precision;
  v_t double precision;
  v_prev_t double precision;
  v_prev_lon double precision;
  v_prev_lat double precision;
  v_acc double precision;
  v_dist double precision;
  v_dt double precision;
  v_total_dist double precision := 0;
  v_first_t double precision;
  v_last_t double precision;
  v_duration double precision := 0;
  v_points geometry[] := array[]::geometry[];
  v_track geometry;
  v_start geometry;
  v_end geometry;
  v_loop_dist double precision;
  v_ring geometry;
  v_poly geometry;
  v_rings jsonb;
  v_ring_index integer;
  v_ring_count integer;
  v_ring_point jsonb;
  v_ring_lon double precision;
  v_ring_lat double precision;
  v_ring_vertices geometry[];
  v_ring_line geometry;
  v_ring_geom geometry;
  v_rings_geom geometry;
  v_ring_ok boolean;
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
  v_reason text;
  v_prev_owner uuid;
  v_rec record;
  v_protected_until timestamptz;
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
begin
  if v_user is null then
    raise exception 'Требуется авторизация' using errcode = '28000';
  end if;

  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    raise exception 'p_points должен быть JSON-массивом' using errcode = '22023';
  end if;

  insert into public.profiles (user_id)
  values (v_user)
  on conflict (user_id) do nothing;

  v_season := public.ensure_active_season();

  v_max_speed := coalesce(public.config_num('max_speed_mps'), 7);
  v_max_acc := coalesce(public.config_num('max_accuracy_m'), 25);
  v_max_jump := coalesce(public.config_num('max_jump_m'), 500);
  v_max_points := coalesce(public.config_num('max_run_points'), 10000)::integer;

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

      if jsonb_typeof(v_pt) <> 'object' then
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

        v_total_dist := v_total_dist + v_dist;

        if v_dist > v_max_jump then
          v_reason := 'jump';
          exit;
        end if;

        if v_dt <= 0 then
          v_reason := 'timestamps';
          exit;
        end if;

        if v_dist / v_dt > v_max_speed then
          v_reason := 'speed';
          exit;
        end if;
      end if;

      v_points := v_points || st_setsrid(st_makepoint(v_lon, v_lat), 4326);
      v_prev_lon := v_lon;
      v_prev_lat := v_lat;
      v_prev_t := v_t;
      v_last_t := v_t;
    end loop;
  end if;

  if v_reason is not null then
    insert into public.runs (
      user_id, season_id, started_at, finished_at, distance_m, duration_s,
      raw_points, status, rejection_reason
    ) values (
      v_user,
      v_season,
      coalesce(to_timestamp(v_first_t / 1000.0), now()),
      coalesce(
        to_timestamp(v_last_t / 1000.0),
        to_timestamp(v_first_t / 1000.0),
        now()
      ),
      0,
      0,
      p_points,
      'rejected',
      v_reason
    )
    returning id into v_run_id;

    return jsonb_build_object(
      'status', 'rejected',
      'reason', v_reason,
      'run_id', v_run_id,
      'season_id', v_season
    );
  end if;

  v_track := st_setsrid(st_makeline(v_points), 4326);
  v_total_dist := st_length(v_track::geography);
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
    where d.city_id = v_city and st_intersects(d.geom, v_start)
    order by st_area(d.geom::geography) asc
    limit 1;
  end if;

  v_distance_bonus := coalesce(public.config_num('distance_bonus_per_meter'), 2);
  v_points_award := round(v_total_dist * v_distance_bonus)::integer;

  insert into public.runs (
    user_id, season_id, city_id, district_id, started_at, finished_at,
    distance_m, duration_s, track, raw_points, status, points_awarded
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
    v_points_award
  )
  returning id into v_run_id;

  v_loop_radius := coalesce(public.config_num('loop_close_radius_m'), 15);
  v_min_area := coalesce(public.config_num('min_area_m2'), 500);
  v_min_perimeter := coalesce(public.config_num('min_perimeter_m'), 40);
  v_min_gain := coalesce(public.config_num('min_gain_m2'), 1);
  v_points_per_m2 := coalesce(public.config_num('points_per_m2'), 1);
  v_stolen_multiplier := coalesce(public.config_num('stolen_points_multiplier'), 2);
  v_protection_hours := coalesce(public.config_num('protection_hours'), 12);

  v_loop_dist := st_distance(v_start::geography, v_end::geography);

  v_poly := null;

  -- Клиент присылает замкнутые контуры захватов (p_rings). Проверяем, что
  -- каждая вершина лежит рядом с треком, и объединяем контуры в одну претензию.
  if p_rings is not null
     and jsonb_typeof(p_rings) = 'array'
     and jsonb_array_length(p_rings) > 0 then
    for v_ring_index in 0 .. jsonb_array_length(p_rings) - 1 loop
      v_rings := p_rings -> v_ring_index;

      if jsonb_typeof(v_rings) <> 'array' then
        continue;
      end if;

      v_ring_count := jsonb_array_length(v_rings);
      if v_ring_count < 3 or v_ring_count > 2000 then
        continue;
      end if;

      v_ring_vertices := array[]::geometry[];
      v_ring_ok := true;

      for v_i in 0 .. v_ring_count - 1 loop
        v_ring_point := v_rings -> v_i;

        if jsonb_typeof(v_ring_point) <> 'array'
           or jsonb_array_length(v_ring_point) < 2 then
          v_ring_ok := false;
          exit;
        end if;

        if jsonb_typeof(v_ring_point -> 0) is distinct from 'number'
           or jsonb_typeof(v_ring_point -> 1) is distinct from 'number' then
          v_ring_ok := false;
          exit;
        end if;

        v_ring_lon := (v_ring_point ->> 0)::double precision;
        v_ring_lat := (v_ring_point ->> 1)::double precision;

        if v_ring_lon < -180 or v_ring_lon > 180
           or v_ring_lat < -85.0511 or v_ring_lat > 85.0511 then
          v_ring_ok := false;
          exit;
        end if;

        v_ring_geom := st_setsrid(st_makepoint(v_ring_lon, v_ring_lat), 4326);

        -- Вершина контура должна быть на треке (допуск 5 м).
        if not st_dwithin(v_track::geography, v_ring_geom::geography, 5) then
          v_ring_ok := false;
          exit;
        end if;

        v_ring_vertices := v_ring_vertices || v_ring_geom;
      end loop;

      if not v_ring_ok or coalesce(array_length(v_ring_vertices, 1), 0) < 3 then
        continue;
      end if;

      v_ring_line := st_makeline(v_ring_vertices);

      if not st_equals(st_startpoint(v_ring_line), st_endpoint(v_ring_line)) then
        v_ring_line := st_addpoint(v_ring_line, st_startpoint(v_ring_line));
      end if;

      v_ring_geom := st_makevalid(st_makepolygon(v_ring_line));
      v_ring_geom := st_multi(st_collectionextract(v_ring_geom, 3));

      if v_ring_geom is not null and not st_isempty(v_ring_geom) then
        v_rings_geom := case
          when v_rings_geom is null then v_ring_geom
          else st_union(v_rings_geom, v_ring_geom)
        end;
      end if;
    end loop;

    if v_rings_geom is not null then
      v_rings_geom := st_multi(st_collectionextract(st_makevalid(v_rings_geom), 3));
    end if;
  end if;

  if v_rings_geom is not null and not st_isempty(v_rings_geom) then
    v_poly := v_rings_geom;
  elsif v_count >= 3 and v_loop_dist <= v_loop_radius then
    if st_equals(v_start, v_end) then
      v_ring := v_track;
    else
      v_ring := st_addpoint(v_track, v_start);
    end if;

    v_poly := st_makevalid(st_makepolygon(v_ring));
    v_poly := st_multi(st_collectionextract(v_poly, 3));
  end if;

  if v_poly is not null
     and not st_isempty(v_poly)
     and st_area(v_poly::geography) >= v_min_area
     and st_perimeter(v_poly::geography) >= v_min_perimeter then
    v_claim := v_poly;

      -- Территории внутри чужой домашней зоны не отдаются.
      select st_union(hz.area) into v_forbidden
      from public.home_zones hz
      where hz.user_id <> v_user;

      if v_forbidden is not null and not st_isempty(v_forbidden) then
        v_claim := st_makevalid(st_difference(v_claim, v_forbidden));
        v_claim := st_multi(st_collectionextract(v_claim, 3));
      end if;

      if v_claim is not null and not st_isempty(v_claim) then
        select st_union(t.geom) into v_own
        from public.territories t
        where t.owner_id = v_user
          and t.season_id = v_season
          and t.archived_at is null;

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
            v_points_award := round(
              v_area_new * v_points_per_m2
              + v_area_stolen * v_points_per_m2 * v_stolen_multiplier
              + v_total_dist * v_distance_bonus
            )::integer;

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

  return jsonb_build_object(
    'status', 'accepted',
    'run_id', v_run_id,
    'season_id', v_season,
    'city_id', v_city,
    'district_id', v_district,
    'distance_m', round(v_total_dist::numeric, 1),
    'duration_s', round(v_duration::numeric, 1),
    'points_awarded', v_points_award,
    'area_m2', round(v_area_capture::numeric, 1),
    'stolen_area_m2', round(v_area_stolen::numeric, 1),
    'territory_id', v_territory_id,
    'protected_until', v_protected_until
  );
end;
$$;

revoke all on function public.submit_run(jsonb, jsonb) from public;
grant execute on function public.submit_run(jsonb, jsonb) to authenticated;

-- ——— Запросы для карты и рейтинга ———

create or replace function public.territories_in_bbox(
  p_west double precision,
  p_south double precision,
  p_east double precision,
  p_north double precision
)
returns table (
  id uuid,
  owner_id uuid,
  season_id uuid,
  city_id uuid,
  district_id uuid,
  geom geometry,
  area_m2 double precision,
  captured_at timestamptz,
  protected_until timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    t.id,
    t.owner_id,
    t.season_id,
    t.city_id,
    t.district_id,
    t.geom,
    t.area_m2,
    t.captured_at,
    t.protected_until
  from public.territories t
  where t.archived_at is null
    and st_intersects(
      t.geom,
      st_makeenvelope(p_west, p_south, p_east, p_north, 4326)
    );
$$;

revoke all on function public.territories_in_bbox(double precision, double precision, double precision, double precision) from public;
grant execute on function public.territories_in_bbox(double precision, double precision, double precision, double precision) to authenticated;

create or replace function public.season_leaderboard(
  p_city_id uuid default null,
  p_district_id uuid default null,
  p_limit integer default 50
)
returns table (
  rank bigint,
  user_id uuid,
  display_name text,
  points integer,
  distance_m double precision,
  area_m2 double precision,
  runs_count integer
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with active as (
    select s.id
    from public.seasons s
    where s.status = 'active'
      and now() >= s.starts_at
      and now() < s.ends_at
    order by s.number desc
    limit 1
  ),
  totals as (
    select
      ss.user_id,
      sum(ss.points)::integer as points,
      sum(ss.distance_m) as distance_m,
      sum(ss.area_m2) as area_m2,
      sum(ss.runs_count)::integer as runs_count,
      max(ss.updated_at) as updated_at
    from public.season_scores ss
    join active a on a.id = ss.season_id
    where (p_city_id is null or ss.city_id = p_city_id)
      and (p_district_id is null or ss.district_id = p_district_id)
    group by ss.user_id
  )
  select
    row_number() over (order by t.points desc, t.updated_at asc) as rank,
    t.user_id,
    p.display_name,
    t.points,
    t.distance_m,
    t.area_m2,
    t.runs_count
  from totals t
  join public.profiles p on p.user_id = t.user_id
  order by t.points desc, t.updated_at asc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

revoke all on function public.season_leaderboard(uuid, uuid, integer) from public;
grant execute on function public.season_leaderboard(uuid, uuid, integer) to authenticated;
