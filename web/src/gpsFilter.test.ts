import { describe, expect, it } from 'vitest';
import { distanceMeters, type LngLat } from './territory';
import {
  accuracyQuality,
  createGpsFilter,
  formatAccuracy,
  GPS_FILTER_CONFIG,
  type GpsFix,
} from './gpsFilter';

const BASE: LngLat = [37.6173, 55.7558];
const DEG_LNG_M = 111320 * Math.cos((BASE[1] * Math.PI) / 180);
const DEG_LAT_M = 111320;

/** Точка в метрах от базовой: x — на восток, y — на север. */
function at(eastMeters: number, northMeters: number): LngLat {
  return [BASE[0] + eastMeters / DEG_LNG_M, BASE[1] + northMeters / DEG_LAT_M];
}

/** Детерминированный генератор: тест не должен зависеть от удачи. */
function makeRandom(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Шум в пределах ±radius метров по каждой оси. */
function jitter(random: () => number, radius: number): { east: number; north: number } {
  return { east: (random() * 2 - 1) * radius, north: (random() * 2 - 1) * radius };
}

function fix(point: LngLat, accuracy: number, seconds: number): GpsFix {
  return { point, accuracy, time: seconds * 1000 };
}

describe('createGpsFilter: стоим на месте', () => {
  it('не копит дистанцию при шуме ±15 м', () => {
    const random = makeRandom(20261112);
    const filter = createGpsFilter();

    let filtered = 0;
    let raw = 0;
    let acceptedPoints = 0;
    let previousRaw: LngLat | null = null;

    for (let second = 0; second < 90; second += 1) {
      const noise = jitter(random, 15);
      const point = at(noise.east, noise.north);

      if (previousRaw) raw += distanceMeters(previousRaw, point);
      previousRaw = point;

      const result = filter.push(fix(point, 10, second));
      filtered += result.stepMeters;
      if (result.accepted) acceptedPoints += 1;
    }

    // Сырой GPS «набегал» километры, отфильтрованный трек почти не сдвинулся.
    expect(raw).toBeGreaterThan(1000);
    expect(filtered).toBeLessThan(30);
    expect(acceptedPoints).toBeLessThan(6);
    expect(filter.isStanding()).toBe(true);
  });
});

describe('createGpsFilter: прямой бег', () => {
  it('сохраняет дистанцию, сглаживает точки и не считает бег остановкой', () => {
    const random = makeRandom(7);
    const filter = createGpsFilter();

    let filtered = 0;
    let lastPoint: LngLat | null = null;
    let previousPoint: LngLat | null = null;
    let lastStandingSecond = -1;
    const reasons: string[] = [];

    for (let second = 0; second <= 60; second += 1) {
      const noise = jitter(random, 1.5);
      const point = at(3 * second + noise.east, noise.north);

      const result = filter.push(fix(point, 6, second));
      filtered += result.stepMeters;
      if (result.standing) lastStandingSecond = second;
      if (result.reason) reasons.push(result.reason);

      if (result.accepted && result.point) {
        if (previousPoint) expect(distanceMeters(previousPoint, result.point)).toBeGreaterThan(0);
        previousPoint = lastPoint;
        lastPoint = result.point;
      }
    }

    // Первые три замера — прогрев GPS.
    expect(reasons.slice(0, 3)).toEqual(['warming-up', 'warming-up', 'warming-up']);
    expect(lastPoint).not.toBeNull();
    // 60 с по 3 м/с ≈ 180 м, минус прогрев и отставание сглаживания.
    expect(filtered).toBeGreaterThan(150);
    expect(filtered).toBeLessThan(185);
    // «Стоим» бывает только в начале, пока движение не подтверждено.
    expect(lastStandingSecond).toBeLessThan(15);
    expect(filter.isStanding()).toBe(false);
  });
});

describe('createGpsFilter: одиночный выброс', () => {
  it('отбрасывает скачок на 200 м и не теряет следующие точки', () => {
    const filter = createGpsFilter();

    let filtered = 0;
    let jumpReasons = 0;
    let afterOutlierAccepted = false;

    for (let second = 0; second <= 60; second += 1) {
      const truth = at(3 * second, 0);
      const point = second === 20 ? at(3 * second, 200) : truth;
      const result = filter.push(fix(point, 6, second));

      filtered += result.stepMeters;
      if (result.reason === 'jump') jumpReasons += 1;
      if (second === 21) afterOutlierAccepted = result.accepted;
    }

    expect(jumpReasons).toBe(1);
    expect(afterOutlierAccepted).toBe(true);
    // Выброс и возврат к треку не должны добавить ~400 м.
    expect(filtered).toBeGreaterThan(130);
    expect(filtered).toBeLessThan(180);
  });
});

describe('createGpsFilter: плохая точность', () => {
  it('отбрасывает все замеры с accuracy хуже порога', () => {
    const filter = createGpsFilter();

    for (let second = 0; second < 20; second += 1) {
      const result = filter.push(fix(at(3 * second, 0), GPS_FILTER_CONFIG.maxAccuracyMeters + 15, second));
      expect(result.accepted).toBe(false);
      expect(result.reason).toBe('inaccurate');
      expect(result.stepMeters).toBe(0);
    }

    // Стоять на месте без единого пригодного замера — состояние по умолчанию.
    expect(filter.isStanding()).toBe(true);
  });
});

describe('индикатор точности', () => {
  it('красит и форматирует замер по качеству', () => {
    expect(accuracyQuality(6)).toBe('good');
    expect(accuracyQuality(18)).toBe('fair');
    expect(accuracyQuality(40)).toBe('poor');
    expect(formatAccuracy(12.4)).toBe('±12 м');
  });
});
