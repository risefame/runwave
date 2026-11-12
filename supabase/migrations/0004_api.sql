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
