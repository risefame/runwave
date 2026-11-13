import { describe, expect, it } from 'vitest';
import {
  describeGeoStatus,
  GEO_READY_ACCURACY_M,
  INDOOR_HINT_AFTER_MS,
  type GeoStatusInput,
} from './geoStatus';

function input(overrides: Partial<GeoStatusInput> = {}): GeoStatusInput {
  return {
    supported: true,
    geoActive: true,
    devMode: false,
    coarseAccuracy: null,
    preciseAccuracy: null,
    preciseReady: false,
    elapsedMs: 0,
    ...overrides,
  };
}

describe('describeGeoStatus', () => {
  it('в начале поиска показывает «Ищем вас…» и ждёт точный сигнал', () => {
    const status = describeGeoStatus(input());
    expect(status.stage).toBe('searching');
    expect(status.text).toBe('Ищем вас…');
    expect(status.waitingPrecise).toBe(true);
    expect(status.indoorHint).toBe(false);
  });

  it('приблизительную позицию показывает с точностью, но без готовности', () => {
    const status = describeGeoStatus(input({ coarseAccuracy: 1500 }));
    expect(status.stage).toBe('coarse');
    expect(status.text).toContain('±1500 м');
    expect(status.waitingPrecise).toBe(true);
  });

  it('неточный точный замер даёт «Уточняем: ±N м»', () => {
    const status = describeGeoStatus(
      input({ coarseAccuracy: 800, preciseAccuracy: GEO_READY_ACCURACY_M + 15 }),
    );
    expect(status.stage).toBe('refining');
    expect(status.text).toBe(`Уточняем: ±${GEO_READY_ACCURACY_M + 15} м`);
    expect(status.waitingPrecise).toBe(true);
  });

  it('точность на пороге gpsFilter считается готовой', () => {
    const status = describeGeoStatus(
      input({ preciseAccuracy: GEO_READY_ACCURACY_M, preciseReady: true }),
    );
    expect(status.stage).toBe('ready');
    expect(status.text).toBe('GPS готов');
    expect(status.waitingPrecise).toBe(false);
  });

  it('подсказка про помещение появляется только через 20 секунд', () => {
    const before = describeGeoStatus(input({ elapsedMs: INDOOR_HINT_AFTER_MS - 1 }));
    const after = describeGeoStatus(input({ elapsedMs: INDOOR_HINT_AFTER_MS }));
    expect(before.indoorHint).toBe(false);
    expect(after.indoorHint).toBe(true);
  });

  it('при готовом GPS подсказка про помещение не нужна', () => {
    const status = describeGeoStatus(
      input({
        preciseAccuracy: 5,
        preciseReady: true,
        elapsedMs: INDOOR_HINT_AFTER_MS * 2,
      }),
    );
    expect(status.indoorHint).toBe(false);
  });

  it('без поддержки геолокации сообщает об этом', () => {
    const status = describeGeoStatus(input({ supported: false }));
    expect(status.stage).toBe('unsupported');
    expect(status.text).toBe('Нет GPS');
    expect(status.waitingPrecise).toBe(false);
  });

  it('имитация доступна только в режиме разработчика', () => {
    const dev = describeGeoStatus(input({ geoActive: false, devMode: true }));
    const prod = describeGeoStatus(input({ geoActive: false, devMode: false }));
    expect(dev.stage).toBe('test');
    expect(dev.quality).toBe('test');
    expect(prod.stage).toBe('off');
    expect(prod.text).toBe('GPS выкл');
  });
});
