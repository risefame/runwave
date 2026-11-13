# Runwave — серверная часть

SQL-миграции мультиплеерной игры захвата территорий: PostgreSQL 15+ и PostGIS 3.x,
Supabase Auth (`auth.users`, `auth.uid()`) и RLS. Специфичных для Supabase API
функций нет — всё работает и на self-hosted Supabase.

## Быстрая установка

Для нового проекта Supabase проще всего открыть `SQL Editor`, вставить целиком
[`setup.sql`](./setup.sql) и нажать Run. Файл содержит миграции `0001–0006` и
стартовые города/районы (тестовые прямоугольники Москвы и Тверского).

Порядок применения важен: `0001` схема → `0002` RLS → `0003` функции →
`0004` запросы карты и рейтинга → `0005` защита забега → `0006` захват дугой
от своей границы. `0006` меняет только `public.check_run_ring` и добавляет
`public.boundary_arc_claim`, поэтому `0005` остаётся как есть и повторно
применять её не нужно.

В Supabase также нужно включить `Authentication → Providers → Anonymous sign-ins`.
Клиент использует публичный publishable key из `web/src/supabase.ts`.

## Применение

На Supabase (managed или self-hosted) миграции применяются как обычно:

```bash
supabase db push
# или вручную, по порядку:
psql "$DATABASE_URL" -f supabase/migrations/0001_schema.sql
psql "$DATABASE_URL" -f supabase/migrations/0002_rls.sql
psql "$DATABASE_URL" -f supabase/migrations/0003_functions.sql
psql "$DATABASE_URL" -f supabase/migrations/0004_api.sql
psql "$DATABASE_URL" -f supabase/migrations/0005_run_security.sql
psql "$DATABASE_URL" -f supabase/migrations/0006_boundary_arc.sql
```

`auth.users` и `auth.uid()` уже есть в Supabase. Для локальных тестов на обычном
PostgreSQL используется заглушка `supabase/tests/00_auth_stub.sql` — на Supabase
её применять не нужно.

## Основные RPC

```sql
-- Забег: массив точек {lon, lat, t (epoch ms), accuracy}.
-- Второй аргумент p_rings — замкнутые контуры захватов [[lon, lat], ...].
select public.submit_run('[
  {"lon": 37.6000, "lat": 55.7500, "t": 1700000000000, "accuracy": 5},
  {"lon": 37.6005, "lat": 55.7505, "t": 1700000005000, "accuracy": 5}
]'::jsonb);

-- Домашняя зона (по умолчанию 300 м из game_config)
select public.set_home_zone(37.60, 55.75, 300);

-- Территории в bbox карты (GeoJSON для веб-клиента)
select * from public.territories_bbox_geojson(37.55, 55.70, 37.65, 55.80);

-- Город и район по точке
select * from public.city_at_point(37.60, 55.75);

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
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/migrations/0004_api.sql
psql -d runwave -v ON_ERROR_STOP=1 -f supabase/tests/game_test.sql
```

Сценарии проверяют захват, защиту, перехват, частичное наложение, скрытую зону
(включая RLS), отклонение скачков и плохой точности, архивирование сезона,
bbox и рейтинг. Тесты выполняются в одной транзакции и откатываются.

### Захват дугой (0006) в тестовом проекте Supabase

`supabase/tests/0006_arc_test.sql` рассчитан на обычный проект Supabase и не
требует `00_auth_stub.sql`: игрок берётся из `request.jwt.claims`, как его
читает `auth.uid()`.

1. Применить миграции по порядку (или `setup.sql` целиком).
2. `SQL Editor` → `New query` → вставить `0006_arc_test.sql` целиком → Run.
3. В `Notices` будут строки `OK: ...`, в конце — `=== Все сценарии 0006
   прошли ===`. Файл заканчивается `rollback`: данные проекта не меняются.
4. Если сценарий упал, придёт `FAIL: <проверка>` — транзакция прервана и тоже
   не зафиксирована; на всякий случай выполни `rollback;` отдельным запросом.

Сценарии: дуга с касанием границы, дуга без касания (конец дальше
`boundary_touch_m`), дуга вокруг угла (выбор стороны границы), дуга через
чужую защищённую территорию, повтор забега.

Дугу описывает трек, а не контур клиента: сервер берёт участок трека вне своей
территории (`ST_Difference`), проверяет, что оба конца лежат не дальше
`boundary_touch_m` от границы и дуга не короче `min_arc_length_m` (20 м),
замыкает её участком границы (`ST_LineSubstring`), выбирает сторону с меньшим
наложением на свою территорию и меньшей площадью, делает `ST_MakeValid` и
`ST_Difference` со своей территорией. Дальше работают правила `0005`:
минимальные площадь, периметр и прирост, правдоподобие площади по длине дуги,
`protected_until`, очки только за новую площадь и двойные за отнятое.
