import { Capacitor } from '@capacitor/core';
import {
  BackgroundGeolocation,
  type CallbackError,
  type Location,
} from '@capgo/background-geolocation';

/** Точка геолокации в общем для браузера и нативной платформы виде. */
export interface GeoFix {
  lon: number;
  lat: number;
  accuracy: number;
  speed: number | null;
  heading: number | null;
  /** Время замера, мс с начала эпохи. */
  timestamp: number;
}

export type GeoErrorKind = 'denied' | 'timeout' | 'unavailable';

export class GeoError extends Error {
  readonly kind: GeoErrorKind;

  constructor(kind: GeoErrorKind) {
    super(kind);
    this.kind = kind;
  }
}

export const isNativeGeo = Capacitor.isNativePlatform();

export function isGeoSupported(): boolean {
  return isNativeGeo || 'geolocation' in navigator;
}

export interface GeoWatchOptions {
  /** На Android/iOS продолжать запись в фоне и показать уведомление. */
  background?: boolean;
  /** Для браузера: насколько старый замер допустим. */
  maximumAge?: number;
}

let watchGeneration = 0;
let activeNativeWatches = 0;
// Плагин не даёт запустить сервис, пока предыдущий stop не завершился.
// Все нативные команды идут через очередь, чтобы restart не терял запись.
let nativeQueue: Promise<unknown> = Promise.resolve();

function enqueueNative<T>(task: () => Promise<T>): Promise<T> {
  const next = nativeQueue.then(task, task);
  nativeQueue = next.catch(() => undefined);
  return next;
}

function fromBrowserPosition(reading: GeolocationPosition): GeoFix {
  return {
    lon: reading.coords.longitude,
    lat: reading.coords.latitude,
    accuracy: reading.coords.accuracy,
    speed: Number.isFinite(reading.coords.speed) ? reading.coords.speed : null,
    heading: Number.isFinite(reading.coords.heading) ? reading.coords.heading : null,
    timestamp: reading.timestamp,
  };
}

function fromNativeLocation(location: Location): GeoFix {
  return {
    lon: location.longitude,
    lat: location.latitude,
    accuracy: location.accuracy,
    speed:
      typeof location.speed === 'number' && Number.isFinite(location.speed) ? location.speed : null,
    heading:
      typeof location.bearing === 'number' && Number.isFinite(location.bearing)
        ? location.bearing
        : null,
    timestamp: typeof location.time === 'number' ? location.time : Date.now(),
  };
}

function browserErrorKind(error: GeolocationPositionError): GeoErrorKind {
  if (error.code === error.PERMISSION_DENIED) return 'denied';
  if (error.code === error.TIMEOUT) return 'timeout';
  return 'unavailable';
}

function nativeErrorKind(error: CallbackError): GeoErrorKind {
  const code = error.code ?? '';
  const message = error.message ?? '';
  if (
    code === 'NOT_AUTHORIZED' ||
    code === 'PERMISSION_DENIED' ||
    /permission|authoriz/i.test(message)
  ) {
    return 'denied';
  }
  return /timeout|time out/i.test(message) ? 'timeout' : 'unavailable';
}

function nativeOptions(background: boolean) {
  return {
    requestPermissions: true,
    stale: false,
    distanceFilter: 0,
    backgroundTitle: 'Runwave',
    ...(background ? { backgroundMessage: 'Runwave записывает бег' } : {}),
  };
}

/** Подписка на точки. Возвращает функцию остановки. */
export function watchGeo(
  onFix: (fix: GeoFix) => void,
  onError: (kind: GeoErrorKind) => void,
  options: GeoWatchOptions = {},
): () => void {
  const { background = false, maximumAge = 0 } = options;

  if (!isNativeGeo) {
    const id = navigator.geolocation.watchPosition(
      (reading) => onFix(fromBrowserPosition(reading)),
      (error) => onError(browserErrorKind(error)),
      { enableHighAccuracy: true, maximumAge, timeout: 15000 },
    );
    return () => navigator.geolocation.clearWatch(id);
  }

  const generation = ++watchGeneration;
  let stopped = false;
  activeNativeWatches += 1;

  const isCurrent = (): boolean => !stopped && generation === watchGeneration;

  void enqueueNative(() =>
    BackgroundGeolocation.start(nativeOptions(background), (location, error) => {
      if (!isCurrent()) return;
      if (error) {
        onError(nativeErrorKind(error));
        return;
      }
      if (location) onFix(fromNativeLocation(location));
    }),
  ).catch((error: unknown) => {
    if (isCurrent()) onError(nativeErrorKind(error as CallbackError));
  });

  return () => {
    if (stopped) return;
    stopped = true;
    activeNativeWatches = Math.max(0, activeNativeWatches - 1);
    if (activeNativeWatches === 0) {
      void enqueueNative(() => BackgroundGeolocation.stop()).catch(() => undefined);
    }
  };
}

export type GeoPermissionState = 'granted' | 'denied' | 'prompt' | 'unknown';

/**
 * Разрешение на геолокацию. В нативном режиме при отказе запрос повторяется:
 * системный диалог показывается только пока разрешение не отклонено окончательно.
 */
export async function ensureGeoPermission(): Promise<GeoPermissionState> {
  try {
    if (isNativeGeo) {
      const status = await enqueueNative(() =>
        BackgroundGeolocation.requestPermissions({ permissions: ['location'] }),
      );
      const location = status.location;
      if (location === 'granted') return 'granted';
      return location === 'denied' ? 'denied' : 'prompt';
    }

    if ('permissions' in navigator) {
      const status = await navigator.permissions.query({ name: 'geolocation' });
      return status.state;
    }
  } catch {
    // Permissions API может быть недоступен — останется системный запрос при замере.
  }
  return 'unknown';
}

/**
 * Приблизительный замер по сети: без высокой точности, за секунды.
 * Годится только для показа места на карте, не для трека.
 */
export function getGeoApprox(): Promise<GeoFix> {
  if (!isNativeGeo) {
    return new Promise((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (reading) => resolve(fromBrowserPosition(reading)),
        (error) => reject(new GeoError(browserErrorKind(error))),
        { enableHighAccuracy: false, maximumAge: 300000, timeout: 10000 },
      );
    });
  }
  return getGeoOnce();
}

/** Один замер: для кнопки «на мне», когда постоянная запись выключена. */
export function getGeoOnce(): Promise<GeoFix> {
  if (!isNativeGeo) {
    return new Promise((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (reading) => resolve(fromBrowserPosition(reading)),
        (error) => reject(new GeoError(browserErrorKind(error))),
        { enableHighAccuracy: true, maximumAge: 0, timeout: 12000 },
      );
    });
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = 0;

    const finish = (action: () => void): void => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timer);
      if (activeNativeWatches === 0) {
        void enqueueNative(() => BackgroundGeolocation.stop())
          .catch(() => undefined)
          .then(action);
        return;
      }
      action();
    };

    timer = window.setTimeout(() => finish(() => reject(new GeoError('timeout'))), 20000);

    void enqueueNative(() =>
      BackgroundGeolocation.start(nativeOptions(false), (location, error) => {
        if (error) {
          finish(() => reject(new GeoError(nativeErrorKind(error))));
          return;
        }
        if (location) finish(() => resolve(fromNativeLocation(location)));
      }),
    ).catch((error: unknown) => {
      finish(() => reject(new GeoError(nativeErrorKind(error as CallbackError))));
    });
  });
}
