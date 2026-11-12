import areaOf from '@turf/area';
import union from '@turf/union';
import { describe, expect, it } from 'vitest';
import type { Feature, FeatureCollection } from 'geojson';
import {
  boundaryExitPoint,
  captureTerritory,
  CONFIG,
  createTerritory,
  distanceMeters,
  findBoundaryClosure,
  findLoopClosure,
  isInsideTerritory,
  MIN_AREA_M2,
  type LngLat,
  type TerritoryShape,
} from './territory';

const BASE: LngLat = [37.6173, 55.7558];
const DEG_LNG_M = 111320 * Math.cos((55.7558 * Math.PI) / 180);
const DEG_LAT_M = 111320;

/** Точка в метрах от базовой: x — на восток, y — на север. */
function at(eastMeters: number, northMeters: number): LngLat {
  return [BASE[0] + eastMeters / DEG_LNG_M, BASE[1] + northMeters / DEG_LAT_M];
}

/** Квадрат по углам в метрах от базовой точки. */
function square(west: number, south: number, east: number, north: number): LngLat[] {
  return [at(west, south), at(east, south), at(east, north), at(west, north)];
}

/** Полигон из контура без проверок площади — для «уже занятых» территорий. */
function polygonOf(ring: LngLat[]): TerritoryShape {
  return { type: 'Polygon', coordinates: [[...ring, ring[0]]] };
}

function shapeArea(shape: TerritoryShape): number {
  return areaOf({ type: 'Feature', properties: {}, geometry: shape });
}

function unionArea(shapes: TerritoryShape[]): number {
  const features: Feature<TerritoryShape>[] = shapes.map((shape) => ({
    type: 'Feature',
    properties: {},
    geometry: shape,
  }));
  const collection: FeatureCollection<TerritoryShape> = { type: 'FeatureCollection', features };
  const merged = union(collection);
  return merged ? shapeArea(merged.geometry) : 0;
}

describe('distanceMeters', () => {
  it('считает короткие городские расстояния', () => {
    expect(distanceMeters(at(0, 0), at(0, 111.32))).toBeCloseTo(111.32, 0);
  });
});

describe('findLoopClosure', () => {
  it('не замыкает прямой след', () => {
    const trail = [at(0, 0), at(0, 10), at(0, 20), at(0, 30), at(0, 45)];
    expect(findLoopClosure(trail)).toBeNull();
  });

  it('замыкает след при возврате к точке старта ближе 15 м', () => {
    const trail = [at(0, 0), at(40, 0), at(40, 40), at(0, 40), at(5, 5)];
    const closure = findLoopClosure(trail);

    expect(closure?.kind).toBe('start');
    expect(closure?.ring.length).toBeGreaterThanOrEqual(4);
  });

  it('замыкает контур при пересечении собственного следа', () => {
    const trail = [
      at(0, 0),
      at(0, 100),
      at(100, 100),
      at(100, 0),
      at(20, 0),
      at(20, 50),
      at(-20, 50),
    ];
    const closure = findLoopClosure(trail);

    expect(closure).not.toBeNull();
    expect(closure!.kind).toBe('cross');
    expect(closure!.crossedSegment).toBe(0);
    // Контур начинается в точке пересечения последнего отрезка с ранним следом.
    expect(closure!.ring[0][0]).toBeCloseTo(at(0, 50)[0], 5);
    expect(closure!.ring[0][1]).toBeCloseTo(at(0, 50)[1], 5);
    expect(closure!.ring[closure!.ring.length - 1]).toEqual(trail[trail.length - 1]);
  });

  it('игнорирует след короче порога', () => {
    expect(findLoopClosure([at(0, 0), at(40, 0), at(0, 1)])).toBeNull();
  });
});

describe('createTerritory', () => {
  it('засчитывает контур больше минимальной площади', () => {
    const closure = findLoopClosure([at(0, 0), at(40, 0), at(40, 40), at(0, 40), at(5, 5)]);
    const territory = createTerritory(closure?.ring ?? []);

    expect(territory).not.toBeNull();
    expect(territory!.area).toBeGreaterThan(MIN_AREA_M2);
    expect(territory!.area).toBeCloseTo(1500, -2);
    expect(territory!.perimeter).toBeGreaterThan(150);
  });

  it('отбрасывает слишком маленький контур', () => {
    const ring = [at(0, 0), at(10, 0), at(10, 10), at(0, 10)];
    expect(createTerritory(ring)).toBeNull();
  });

  it('возвращает замкнутое кольцо и центр тяжести внутри контура', () => {
    const territory = createTerritory(square(0, 0, 60, 60));

    expect(territory).not.toBeNull();
    expect(territory!.shape.type).toBe('Polygon');
    const ring = territory!.shape.type === 'Polygon' ? territory!.shape.coordinates[0] : [];
    expect(ring[0]).toEqual(ring[ring.length - 1]);
    expect(territory!.area).toBeCloseTo(3600, -2);
    expect(territory!.centroid[0]).toBeCloseTo(at(30, 30)[0], 6);
    expect(territory!.centroid[1]).toBeCloseTo(at(30, 30)[1], 6);
  });
});

describe('captureTerritory: пересечение', () => {
  it('начисляет только новую часть площади', () => {
    const owned = polygonOf(square(0, 0, 60, 60));
    const gained = captureTerritory(square(40, 0, 100, 60), [owned]);

    expect(gained).not.toBeNull();
    // Пересечение 60 на 20 м не должно попасть в очки: остаётся 40 на 60 м.
    expect(gained!.area).toBeCloseTo(2400, -2);
  });

  it('не оставляет наложений: площади складываются без пересечения', () => {
    const owned = polygonOf(square(0, 0, 60, 60));
    const gained = captureTerritory(square(40, 0, 100, 60), [owned]);

    expect(gained).not.toBeNull();
    expect(gained!.area + shapeArea(owned)).toBeCloseTo(unionArea([owned, gained!.shape]), 0);
  });

  it('учитывает все уже захваченные территории', () => {
    const owned = [polygonOf(square(0, 0, 60, 60)), polygonOf(square(60, 0, 100, 60))];
    expect(captureTerritory(square(0, 0, 100, 60), owned)).toBeNull();
  });
});

describe('captureTerritory: вложенность', () => {
  it('не засчитывает контур внутри своей территории', () => {
    const owned = polygonOf(square(0, 0, 100, 100));
    expect(captureTerritory(square(20, 20, 80, 80), [owned])).toBeNull();
  });

  it('не засчитывает повторный захват того же контура', () => {
    const ring = square(0, 0, 80, 80);
    expect(captureTerritory(ring, [polygonOf(ring)])).toBeNull();
  });

  it('вычитает свою территорию из большого контура, оставляя дырку', () => {
    const owned = polygonOf(square(40, 40, 60, 60));
    const gained = captureTerritory(square(0, 0, 100, 100), [owned]);

    expect(gained).not.toBeNull();
    expect(gained!.area).toBeCloseTo(10000 - 400, -2);
    expect(gained!.shape.type).toBe('Polygon');
    const rings = gained!.shape.type === 'Polygon' ? gained!.shape.coordinates : [];
    expect(rings.length).toBe(2);
  });
});

describe('findBoundaryClosure: присоединение к своей границе', () => {
  const owned = polygonOf(square(0, 0, 100, 100));

  it('замыкает дугу, коснувшуюся границы с обеих сторон', () => {
    // Выход в середине восточной границы, возврат к ней же выше.
    const trail = [at(100, 50), at(130, 50), at(130, 90), at(100, 90)];
    const closure = findBoundaryClosure(trail, [owned]);

    expect(closure).not.toBeNull();
    expect(closure!.touchDistance).toBeLessThan(1);
    expect(closure!.arcLength).toBeCloseTo(100, 0);
    // Область между дугой и коротким участком границы: 30 на 40 м.
    expect(closure!.area).toBeCloseTo(1200, -1);

    const gained = captureTerritory(closure!.ring, [owned]);
    expect(gained).not.toBeNull();
    expect(gained!.area).toBeCloseTo(1200, -1);
    // Территории без наложений: их площади складываются.
    expect(gained!.area + shapeArea(owned)).toBeCloseTo(unionArea([owned, gained!.shape]), 0);
  });

  it('не засчитывает дугу, начатую в стороне от территории', () => {
    // Конец на границе есть, а выхода за границу не было.
    const trail = [at(130, 50), at(130, 90), at(100, 90)];
    expect(findBoundaryClosure(trail, [owned])).toBeNull();
  });

  it('засчитывает касание в пределах touchTolerance и не засчитывает дальше', () => {
    const near = [at(100, 50), at(130, 50), at(130, 90), at(104, 90)];
    const far = [at(100, 50), at(130, 50), at(130, 90), at(120, 90)];

    expect(CONFIG.touchTolerance).toBe(12);
    expect(findBoundaryClosure(near, [owned])).not.toBeNull();
    expect(findBoundaryClosure(far, [owned])).toBeNull();
  });

  it('обходит угол территории и берёт меньшую из двух областей', () => {
    // Выход на восточной границе, обход северо-восточного угла, вход в северную.
    const trail = [at(100, 20), at(140, 20), at(140, 120), at(20, 120), at(20, 100)];
    const closure = findBoundaryClosure(trail, [owned]);

    expect(closure).not.toBeNull();
    // Короткий путь по границе через угол даёт 5600 м², длинный — всю территорию.
    expect(closure!.area).toBeGreaterThan(5000);
    expect(closure!.area).toBeLessThan(7000);

    const gained = captureTerritory(closure!.ring, [owned]);
    expect(gained).not.toBeNull();
    expect(gained!.area).toBeCloseTo(closure!.area, -1);
  });

  it('не засчитывает шум GPS у границы: дуга короче 20 м', () => {
    const trail = [at(100, 50), at(100.5, 51), at(99.5, 52), at(100.5, 53)];
    expect(findBoundaryClosure(trail, [owned])).toBeNull();
  });

  it('не засчитывает возврат в ту же точку: его закрывают старые правила', () => {
    const trail = [at(100, 50), at(130, 50), at(130, 60), at(100, 50.5)];
    expect(findBoundaryClosure(trail, [owned])).toBeNull();
    expect(findLoopClosure(trail)?.kind).toBe('start');
  });

  it('старые правила работают для дуги, начатой в стороне от территории', () => {
    // Возврат к началу вдали от своих территорий.
    const trail = [at(300, 0), at(340, 0), at(340, 40), at(300, 40), at(305, 5)];

    expect(findBoundaryClosure(trail, [owned])).toBeNull();
    const closure = findLoopClosure(trail);
    expect(closure?.kind).toBe('start');
    expect(captureTerritory(closure!.ring, [owned])).not.toBeNull();
  });
});

describe('граница территории', () => {
  const owned = polygonOf(square(0, 0, 100, 100));

  it('находит точку выхода на границу', () => {
    const exit = boundaryExitPoint(at(90, 50), at(130, 50), [owned]);
    expect(exit[0]).toBeCloseTo(at(100, 50)[0], 7);
    expect(exit[1]).toBeCloseTo(at(100, 50)[1], 7);
  });

  it('различает точки внутри и снаружи', () => {
    expect(isInsideTerritory(at(50, 50), [owned])).toBe(true);
    expect(isInsideTerritory(at(150, 50), [owned])).toBe(false);
  });
});

describe('captureTerritory: касание контуров', () => {
  it('не теряет площадь при общей границе', () => {
    const owned = polygonOf(square(0, 0, 40, 40));
    const traced = captureTerritory(square(40, 0, 80, 40), []);
    const gained = captureTerritory(square(40, 0, 80, 40), [owned]);

    expect(gained).not.toBeNull();
    expect(gained!.area).toBeCloseTo(traced!.area, 6);
    expect(gained!.area + shapeArea(owned)).toBeCloseTo(unionArea([owned, gained!.shape]), 0);
  });

  it('не теряет площадь при касании в одной точке', () => {
    const owned = polygonOf(square(0, 0, 40, 40));
    const traced = captureTerritory(square(40, 40, 80, 80), []);
    const gained = captureTerritory(square(40, 40, 80, 80), [owned]);

    expect(gained).not.toBeNull();
    expect(gained!.area).toBeCloseTo(traced!.area, 6);
  });
});
