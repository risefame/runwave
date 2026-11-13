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
