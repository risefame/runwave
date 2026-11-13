-- Runwave: полная установка базы для Supabase.
-- Вставьте этот файл целиком в SQL Editor и нажмите Run (один раз).
-- Составлено из supabase/migrations/*.sql и supabase/seed.sql.
-- Повторный запуск на уже настроенной базе не нужен.

-- ===== migrations/0001_schema.sql =====
-- Runwave: схема мультиплеерной игры захвата территорий.
-- Требования: PostgreSQL 15+, PostGIS 3.x.
-- Переносимо между Supabase (включая self-hosted) и обычным PostgreSQL:
-- используется только стандартный SQL, PostGIS, auth.users и RLS.

create schema if not exists extensions;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'postgis') then
    execute 'create extension postgis with schema extensions';
  end if;
end;
$$;

set search_path = public, extensions;

-- ——— Общее ———

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_updated_at() from public;

-- ——— Конфигурация игры ———

create table if not exists public.game_config (
  key text primary key,
  value numeric not null,
  description text not null default '',
  updated_at timestamptz not null default now()
);

insert into public.game_config (key, value, description) values
  ('protection_hours', 12, 'Сколько часов новая территория защищена от перехвата'),
  ('season_weeks', 4, 'Длительность сезона в неделях'),
  ('max_speed_mps', 7, 'Максимальная допустимая скорость между точками трека, м/с'),
  ('max_accuracy_m', 25, 'Максимальная допустимая точность GPS, м'),
  ('max_jump_m', 500, 'Максимальный скачок между соседними точками, м'),
  ('max_run_points', 10000, 'Максимум точек в одном забеге'),
  ('min_area_m2', 500, 'Минимальная площадь засчитываемой территории, м²'),
  ('min_perimeter_m', 40, 'Минимальный периметр территории, м'),
  ('min_gain_m2', 1, 'Минимальный прирост площади, м²'),
  ('loop_close_radius_m', 15, 'Радиус замыкания трека в петлю, м'),
  ('points_per_m2', 1, 'Очков за квадратный метр новой земли'),
  ('stolen_points_multiplier', 2, 'Множитель очков за землю, отнятую у соперника'),
  ('distance_bonus_per_meter', 2, 'Очков за метр дистанции'),
  ('home_zone_radius_m', 300, 'Радиус скрытой домашней зоны по умолчанию, м')
on conflict (key) do nothing;

-- ——— Города и районы ———

create table if not exists public.cities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  geom geometry(MultiPolygon, 4326) not null,
  created_at timestamptz not null default now(),
  constraint cities_geom_srid check (st_srid(geom) = 4326),
  constraint cities_geom_valid check (st_isvalid(geom))
);

create index if not exists cities_geom_gix on public.cities using gist (geom);

create table if not exists public.districts (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id) on delete cascade,
  name text not null,
  geom geometry(MultiPolygon, 4326) not null,
  created_at timestamptz not null default now(),
  constraint districts_geom_srid check (st_srid(geom) = 4326),
  constraint districts_geom_valid check (st_isvalid(geom))
);

create index if not exists districts_geom_gix on public.districts using gist (geom);
create index if not exists districts_city_idx on public.districts (city_id);

-- ——— Профили ———

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Игрок',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_len check (char_length(display_name) between 1 and 40)
);

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- ——— Скрытая домашняя зона ———

create table if not exists public.home_zones (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  center geometry(Point, 4326) not null,
  radius_m double precision not null,
  area geometry(Polygon, 4326) not null,
  updated_at timestamptz not null default now(),
  constraint home_zones_radius_range check (radius_m between 50 and 2000),
  constraint home_zones_center_srid check (st_srid(center) = 4326),
  constraint home_zones_area_srid check (st_srid(area) = 4326),
  constraint home_zones_area_valid check (st_isvalid(area))
);

create index if not exists home_zones_area_gix on public.home_zones using gist (area);
create index if not exists home_zones_center_gix on public.home_zones using gist (center);

-- Площадь зоны всегда пересчитывается из центра и радиуса.
create or replace function public.sync_home_zone()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  new.center := st_setsrid(new.center, 4326);
  new.area := st_buffer(new.center::geography, new.radius_m)::geometry;
  new.updated_at := now();
  return new;
end;
$$;

create trigger home_zones_sync_area
before insert or update on public.home_zones
for each row execute function public.sync_home_zone();

revoke all on function public.sync_home_zone() from public;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  v_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    nullif(new.raw_user_meta_data ->> 'username', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Игрок'
  );
  insert into public.profiles (user_id, display_name)
  values (new.id, left(v_name, 40))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public;

do $$
begin
  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'auth' and c.relname = 'users'
  ) then
    execute 'drop trigger if exists on_auth_user_created on auth.users';
    begin
      execute 'create trigger on_auth_user_created after insert on auth.users
               for each row execute function public.handle_new_user()';
    exception
      when insufficient_privilege then
        raise warning 'Не удалось создать триггер на auth.users: профиль будет создан при первом submit_run';
    end;
  end if;
end;
$$;

-- ——— Сезоны ———

create table if not exists public.seasons (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint seasons_status_check check (status in ('pending', 'active', 'archived')),
  constraint seasons_dates_check check (ends_at > starts_at)
);

-- В один момент времени активен только один сезон.
create unique index if not exists seasons_single_active_idx
  on public.seasons (status)
  where status = 'active';

-- ——— Забеги ———

create table if not exists public.runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  season_id uuid references public.seasons(id) on delete set null,
  city_id uuid references public.cities(id) on delete set null,
  district_id uuid references public.districts(id) on delete set null,
  started_at timestamptz not null,
  finished_at timestamptz not null,
  distance_m double precision not null default 0,
  duration_s double precision not null default 0,
  track geometry(LineString, 4326),
  raw_points jsonb not null default '[]'::jsonb,
  status text not null default 'accepted',
  rejection_reason text,
  points_awarded integer not null default 0,
  area_m2 double precision not null default 0,
  stolen_area_m2 double precision not null default 0,
  territory_id uuid,
  created_at timestamptz not null default now(),
  constraint runs_status_check check (status in ('accepted', 'rejected')),
  constraint runs_raw_points_array check (jsonb_typeof(raw_points) = 'array'),
  constraint runs_track_srid check (track is null or st_srid(track) = 4326)
);

create index if not exists runs_user_time_idx on public.runs (user_id, started_at desc);
create index if not exists runs_season_idx on public.runs (season_id);
create index if not exists runs_city_idx on public.runs (city_id);
create index if not exists runs_track_gix on public.runs using gist (track);

-- ——— Территории ———

create table if not exists public.territories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(user_id) on delete cascade,
  season_id uuid not null references public.seasons(id) on delete cascade,
  city_id uuid references public.cities(id) on delete set null,
  district_id uuid references public.districts(id) on delete set null,
  geom geometry(MultiPolygon, 4326) not null,
  area_m2 double precision not null,
  captured_at timestamptz not null default now(),
  protected_until timestamptz not null,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint territories_area_positive check (area_m2 > 0),
  constraint territories_geom_srid check (st_srid(geom) = 4326),
  constraint territories_geom_valid check (st_isvalid(geom)),
  constraint territories_protection_check check (protected_until >= captured_at)
);

create index if not exists territories_geom_gix
  on public.territories using gist (geom)
  where archived_at is null;
create index if not exists territories_owner_season_idx
  on public.territories (owner_id, season_id)
  where archived_at is null;
create index if not exists territories_season_idx on public.territories (season_id);

create trigger territories_set_updated_at
before update on public.territories
for each row execute function public.set_updated_at();

alter table public.runs
  add constraint runs_territory_fk
  foreign key (territory_id) references public.territories(id) on delete set null;

-- ——— История захватов ———

create table if not exists public.capture_history (
  id bigint generated always as identity primary key,
  season_id uuid not null references public.seasons(id) on delete cascade,
  run_id uuid references public.runs(id) on delete set null,
  territory_id uuid references public.territories(id) on delete set null,
  actor_id uuid references public.profiles(user_id) on delete set null,
  previous_owner_id uuid references public.profiles(user_id) on delete set null,
  action text not null,
  geom geometry(MultiPolygon, 4326) not null,
  area_new_m2 double precision not null default 0,
  area_stolen_m2 double precision not null default 0,
  points integer not null default 0,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint capture_history_action_check check (action in ('claim', 'steal', 'merge')),
  constraint capture_history_geom_srid check (st_srid(geom) = 4326)
);

create index if not exists capture_history_geom_gix on public.capture_history using gist (geom);
create index if not exists capture_history_season_idx on public.capture_history (season_id, created_at desc);
create index if not exists capture_history_actor_idx on public.capture_history (actor_id, created_at desc);
create index if not exists capture_history_territory_idx on public.capture_history (territory_id);

-- ——— Очки по сезонам ———

-- Строка на пару (сезон, игрок, город, район): рейтинг считается отдельно
-- по городу и по району. NULLS NOT DISTINCT требует PostgreSQL 15+.
create table if not exists public.season_scores (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  city_id uuid references public.cities(id) on delete set null,
  district_id uuid references public.districts(id) on delete set null,
  points integer not null default 0,
  distance_m double precision not null default 0,
  area_m2 double precision not null default 0,
  runs_count integer not null default 0,
  rank integer,
  trophies integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint season_scores_unique
    unique nulls not distinct (season_id, user_id, city_id, district_id)
);

create index if not exists season_scores_rating_idx
  on public.season_scores (season_id, city_id, points desc);

-- ===== migrations/0002_rls.sql =====
-- RLS и права доступа.
-- Чтение: игроки видят чужие территории, кроме участков внутри чужой
-- скрытой домашней зоны. Запись: напрямую — только свои профиль и домашняя
-- зона; игровые таблицы (территории, забеги, очки, история) меняются только
-- через security-definer функции submit_run/archive_season.

set search_path = public, extensions;

-- Территория видна, если она своя, либо не архивная и не попадает
-- в скрытую зону другого игрока. Функция security definer, потому что
-- home_zones закрыта RLS и политика не смогла бы её прочитать.
create or replace function public.can_read_territory(
  p_owner_id uuid,
  p_geom geometry,
  p_archived_at timestamptz
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null then
    return false;
  end if;
  if p_owner_id = auth.uid() then
    return true;
  end if;
  if p_archived_at is not null then
    return false;
  end if;
  return not exists (
    select 1
    from public.home_zones hz
    where hz.user_id <> auth.uid()
      and st_intersects(p_geom, hz.area)
  );
end;
$$;

revoke all on function public.can_read_territory(uuid, geometry, timestamptz) from public;
grant execute on function public.can_read_territory(uuid, geometry, timestamptz) to authenticated;

alter table public.profiles enable row level security;
alter table public.home_zones enable row level security;
alter table public.cities enable row level security;
alter table public.districts enable row level security;
alter table public.seasons enable row level security;
alter table public.runs enable row level security;
alter table public.territories enable row level security;
alter table public.capture_history enable row level security;
alter table public.season_scores enable row level security;
alter table public.game_config enable row level security;

-- ——— Профили ———

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (true);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ——— Скрытая домашняя зона: только своя ———

drop policy if exists home_zones_select_own on public.home_zones;
create policy home_zones_select_own on public.home_zones
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists home_zones_insert_own on public.home_zones;
create policy home_zones_insert_own on public.home_zones
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists home_zones_update_own on public.home_zones;
create policy home_zones_update_own on public.home_zones
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists home_zones_delete_own on public.home_zones;
create policy home_zones_delete_own on public.home_zones
  for delete to authenticated
  using (user_id = auth.uid());

-- ——— Справочники и сезоны: чтение всем авторизованным ———

drop policy if exists cities_select on public.cities;
create policy cities_select on public.cities
  for select to authenticated using (true);

drop policy if exists districts_select on public.districts;
create policy districts_select on public.districts
  for select to authenticated using (true);

drop policy if exists seasons_select on public.seasons;
create policy seasons_select on public.seasons
  for select to authenticated using (true);

drop policy if exists game_config_select on public.game_config;
create policy game_config_select on public.game_config
  for select to authenticated using (true);

-- ——— Забеги: только свои ———

drop policy if exists runs_select_own on public.runs;
create policy runs_select_own on public.runs
  for select to authenticated
  using (user_id = auth.uid());

-- ——— Территории ———

drop policy if exists territories_select on public.territories;
create policy territories_select on public.territories
  for select to authenticated
  using (public.can_read_territory(owner_id, geom, archived_at));

-- ——— История захватов: свои действия и потеря своей земли ———

drop policy if exists capture_history_select_own on public.capture_history;
create policy capture_history_select_own on public.capture_history
  for select to authenticated
  using (actor_id = auth.uid() or previous_owner_id = auth.uid());

-- ——— Очки сезона: рейтинг публичный ———

drop policy if exists season_scores_select on public.season_scores;
create policy season_scores_select on public.season_scores
  for select to authenticated using (true);

-- ——— Права ———

grant usage on schema public to authenticated;
grant usage on schema extensions to authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.home_zones to authenticated;
grant select on public.cities, public.districts, public.seasons, public.game_config to authenticated;
grant select on public.runs, public.territories, public.capture_history, public.season_scores to authenticated;

-- ===== migrations/0003_functions.sql =====
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

-- ===== migrations/0004_api.sql =====
-- API-обёртки для веб-клиента: GeoJSON для карты и город по точке.
-- Применяется после 0003_functions.sql.

set search_path = public, extensions;

create or replace function public.territories_bbox_geojson(
  p_west double precision,
  p_south double precision,
  p_east double precision,
  p_north double precision
)
returns table (
  id uuid,
  owner_id uuid,
  area_m2 double precision,
  captured_at timestamptz,
  protected_until timestamptz,
  geojson jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    t.id,
    t.owner_id,
    t.area_m2,
    t.captured_at,
    t.protected_until,
    st_asgeojson(t.geom)::jsonb
  from public.territories t
  where t.archived_at is null
    and st_intersects(
      t.geom,
      st_makeenvelope(p_west, p_south, p_east, p_north, 4326)
    )
  order by t.area_m2 desc
  limit 2000;
$$;

revoke all on function public.territories_bbox_geojson(
  double precision, double precision, double precision, double precision
) from public;
grant execute on function public.territories_bbox_geojson(
  double precision, double precision, double precision, double precision
) to authenticated;

create or replace function public.city_at_point(
  p_lon double precision,
  p_lat double precision
)
returns table (
  city_id uuid,
  city_name text,
  district_id uuid,
  district_name text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with pt as (
    select st_setsrid(st_makepoint(p_lon, p_lat), 4326) as geom
  ),
  city as (
    select c.id, c.name
    from public.cities c, pt
    where st_intersects(c.geom, pt.geom)
    order by st_area(c.geom::geography) asc
    limit 1
  )
  select
    city.id,
    city.name,
    d.id,
    d.name
  from city
  left join lateral (
    select d.id, d.name
    from public.districts d, pt
    where d.city_id = city.id
      and st_intersects(d.geom, pt.geom)
    order by st_area(d.geom::geography) asc
    limit 1
  ) d on true;
$$;

revoke all on function public.city_at_point(double precision, double precision) from public;
grant execute on function public.city_at_point(double precision, double precision) to authenticated;


-- ===== migrations/0005_run_security.sql =====
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

-- ===== migrations/0006_boundary_arc.sql =====
-- Runwave 0006: захват дугой от границы своей территории (механика Paper.io).
-- Применять после 0005_run_security.sql.
--
-- 0005 контуры, у которых вершина лежит на границе своей территории, помечал
-- ring_boundary_arc и не засчитывал. Клиент такие захваты делает давно
-- (web/src/territory.ts → findBoundaryClosure): игрок выходит из своей
-- территории, обегает участок снаружи и возвращается к границе; область
-- замыкается дугой трека и участком границы между выходом и входом.
-- Из-за этого онлайн-территория расходилась с тем, что видит игрок.
--
-- Что делает 0006:
--   1. public.boundary_arc_claim — строит полигон дуги на сервере: дуга берётся
--      из трека (ST_Difference с уже своей территорией), замыкается участком
--      своей границы (ST_LineSubstring между проекциями концов), сторона
--      выбирается по клиентским правилам (меньше наложений на свою
--      территорию, при равенстве — меньшая площадь), полигон ST_MakeValid,
--      затем ST_Difference со своей территорией: в захват идёт только новая
--      площадь;
--   2. public.check_run_ring переопределяется: вершины контура по-прежнему
--      должны быть точками трека, но вершина на границе своей территории
--      больше не отбрасывается — контур уходит в boundary_arc_claim;
--   3. параметры клиента переезжают в game_config (min_arc_length_m).
--
-- submit_run_v2 из 0005 не меняется: он вызывает check_run_ring и дальше
-- применяет те же правила, что и для обычных захватов, — минимальные площадь,
-- периметр и прирост, правдоподобие площади, снятие защиты protected_until,
-- очки только за новую часть и двойные за отнятое, идемпотентность по
-- client_run_id, сохранение отказов с reason_code.

set search_path = public, extensions;

-- ——— 1. Новые параметры игры ———

insert into public.game_config (key, value, description) values
  ('min_arc_length_m', 20, 'Минимальная длина дуги, замыкающей захват от своей границы, м')
on conflict (key) do nothing;

-- ——— 2. Замыкание дуги участком своей границы ———

-- Строит захват по дуге трека. p_first — первая вершина контура клиента:
-- по ней выбирается нужный выход за границу, если за забег их было несколько.
--
-- Условия (те же, что в web/src/territory.ts):
--   - дуга — участок трека вне своей территории, который начался и закончился
--     на её границе (оба конца ближе p_boundary_tolerance к границе);
--   - длина дуги не меньше min_arc_length_m (отсекает шум GPS у границы);
--   - выход и вход не в одной точке;
--   - из двух направлений по границе берётся то, которое не пересекает уже
--     свою территорию и меньше по площади;
--   - площадь и периметр полигона — как у обычного захвата, площадь
--     правдоподобна для длины дуги;
--   - в результат идёт только площадь, которой у игрока ещё не было.
--
-- issue — почему контур не засчитан: ring_boundary_arc (нет дуги, дуга короткая,
-- концы в одной точке, концы на разных кусках границы, полигон не собрался,
-- прирост меньше min_gain_m2) или area_implausible.
create or replace function public.boundary_arc_claim(
  p_first geometry,
  p_track geometry,
  p_own geometry,
  p_boundary_tolerance double precision,
  out claim geometry,
  out issue text
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_min_arc_length double precision :=
    greatest(coalesce(public.config_num('min_arc_length_m'), 20), 1);
  v_min_area double precision := coalesce(public.config_num('min_area_m2'), 500);
  v_min_perimeter double precision := coalesce(public.config_num('min_perimeter_m'), 40);
  v_min_gain double precision := coalesce(public.config_num('min_gain_m2'), 1);
  v_area_tolerance double precision := coalesce(public.config_num('area_tolerance'), 1.05);
  -- Наложение на свою территорию до этой площади — касание границы, м².
  v_overlap_tolerance double precision := 1;
  -- Ближе этого концы дуги считаются одной точкой, м.
  v_same_point_tolerance double precision := 1.5;
  v_boundary geometry;
  v_out geometry;
  v_part geometry;
  v_arc geometry;
  v_arc_length double precision;
  v_exit geometry;
  v_entry geometry;
  v_best_dist double precision;
  v_dist double precision;
  v_best_part geometry;
  v_best_sum double precision;
  v_sum double precision;
  v_f_exit double precision;
  v_f_entry double precision;
  v_min_f double precision;
  v_max_f double precision;
  v_sides geometry[] := array[]::geometry[];
  v_side geometry;
  v_line geometry;
  v_poly geometry;
  v_best_poly geometry;
  v_area double precision;
  v_best_area double precision;
  v_overlap double precision;
  v_best_overlap double precision;
  v_clean boolean;
  v_best_clean boolean;
  v_fresh geometry;
  v_i integer;
begin
  claim := null;
  issue := null;

  if p_track is null or p_own is null or st_isempty(p_own) then
    issue := 'ring_boundary_arc';
    return;
  end if;

  v_boundary := st_boundary(p_own);

  -- Дуга: часть трека вне своей территории. ST_Difference режет трек ровно
  -- по границе, поэтому концы каждого куска лежат на ней.
  v_out := st_difference(p_track, p_own);

  if v_out is null or st_isempty(v_out) then
    issue := 'ring_boundary_arc';
    return;
  end if;

  -- Несколько выходов за забег: берём тот, что начинается (или заканчивается)
  -- у первой вершины контура клиента.
  for v_part in select (st_dump(v_out)).geom loop
    if v_part is null
       or st_isempty(v_part)
       or geometrytype(v_part) <> 'LINESTRING' then
      continue;
    end if;

    v_exit := st_startpoint(v_part);
    v_entry := st_endpoint(v_part);

    -- Кусок, который начался или закончился не у границы, — это не дуга:
    -- забег начался снаружи или закончился вне своей территории.
    if not st_dwithin(v_boundary::geography, v_exit::geography, p_boundary_tolerance)
       or not st_dwithin(v_boundary::geography, v_entry::geography, p_boundary_tolerance) then
      continue;
    end if;

    if st_length(v_part::geography) < v_min_arc_length then
      continue;
    end if;

    if st_distance(v_exit::geography, v_entry::geography) <= v_same_point_tolerance then
      continue;
    end if;

    v_dist := least(
      st_distance(v_exit::geography, p_first::geography),
      st_distance(v_entry::geography, p_first::geography)
    );

    if v_best_dist is null or v_dist < v_best_dist then
      v_best_dist := v_dist;
      v_arc := v_part;
    end if;
  end loop;

  if v_arc is null or v_best_dist is null or v_best_dist > p_boundary_tolerance then
    issue := 'ring_boundary_arc';
    return;
  end if;

  v_arc_length := st_length(v_arc::geography);
  v_exit := st_startpoint(v_arc);
  v_entry := st_endpoint(v_arc);

  -- Дуга должна начинаться и заканчиваться на одном куске границы: у
  -- MultiPolygon из нескольких частей проекции на разные куски не замыкаются
  -- одним участком границы (как и в клиенте, где сверяется ringIndex).
  for v_part in select (st_dump(v_boundary)).geom loop
    if v_part is null
       or st_isempty(v_part)
       or geometrytype(v_part) <> 'LINESTRING' then
      continue;
    end if;

    v_dist := st_distance(v_part::geography, v_exit::geography);
    v_sum := st_distance(v_part::geography, v_entry::geography);

    if v_dist > p_boundary_tolerance or v_sum > p_boundary_tolerance then
      continue;
    end if;

    if v_best_sum is null or v_dist + v_sum < v_best_sum then
      v_best_sum := v_dist + v_sum;
      v_best_part := v_part;
    end if;
  end loop;

  if v_best_part is null then
    issue := 'ring_boundary_arc';
    return;
  end if;

  v_f_exit := least(greatest(st_linelocatepoint(v_best_part, v_exit), 0), 1);
  v_f_entry := least(greatest(st_linelocatepoint(v_best_part, v_entry), 0), 1);
  v_min_f := least(v_f_exit, v_f_entry);
  v_max_f := greatest(v_f_exit, v_f_entry);

  if v_max_f <= v_min_f then
    issue := 'ring_boundary_arc';
    return;
  end if;

  -- Два пути по границе: короткий между проекциями концов и остальной.
  -- Участок границы всегда направляем от входа к выходу, чтобы линия дуги
  -- и границы замкнулась.
  v_sides := array_append(v_sides, st_linesubstring(v_best_part, v_min_f, v_max_f));

  if v_min_f > 0 and v_max_f < 1 then
    v_sides := array_append(
      v_sides,
      st_makeline(
        st_linesubstring(v_best_part, v_max_f, 1),
        st_linesubstring(v_best_part, 0, v_min_f)
      )
    );
  elsif v_max_f >= 1 then
    v_sides := array_append(v_sides, st_linesubstring(v_best_part, 0, v_min_f));
  else
    v_sides := array_append(v_sides, st_linesubstring(v_best_part, v_max_f, 1));
  end if;

  for v_i in 1 .. coalesce(array_length(v_sides, 1), 0) loop
    v_side := v_sides[v_i];

    if v_side is null or st_isempty(v_side) then
      continue;
    end if;

    if st_distance(st_startpoint(v_side)::geography, v_entry::geography)
       > st_distance(st_endpoint(v_side)::geography, v_entry::geography) then
      v_side := st_reverse(v_side);
    end if;

    v_line := st_makeline(v_arc, v_side);

    if not st_isclosed(v_line) then
      v_line := st_addpoint(v_line, st_startpoint(v_line));
    end if;

    begin
      v_poly := st_buildarea(v_line);
    exception
      when others then
        v_poly := null;
    end;

    if v_poly is not null and not st_isempty(v_poly) then
      v_poly := st_makevalid(v_poly);

      if geometrytype(v_poly) not in ('POLYGON', 'MULTIPOLYGON') then
        v_poly := st_collectionextract(v_poly, 3);
      end if;
    end if;

    if v_poly is null or st_isempty(v_poly) then
      continue;
    end if;

    v_area := st_area(v_poly::geography);

    if v_area is null or v_area <= 0 then
      continue;
    end if;

    v_overlap := coalesce(st_area(st_intersection(v_poly, p_own)::geography), 0);
    v_clean := v_overlap <= v_overlap_tolerance;

    if v_best_poly is null
       or (v_clean and not coalesce(v_best_clean, false))
       or (v_clean = coalesce(v_best_clean, false) and v_clean and v_area < v_best_area)
       or (v_clean = coalesce(v_best_clean, false) and not v_clean
           and v_overlap < v_best_overlap - v_overlap_tolerance) then
      v_best_poly := v_poly;
      v_best_area := v_area;
      v_best_overlap := v_overlap;
      v_best_clean := v_clean;
    end if;
  end loop;

  if v_best_poly is null then
    issue := 'ring_boundary_arc';
    return;
  end if;

  if v_best_area < v_min_area
     or st_perimeter(v_best_poly::geography) < v_min_perimeter then
    issue := 'ring_boundary_arc';
    return;
  end if;

  if not public.claim_plausible(v_best_poly, v_arc_length, v_area_tolerance) then
    issue := 'area_implausible';
    return;
  end if;

  -- Только новая площадь: граница своей территории и её внутренность в захват
  -- не идут (у клиента то же делает withoutOwned).
  v_fresh := st_makevalid(st_difference(v_best_poly, p_own));
  v_fresh := st_multi(st_collectionextract(v_fresh, 3));

  if v_fresh is null
     or st_isempty(v_fresh)
     or st_area(v_fresh::geography) < v_min_gain then
    issue := 'ring_boundary_arc';
    return;
  end if;

  claim := v_fresh;
end;
$$;

revoke all on function public.boundary_arc_claim(
  geometry, geometry, geometry, double precision
) from public;

-- ——— 3. Приём контура: дуга засчитывается ———

-- Отличия от версии 0005:
--   - вершина, не лежащая на треке, но лежащая на границе своей территории,
--     больше не даёт ring_boundary_arc: такой контур уходит в
--     public.boundary_arc_claim, который строит полигон сам;
--   - порядок вершин и замыкание проверяются только для обычных контуров:
--     у дуги вершины границы идут в обратную сторону и на трек не проецируются.
-- Остальные коды (ring_format, ring_off_track, ring_untracked,
-- ring_not_ordered, ring_not_closed, ring_degenerate) и допуски — как в 0005.
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
  v_has_boundary boolean := false;
  v_dist double precision;
  v_line geometry;
  v_poly geometry;
  v_arc_claim geometry;
  v_arc_issue text;
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

  -- Вершина контура — точка трека либо точка границы своей территории.
  -- Второе бывает только у замыкания дугой: такие вершины приходят из
  -- участка границы, которым клиент замкнул дугу.
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
      v_has_boundary := true;
      continue;
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

  -- Замыкание дугой: полигон строит сервер из трека и своей территории в базе.
  -- Вершины клиента геометрией не служат — из них берётся только точка выхода,
  -- по которой выбирается нужный выход за границу.
  if v_has_boundary then
    select c.claim, c.issue
    into v_arc_claim, v_arc_issue
    from public.boundary_arc_claim(
      v_first,
      p_track,
      p_own,
      p_boundary_tolerance
    ) c;

    claim := v_arc_claim;
    issue := v_arc_issue;
    return;
  end if;

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

-- ===== seed.sql =====
-- Стартовые данные для Москвы (тестовые прямоугольники).
-- Для продакшена замените geom на реальные границы города/районов
-- (GeoJSON из OSM/Nominatim, QGIS и т. п.).

set search_path = public, extensions;

insert into public.cities (name, geom)
select 'Москва', st_multi(st_makeenvelope(37.30, 55.50, 38.00, 56.00, 4326))
where not exists (
  select 1 from public.cities where name = 'Москва'
);

insert into public.districts (city_id, name, geom)
select
  c.id,
  'Тверской',
  st_multi(st_makeenvelope(37.50, 55.70, 37.75, 55.80, 4326))
from public.cities c
where c.name = 'Москва'
  and not exists (
    select 1
    from public.districts d
    where d.city_id = c.id and d.name = 'Тверской'
  );
