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
