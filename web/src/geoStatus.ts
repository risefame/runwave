import { accuracyQuality, formatAccuracy, GPS_FILTER_CONFIG } from './gpsFilter';

/** Точность (м), с которой точный сигнал считается готовым к записи трека. */
export const GEO_READY_ACCURACY_M = GPS_FILTER_CONFIG.maxAccuracyMeters;

/** Сколько ждать точный сигнал, прежде чем подсказать про помещение, мс. */
export const INDOOR_HINT_AFTER_MS = 20000;

export type GeoStatusStage =
  | 'off'
  | 'unsupported'
  | 'test'
  | 'searching'
  | 'coarse'
  | 'refining'
  | 'ready';

export type GeoStatusQuality = 'off' | 'waiting' | 'good' | 'fair' | 'poor' | 'test';

export interface GeoStatusInput {
  /** Устройство вообще умеет определять геолокацию. */
  supported: boolean;
  /** Реальный GPS включён. */
  geoActive: boolean;
  /** Открыт режим разработчика: только там доступна имитация. */
  devMode: boolean;
  /** Точность приблизительного замера по сети, м. */
  coarseAccuracy: number | null;
  /** Точность последнего точного замера, м. */
  preciseAccuracy: number | null;
  /** Точный сигнал уже достиг порога записи. */
  preciseReady: boolean;
  /** Сколько миллисекунд идёт поиск точного сигнала. */
  elapsedMs: number;
}

export interface GeoStatusResult {
  stage: GeoStatusStage;
  /** Текст в индикаторе GPS. */
  text: string;
  /** Подсказка при наведении. */
  title: string;
  quality: GeoStatusQuality;
  /** Точки ещё не засчитываются в трек: ждём точный сигнал. */
  waitingPrecise: boolean;
  /** Пора подсказать, что в помещении GPS ищет дольше. */
  indoorHint: boolean;
}

function result(
  stage: GeoStatusStage,
  text: string,
  title: string,
  quality: GeoStatusQuality,
  waitingPrecise = false,
  indoorHint = false,
): GeoStatusResult {
  return { stage, text, title, quality, waitingPrecise, indoorHint };
}

/**
 * Текст индикатора GPS и подсказки. Чистая функция: ни карты, ни таймеров —
 * только состояние поиска позиции.
 */
export function describeGeoStatus(input: GeoStatusInput): GeoStatusResult {
  if (!input.supported) {
    return result(
      'unsupported',
      'Нет GPS',
      'Устройство не поддерживает геолокацию',
      'off',
    );
  }

  if (!input.geoActive) {
    if (input.devMode) {
      return result(
        'test',
        'Тест: имитация',
        'Режим разработчика: GPS выключен, территории помечаются «тест»',
        'test',
      );
    }
    return result('off', 'GPS выкл', 'Геолокация выключена', 'off');
  }

  const indoorHint = input.elapsedMs >= INDOOR_HINT_AFTER_MS;

  if (input.preciseReady) {
    const quality =
      input.preciseAccuracy === null ? 'good' : accuracyQuality(input.preciseAccuracy);
    return result('ready', 'GPS готов', 'Точный сигнал есть — точки засчитываются', quality);
  }

  if (input.preciseAccuracy !== null) {
    return result(
      'refining',
      `Уточняем: ${formatAccuracy(input.preciseAccuracy)}`,
      'Точность пока хуже порога — ждём точный сигнал',
      accuracyQuality(input.preciseAccuracy),
      true,
      indoorHint,
    );
  }

  if (input.coarseAccuracy !== null) {
    return result(
      'coarse',
      `Примерно ${formatAccuracy(input.coarseAccuracy)} · уточняем`,
      'Приблизительная позиция по сети: для записи нужен GPS',
      'waiting',
      true,
      indoorHint,
    );
  }

  return result(
    'searching',
    'Ищем вас…',
    'Определяем местоположение',
    'waiting',
    true,
    indoorHint,
  );
}
