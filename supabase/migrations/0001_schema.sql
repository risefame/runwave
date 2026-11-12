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
