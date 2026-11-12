# Runwave — серверная часть

SQL-миграции мультиплеерной игры захвата территорий: PostgreSQL 15+ и PostGIS 3.x,
Supabase Auth (`auth.users`, `auth.uid()`) и RLS. Специфичных для Supabase API
функций нет — всё работает и на self-hosted Supabase.

## Применение

На Supabase (managed или self-hosted) миграции применяются как обычно:

```bash
supabase db push
# или вручную, по порядку:
psql "$DATABASE_URL" -f supabase/migrations/0001_schema.sql
psql "$DATABASE_URL" -f supabase/migrations/0002_rls.sql
psql "$DATABASE_URL" -f supabase/migrations/0003_functions.sql
```

`auth.users` и `auth.uid()` уже есть в Supabase. Для локальных тестов на обычном
PostgreSQL используется заглушка `supabase/tests/00_auth_stub.sql` — на Supabase
её применять не нужно.

## Основные RPC

```sql
-- Забег: массив точек {lon, lat, t (epoch ms), accuracy}
select public.submit_run('[
  {"lon": 37.60, "lat": 55.75, "t": 1700000000000, "accuracy": 5}
]'::jsonb);

-- Домашняя зона (по умолчанию 300 м из game_config)
select public.set_home_zone(37.60, 55.75, 300);

-- Территории в bbox карты
select * from public.territories_in_bbox(37.55, 55.70, 37.65, 55.80);

-- Рейтинг сезона по городу/району
select * from public.season_leaderboard('city-uuid', null, 50);
```

Правила и числа (защита 12 ч, сезон 4 недели, скорость 7 м/с, точность 25 м,
очки за м², множитель за отнятую землю, бонус за дистанцию, радиус зоны и т. д.)
лежат в `public.game_config` и читаются функциями. Прямая запись в игровые
таблицы через RLS закрыта: территории, забеги, очки и историю меняют только
`submit_run` и `archive_season`. Игрок может напрямую писать только свой профиль
и свою домашнюю зону.

Закрытие сезона (только `service_role`):

```sql
select public.archive_season('season-uuid');
```

## Тесты

Нужен локальный PostgreSQL 15+ с установленным PostGIS.

```bash
createdb runwave
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/tests/00_auth_stub.sql
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/migrations/0001_schema.sql
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/migrations/0002_rls.sql
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/migrations/0003_functions.sql
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/tests/game_test.sql
```

Сценарии проверяют захват, защиту, перехват, частичное наложение, скрытую зону
(включая RLS), отклонение скачков и плохой точности, архивирование сезона,
bbox и рейтинг. Тесты выполняются в одной транзакции и откатываются.
