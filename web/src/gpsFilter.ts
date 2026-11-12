import { distanceMeters, type LngLat } from './territory';

/**
 * Все пороги фильтра GPS собраны здесь: меняйте числа в одном месте,
 * остальная логика от конкретных значений не зависит.
 */
export interface GpsFilterConfig {
  /** Замеры с accuracy хуже этого значения (м) отбрасываются. */
  maxAccuracyMeters: number;
  /** Точность (м), начиная с которой индикатор GPS считается хорошим. */
  accuracyGoodMeters: number;
  /** Минимальный шаг между точками следа, м. */
  minStepMeters: number;
  /** Доля accuracy в минимальном шаге: шаг = max(minStep, accuracy * ratio). */
  accuracyStepRatio: number;
  /** Максимальная правдоподобная скорость между замерами, м/с: быстрее — скачок. */
  maxSpeedMps: number;
  /** Скорость, ниже которой считаем, что стоим, м/с. */
  standingSpeedMps: number;
  /** Сколько миллисекунд должна продержаться низкая скорость, чтобы включить «стоим». */
  standingWindowMs: number;
  /** Смещение от точки остановки (м), после которого движение вообще учитывается. */
  standingExitMeters: number;
  /** Прирост смещения (м) на каждом замере, подтверждающий движение. */
  standingExitStepMeters: number;
  /** Сколько подряд замеров должны подтвердить движение, чтобы выйти из «стоим». */
  standingExitSamples: number;
  /** Размер окна скользящего среднего для принятых точек. */
  smoothingWindow: number;
  /** Сколько первых пригодных точек после старта игнорировать (прогрев GPS). */
  warmupSamples: number;
}

export const GPS_FILTER_CONFIG: GpsFilterConfig = {
  maxAccuracyMeters: 25,
  accuracyGoodMeters: 10,
  minStepMeters: 5,
  accuracyStepRatio: 0.5,
  maxSpeedMps: 7,
  standingSpeedMps: 0.5,
  standingWindowMs: 4000,
  standingExitMeters: 12,
  standingExitStepMeters: 2,
  standingExitSamples: 3,
  smoothingWindow: 3,
  warmupSamples: 3,
};

export interface GpsFix {
  point: LngLat;
  /** Радиус точности замера, м. */
  accuracy: number;
  /** Монотонное время замера, мс. */
  time: number;
}

export type GpsRejectReason = 'warming-up' | 'inaccurate' | 'jump' | 'too-close' | 'standing';

export interface GpsFilterResult {
  accepted: boolean;
  reason: GpsRejectReason | null;
  /** Сглаженная точка, принятая в след (null, если замер отброшен). */
  point: LngLat | null;
  /** Сколько метров этот замер добавляет к дистанции. */
  stepMeters: number;
  /** Скорость на отрезке следа, м/с. */
  speedMps: number;
  /** Стоим на месте: след и дистанция не растут. */
  standing: boolean;
  /** Точность текущего замера, м. */
  accuracy: number;
}

export interface GpsFilter {
  push(fix: GpsFix): GpsFilterResult;
  reset(): void;
  isStanding(): boolean;
}

export type GpsAccuracyQuality = 'good' | 'fair' | 'poor';

function meanPoint(points: LngLat[]): LngLat {
  let lng = 0;
  let lat = 0;
  for (const point of points) {
    lng += point[0];
    lat += point[1];
  }
  return [lng / points.length, lat / points.length];
}

/** Качество сигнала для индикатора точности. */
export function accuracyQuality(
  accuracy: number,
  overrides: Partial<GpsFilterConfig> = {},
): GpsAccuracyQuality {
  const config = { ...GPS_FILTER_CONFIG, ...overrides };
  if (!Number.isFinite(accuracy)) return 'poor';
  if (accuracy > config.maxAccuracyMeters) return 'poor';
  return accuracy <= config.accuracyGoodMeters ? 'good' : 'fair';
}

/** Точность в виде «±12 м». */
export function formatAccuracy(accuracy: number): string {
  return Number.isFinite(accuracy) ? `±${Math.round(Math.max(0, accuracy))} м` : '—';
}

/**
 * Фильтр шума GPS. Чистая логика без карты и таймеров: на вход — замеры,
 * на выход — решения, что попадёт в след и в дистанцию.
 */
export function createGpsFilter(overrides: Partial<GpsFilterConfig> = {}): GpsFilter {
  const config: GpsFilterConfig = { ...GPS_FILTER_CONFIG, ...overrides };

  let warmupLeft = config.warmupSamples;
  /** Предыдущий пригодный замер: база для проверки скачка. */
  let previous: { point: LngLat; time: number } | null = null;
  /** Время последнего замера, попавшего в след. */
  let lastAcceptedAt = 0;
  /** Окно сглаживания (скользящее среднее). */
  let window: LngLat[] = [];
  /** Последняя выданная (сглаженная) точка — хвост следа. */
  let output: LngLat | null = null;
  /** Старт всегда в состоянии «стоим»: пока движение не подтверждено, трек не растёт. */
  let standing = true;
  /** Точка, вокруг которой держимся, пока стоим. */
  let stillAnchor: LngLat | null = null;
  /** Наибольшее смещение от точки остановки, уже подтверждённое замерами. */
  let stillLastDistance = 0;
  /** Сколько подряд замеров подтвердили движение при выходе из «стоим». */
  let stillMovedSamples = 0;

  function rejected(reason: GpsRejectReason, accuracy: number, speedMps = 0): GpsFilterResult {
    return { accepted: false, reason, point: null, stepMeters: 0, speedMps, standing, accuracy };
  }

  function accepted(
    point: LngLat,
    stepMeters: number,
    speedMps: number,
    accuracy: number,
  ): GpsFilterResult {
    return { accepted: true, reason: null, point, stepMeters, speedMps, standing, accuracy };
  }

  function reset(): void {
    warmupLeft = config.warmupSamples;
    previous = null;
    lastAcceptedAt = 0;
    window = [];
    output = null;
    standing = true;
    stillAnchor = null;
    stillLastDistance = 0;
    stillMovedSamples = 0;
  }

  function push(fix: GpsFix): GpsFilterResult {
    const point: LngLat = [fix.point[0], fix.point[1]];
    const { accuracy, time } = fix;

    if (!Number.isFinite(accuracy) || accuracy > config.maxAccuracyMeters) {
      return rejected('inaccurate', accuracy);
    }

    // GPS «прогревается»: первые замеры после старта слишком неточны по смещению.
    if (warmupLeft > 0) {
      warmupLeft -= 1;
      return rejected('warming-up', accuracy);
    }

    let fixSpeed = 0;
    if (previous) {
      const dt = (time - previous.time) / 1000;
      fixSpeed = dt > 0 ? distanceMeters(previous.point, point) / dt : 0;
      // Скачок не становится новой базой: следующий нормальный замер
      // сравнится с последним нормальным, а не с выбросом.
      if (fixSpeed > config.maxSpeedMps) return rejected('jump', accuracy, fixSpeed);
    }
    previous = { point, time };

    if (!output) {
      // Первая точка после прогрева становится опорой трека — без дистанции.
      output = point;
      window = [point];
      lastAcceptedAt = time;
      stillAnchor = point;
      stillLastDistance = 0;
      stillMovedSamples = 0;
      return accepted(point, 0, 0, accuracy);
    }

    if (standing) {
      const fromAnchor = distanceMeters(stillAnchor ?? point, point);
      // Мало того, что отошли от точки остановки — смещение должно ещё и расти
      // от замера к замеру, иначе это просто шум вокруг стоящего человека.
      const movedEnough =
        fixSpeed >= config.standingSpeedMps &&
        fromAnchor >= config.standingExitMeters &&
        fromAnchor >= stillLastDistance + config.standingExitStepMeters;

      stillMovedSamples = movedEnough ? stillMovedSamples + 1 : 0;
      stillLastDistance = Math.max(stillLastDistance, fromAnchor);

      if (stillMovedSamples < config.standingExitSamples) return rejected('standing', accuracy);

      // Движение подтверждено несколькими замерами — возвращаемся в след.
      standing = false;
      stillAnchor = null;
      stillLastDistance = 0;
      stillMovedSamples = 0;
      window = [point];
      output = point;
      lastAcceptedAt = time;
      return accepted(point, fromAnchor, fixSpeed, accuracy);
    }

    const stepFromTrack = distanceMeters(output, point);
    const dwellMs = time - lastAcceptedAt;
    const dwell = dwellMs / 1000;
    const trackSpeed = dwell > 0 ? stepFromTrack / dwell : 0;
    // Допуск на шум: за время простоя точка не должна уйти дальше
    // разрешённого пробега плюс собственный радиус точности.
    const driftAllowed = config.standingSpeedMps * dwell + accuracy;

    if (dwellMs >= config.standingWindowMs && stepFromTrack <= driftAllowed) {
      standing = true;
      stillAnchor = [output[0], output[1]];
      stillLastDistance = 0;
      stillMovedSamples = 0;
      window = [output];
      return rejected('standing', accuracy);
    }

    const minStep = Math.max(config.minStepMeters, accuracy * config.accuracyStepRatio);
    if (stepFromTrack < minStep) return rejected('too-close', accuracy);

    window.push(point);
    if (window.length > config.smoothingWindow) window.shift();

    const smoothed = meanPoint(window);
    const step = distanceMeters(output, smoothed);
    output = smoothed;
    lastAcceptedAt = time;
    return accepted(smoothed, step, trackSpeed, accuracy);
  }

  return {
    push,
    reset,
    isStanding: () => standing,
  };
}
