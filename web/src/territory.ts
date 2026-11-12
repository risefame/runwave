import areaOf from '@turf/area';
import centerOfMass from '@turf/center-of-mass';
import difference from '@turf/difference';
import lengthOf from '@turf/length';
import union from '@turf/union';
import type { Feature, FeatureCollection, LineString, MultiPolygon, Polygon } from 'geojson';

export type LngLat = [number, number];

/** Геометрия территории: после обрезки наложений может стать мультиполигоном. */
export type TerritoryShape = Polygon | MultiPolygon;

/** Минимальная площадь засчитываемой территории, м². */
export const MIN_AREA_M2 = 500;
/** Минимальный периметр: отсекает вырожденные «нитки» и самопересечения. */
export const MIN_PERIMETER_M = 40;
/** Радиус, при котором возврат к началу следа замыкает контур, м. */
export const START_CLOSE_RADIUS_M = 15;
/** Минимальный прирост площади, м²: меньше — новая площадь не засчитывается. */
export const MIN_GAIN_M2 = 1;

/** Пороги захвата присоединением к своей границе. */
export const CONFIG = {
  /** Допуск касания границы своей территории, м. */
  touchTolerance: 12,
  /** Минимальная длина дуги, замыкающей захват, м: отсекает шум GPS у границы. */
  minArcLength: 20,
} as const;

/** Насколько точка выхода может отстоять от границы, чтобы считаться выходом, м. */
const BOUNDARY_EXIT_TOLERANCE_M = 2;
/** Пересечение с уже своей территорией до этой площади считается касанием, м². */
const OVERLAP_TOLERANCE_M2 = 1;
/** Ближе этого к точке выхода вход считается возвратом в ту же точку, м. */
const SAME_POINT_TOLERANCE_M = 1.5;

export interface LoopClosure {
  /** 'start' — вернулись к началу следа, 'cross' — пересекли более ранний отрезок. */
  kind: 'start' | 'cross';
  /** Точки замкнутого контура (без замыкающей точки). */
  ring: LngLat[];
  /** Индекс пересёкнутого отрезка для kind: 'cross'. */
  crossedSegment?: number;
}

export interface TerritoryGeometry {
  /** Геометрия без наложений на другие территории игрока. */
  shape: TerritoryShape;
  /** Площадь, м². */
  area: number;
  /** Периметр (длина всей границы), м. */
  perimeter: number;
  /** Центр тяжести территории. */
  centroid: LngLat;
}

export interface LoopOptions {
  /** Радиус возврата к началу, м. */
  startRadius?: number;
  /** Сколько точек нужно, чтобы вообще искать замыкание. */
  minTrailPoints?: number;
}

export interface TerritoryOptions {
  minArea?: number;
  minPerimeter?: number;
}

export interface CaptureOptions extends TerritoryOptions {
  /** Минимальный прирост площади, м². */
  minGain?: number;
}

function toRad(degrees: number): number {
  return (degrees * Math.PI) / 180;
}

/** Расстояние между точками по большому кругу, м. */
export function distanceMeters(a: LngLat, b: LngLat): number {
  const earthRadius = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a[1])) * Math.cos(toRad(b[1])) * Math.sin(dLng / 2) ** 2;
  return 2 * earthRadius * Math.asin(Math.sqrt(h));
}

/**
 * Точка пересечения двух отрезков в координатах [lng, lat] или null.
 * Плоская геометрия: на городских масштабах погрешность пренебрежимо мала.
 * Параллельные и коллинеарные отрезки пересечением не считаются.
 */
export function segmentIntersection(a1: LngLat, a2: LngLat, b1: LngLat, b2: LngLat): LngLat | null {
  const rx = a2[0] - a1[0];
  const ry = a2[1] - a1[1];
  const sx = b2[0] - b1[0];
  const sy = b2[1] - b1[1];

  const denominator = rx * sy - ry * sx;
  if (Math.abs(denominator) < 1e-15) return null;

  const qpx = b1[0] - a1[0];
  const qpy = b1[1] - a1[1];
  const t = (qpx * sy - qpy * sx) / denominator;
  const u = (qpx * ry - qpy * rx) / denominator;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;

  return [a1[0] + rx * t, a1[1] + ry * t];
}

/**
 * Ищет замыкание текущего следа: возврат к началу или пересечение
 * последнего отрезка с более ранним следом.
 * Чистая функция: ничего не мутирует и не зависит от карты.
 */
export function findLoopClosure(trail: LngLat[], options: LoopOptions = {}): LoopClosure | null {
  const startRadius = options.startRadius ?? START_CLOSE_RADIUS_M;
  const minTrailPoints = options.minTrailPoints ?? 4;
  if (trail.length < minTrailPoints) return null;

  const last = trail[trail.length - 1];
  if (distanceMeters(last, trail[0]) <= startRadius) {
    return { kind: 'start', ring: trail.map((point): LngLat => [point[0], point[1]]) };
  }

  const end = trail.length - 1;
  // i = end - 2 делит вершину с последним отрезком, поэтому начинаем с end - 3
  // и идём назад: самый поздний отрезок даёт самый компактный контур.
  for (let i = end - 3; i >= 0; i -= 1) {
    const cross = segmentIntersection(trail[i], trail[i + 1], trail[end - 1], trail[end]);
    if (!cross) continue;

    const ring = [cross, ...trail.slice(i + 1).map((point): LngLat => [point[0], point[1]])];
    if (ring.length < 4) continue;
    return { kind: 'cross', ring, crossedSegment: i };
  }

  return null;
}

function closeRing(ring: LngLat[]): LngLat[] {
  const points: LngLat[] = [];
  for (const point of ring) {
    const previous = points[points.length - 1];
    if (previous && previous[0] === point[0] && previous[1] === point[1]) continue;
    points.push([point[0], point[1]]);
  }

  if (points.length === 0) return points;
  const first = points[0];
  const last = points[points.length - 1];
  if (first[0] !== last[0] || first[1] !== last[1]) points.push([first[0], first[1]]);
  return points;
}

function lineFeature(points: LngLat[]): Feature<LineString> {
  return {
    type: 'Feature',
    properties: {},
    geometry: { type: 'LineString', coordinates: points },
  };
}

function shapeFeature(shape: TerritoryShape): Feature<TerritoryShape> {
  return { type: 'Feature', properties: {}, geometry: shape };
}

function shapeCollection(shapes: TerritoryShape[]): FeatureCollection<TerritoryShape> {
  return { type: 'FeatureCollection', features: shapes.map(shapeFeature) };
}

/** Все полигоны геометрии (для мультиполигона — каждый его контур). */
function polygonsOf(shape: TerritoryShape): Polygon['coordinates'][] {
  return shape.type === 'Polygon' ? [shape.coordinates] : shape.coordinates;
}

/** Внешние кольца всех полигонов территории. */
export function outerRings(shape: TerritoryShape): LngLat[][] {
  return polygonsOf(shape).map((rings) => rings[0] as LngLat[]);
}

/** Длина границы: внешние кольца и границы дырок. */
function boundaryLength(shape: TerritoryShape): number {
  let total = 0;
  for (const rings of polygonsOf(shape)) {
    for (const ring of rings) {
      if (ring.length < 2) continue;
      total += lengthOf(lineFeature(ring as LngLat[]), { units: 'kilometers' }) * 1000;
    }
  }
  return total;
}

/** Центр тяжести (площадной центроид), а не среднее арифметическое вершин. */
function centerOf(shape: TerritoryShape): LngLat {
  const [lng, lat] = centerOfMass(shapeFeature(shape)).geometry.coordinates;
  if (Number.isFinite(lng) && Number.isFinite(lat)) return [lng, lat];

  const first = outerRings(shape)[0]?.[0];
  return first ? [first[0], first[1]] : [0, 0];
}

function measureShape(shape: TerritoryShape): {
  area: number;
  perimeter: number;
  centroid: LngLat;
} {
  return {
    area: areaOf(shapeFeature(shape)),
    perimeter: boundaryLength(shape),
    centroid: centerOf(shape),
  };
}

/** Площадь (м²) и периметр (м) контура. */
export function measureRing(ring: LngLat[]): {
  area: number;
  perimeter: number;
  centroid: LngLat;
} {
  const closed = closeRing(ring);
  if (closed.length < 4) return { area: 0, perimeter: 0, centroid: centerOf({ type: 'Polygon', coordinates: [closed] }) };

  return measureShape({ type: 'Polygon', coordinates: [closed] });
}

/** Засчитывает контур как территорию или возвращает null, если он слишком мал. */
export function createTerritory(
  ring: LngLat[],
  options: TerritoryOptions = {},
): TerritoryGeometry | null {
  const minArea = options.minArea ?? MIN_AREA_M2;
  const minPerimeter = options.minPerimeter ?? MIN_PERIMETER_M;
  if (ring.length < 3) return null;

  const closed = closeRing(ring);
  if (closed.length < 4) return null;

  const shape: Polygon = { type: 'Polygon', coordinates: [closed] };
  const { area, perimeter, centroid } = measureShape(shape);
  if (!Number.isFinite(area) || area < minArea) return null;
  if (!Number.isFinite(perimeter) || perimeter < minPerimeter) return null;

  return { shape, area, perimeter, centroid };
}

/** Убирает из контура уже занятую игроком площадь. */
function withoutOwned(shape: TerritoryShape, owned: TerritoryShape[]): TerritoryShape | null {
  if (owned.length === 0) return shape;

  // Все свои полигоны объединяем в одну геометрию, иначе вычитать пришлось бы по одному.
  const ownedShape =
    owned.length === 1 ? owned[0] : (union(shapeCollection(owned))?.geometry ?? null);
  if (!ownedShape) return null;

  const result = difference(shapeCollection([shape, ownedShape]));
  return result ? result.geometry : null;
}

/**
 * Новый захват с учётом уже занятой площади.
 * Свои территории объединяются (turf union), из нового контура вычитается
 * объединение (turf difference): в результат и в очки попадает только та часть,
 * которой у игрока ещё не было, поэтому территории хранятся без наложений.
 * null — контур не засчитан (мал, вырожден или целиком лежит на своей территории).
 */
export function captureTerritory(
  ring: LngLat[],
  owned: TerritoryShape[],
  options: CaptureOptions = {},
): TerritoryGeometry | null {
  const traced = createTerritory(ring, options);
  if (!traced) return null;

  const minGain = options.minGain ?? MIN_GAIN_M2;
  const fresh = withoutOwned(traced.shape, owned);
  if (!fresh) return null;

  const { area, perimeter, centroid } = measureShape(fresh);
  if (!Number.isFinite(area) || area < minGain) return null;
  if (!Number.isFinite(perimeter)) return null;

  return { shape: fresh, area, perimeter, centroid };
}

// ——— Присоединение к своей границе (механика Paper.io) ———

export interface BoundaryClosureOptions {
  /** Допуск касания границы, м. */
  touchTolerance?: number;
  /** Минимальная длина дуги, м. */
  minArcLength?: number;
}

export interface BoundaryClosure {
  /** Замкнутый контур: дуга следа плюс отрезок границы. */
  ring: LngLat[];
  /** Точка выхода на границу. */
  exit: LngLat;
  /** Точка входа, спроецированная на границу. */
  entry: LngLat;
  /** Длина дуги между выходом и входом, м. */
  arcLength: number;
  /** Расстояние от последней точки следа до границы, м. */
  touchDistance: number;
  /** Площадь выбранной области, м². */
  area: number;
}

function ringsOfShape(shape: TerritoryShape): LngLat[][] {
  const rings: LngLat[][] = [];
  for (const polygon of polygonsOf(shape)) {
    for (const ring of polygon) rings.push(ring as LngLat[]);
  }
  return rings;
}

/** Все свои территории одной геометрией: общая граница и общая площадь. */
function combinedOwned(owned: TerritoryShape[]): TerritoryShape | null {
  if (owned.length === 0) return null;
  if (owned.length === 1) return owned[0];
  return union(shapeCollection(owned))?.geometry ?? null;
}

function pointInRing(point: LngLat, ring: LngLat[]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i, i += 1) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    const crosses = yi > point[1] !== yj > point[1];
    if (crosses && point[0] < ((xj - xi) * (point[1] - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/** Точка внутри своей территории (внешние кольца минус дырки). */
export function isInsideTerritory(point: LngLat, owned: TerritoryShape[]): boolean {
  for (const shape of owned) {
    for (const rings of polygonsOf(shape)) {
      if (!pointInRing(point, rings[0] as LngLat[])) continue;
      const inHole = rings
        .slice(1)
        .some((hole) => pointInRing(point, hole as LngLat[]));
      if (!inHole) return true;
    }
  }
  return false;
}

/** Проекция точки на отрезок в локальных метрах; t — доля вдоль отрезка. */
function projectOnSegment(point: LngLat, a: LngLat, b: LngLat): { point: LngLat; t: number } {
  const metersPerDegLng = 111320 * Math.cos(toRad(point[1]));
  const ax = (a[0] - point[0]) * metersPerDegLng;
  const ay = (a[1] - point[1]) * 111320;
  const bx = (b[0] - point[0]) * metersPerDegLng;
  const by = (b[1] - point[1]) * 111320;
  const dx = bx - ax;
  const dy = by - ay;
  const lengthSquared = dx * dx + dy * dy;
  const unclamped = lengthSquared > 0 ? -(ax * dx + ay * dy) / lengthSquared : 0;
  const t = Math.min(Math.max(unclamped, 0), 1);
  return { point: [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t], t };
}

interface BoundaryHit {
  point: LngLat;
  ringIndex: number;
  segmentIndex: number;
  distance: number;
}

function nearestBoundary(point: LngLat, rings: LngLat[][]): BoundaryHit | null {
  let best: BoundaryHit | null = null;
  for (let ringIndex = 0; ringIndex < rings.length; ringIndex += 1) {
    const ring = rings[ringIndex];
    for (let segmentIndex = 0; segmentIndex < ring.length - 1; segmentIndex += 1) {
      const projected = projectOnSegment(point, ring[segmentIndex], ring[segmentIndex + 1]);
      const distance = distanceMeters(point, projected.point);
      if (!best || distance < best.distance) {
        best = { point: projected.point, ringIndex, segmentIndex, distance };
      }
    }
  }
  return best;
}

/** Пересечение отрезка с границей своей территории, ближайшее к концу отрезка. */
export function boundaryCrossing(
  from: LngLat,
  to: LngLat,
  owned: TerritoryShape[],
): LngLat | null {
  const shape = combinedOwned(owned);
  const rings = shape ? ringsOfShape(shape) : [];

  let crossing: LngLat | null = null;
  let crossingDistance = Infinity;
  for (const ring of rings) {
    for (let i = 0; i < ring.length - 1; i += 1) {
      const cross = segmentIntersection(from, to, ring[i], ring[i + 1]);
      if (!cross) continue;
      const distance = distanceMeters(cross, to);
      if (distance < crossingDistance) {
        crossingDistance = distance;
        crossing = cross;
      }
    }
  }
  return crossing;
}

/**
 * Точка выхода на границу: пересечение отрезка (внутри → снаружи) с границей.
 * Если пересечения нет, берётся ближайшая точка границы.
 */
export function boundaryExitPoint(
  from: LngLat,
  to: LngLat,
  owned: TerritoryShape[],
): LngLat {
  const crossing = boundaryCrossing(from, to, owned);
  if (crossing) return crossing;

  const shape = combinedOwned(owned);
  const hit = nearestBoundary(to, shape ? ringsOfShape(shape) : []);
  return hit ? hit.point : [to[0], to[1]];
}

/** Два пути по кольцу границы между точкой входа и точкой выхода. */
function boundaryPaths(
  ring: LngLat[],
  entry: LngLat,
  entrySegment: number,
  exit: LngLat,
  exitSegment: number,
): LngLat[][] | null {
  const points: LngLat[] = [];
  let entryIndex = -1;
  let exitIndex = -1;

  for (let i = 0; i < ring.length - 1; i += 1) {
    points.push([ring[i][0], ring[i][1]]);
    if (i === entrySegment) {
      points.push([entry[0], entry[1]]);
      entryIndex = points.length - 1;
    }
    if (i === exitSegment) {
      points.push([exit[0], exit[1]]);
      exitIndex = points.length - 1;
    }
  }
  points.push([ring[ring.length - 1][0], ring[ring.length - 1][1]]);

  if (entryIndex < 0 || exitIndex < 0 || entryIndex === exitIndex) return null;

  const forward =
    entryIndex < exitIndex
      ? points.slice(entryIndex, exitIndex + 1)
      : [...points.slice(entryIndex), ...points.slice(0, exitIndex + 1)];
  // Путь через замыкание кольца идёт в обратную сторону — разворачиваем,
  // чтобы оба пути шли от входа к выходу.
  const backward =
    exitIndex < entryIndex
      ? points.slice(exitIndex, entryIndex + 1).reverse()
      : [...points.slice(exitIndex), ...points.slice(0, entryIndex + 1)].reverse();

  return [forward, backward];
}

/**
 * Замыкание следа присоединением к своей территории.
 *
 * Условия: след начался на границе (выход за неё), последняя точка снова
 * подошла к границе ближе CONFIG.touchTolerance, дуга не короче
 * CONFIG.minArcLength. Область собирается из дуги и отрезка границы между
 * выходом и входом; из двух направлений по границе берётся то, которое не
 * пересекает уже захваченную территорию и меньше по площади.
 * null — контур не касается своей границы: работают старые правила замыкания.
 */
export function findBoundaryClosure(
  trail: LngLat[],
  owned: TerritoryShape[],
  options: BoundaryClosureOptions = {},
): BoundaryClosure | null {
  if (trail.length < 3 || owned.length === 0) return null;

  const touchTolerance = options.touchTolerance ?? CONFIG.touchTolerance;
  const minArcLength = options.minArcLength ?? CONFIG.minArcLength;

  const ownedShape = combinedOwned(owned);
  if (!ownedShape) return null;
  const rings = ringsOfShape(ownedShape);

  const exit = trail[0];
  const start = nearestBoundary(exit, rings);
  if (!start || start.distance > BOUNDARY_EXIT_TOLERANCE_M) return null;

  const last = trail[trail.length - 1];
  const touch = nearestBoundary(last, rings);
  if (!touch || touch.distance > touchTolerance) return null;

  const entry = touch.point;
  if (distanceMeters(exit, entry) <= SAME_POINT_TOLERANCE_M) return null;

  let arcLength = distanceMeters(last, entry);
  for (let i = 1; i < trail.length; i += 1) {
    arcLength += distanceMeters(trail[i - 1], trail[i]);
  }
  if (arcLength < minArcLength) return null;

  // Дуга должна начинаться и заканчиваться на одном контуре границы.
  if (start.ringIndex !== touch.ringIndex) return null;

  const paths = boundaryPaths(
    rings[touch.ringIndex],
    entry,
    touch.segmentIndex,
    exit,
    start.segmentIndex,
  );
  if (!paths) return null;

  const arc: LngLat[] = trail.map((point): LngLat => [point[0], point[1]]);
  arc.push([entry[0], entry[1]]);

  let best: { ring: LngLat[]; area: number; overlap: number } | null = null;

  for (const path of paths) {
    // path начинается с точки входа, которая уже есть в конце дуги.
    const closed = closeRing([...arc, ...path.slice(1)]);
    if (closed.length < 4) continue;

    const candidate: Polygon = { type: 'Polygon', coordinates: [closed] };
    const area = areaOf(shapeFeature(candidate));
    if (!Number.isFinite(area) || area <= 0) continue;

    const fresh = difference(shapeCollection([candidate, ownedShape]));
    const overlap = Math.max(0, area - (fresh ? areaOf(fresh) : 0));

    if (!best || isBetterCandidate({ area, overlap }, best)) {
      best = { ring: closed, area, overlap };
    }
  }

  if (!best) return null;

  return {
    ring: best.ring,
    exit: [exit[0], exit[1]],
    entry,
    arcLength,
    touchDistance: touch.distance,
    area: best.area,
  };
}

/** Меньше наложений, при равенстве — меньшая площадь. */
function isBetterCandidate(
  candidate: { area: number; overlap: number },
  current: { area: number; overlap: number },
): boolean {
  const candidateClean = candidate.overlap <= OVERLAP_TOLERANCE_M2;
  const currentClean = current.overlap <= OVERLAP_TOLERANCE_M2;
  if (candidateClean !== currentClean) return candidateClean;
  if (!candidateClean && Math.abs(candidate.overlap - current.overlap) > OVERLAP_TOLERANCE_M2) {
    return candidate.overlap < current.overlap;
  }
  return candidate.area < current.area;
}
