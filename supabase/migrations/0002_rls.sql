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
