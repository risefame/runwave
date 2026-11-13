import { Map as MapLibreMap, Marker, type GeoJSONSource } from 'maplibre-gl';
import type {
  Feature,
  FeatureCollection,
  LineString,
  MultiPolygon,
  Point,
  Polygon,
} from 'geojson';
import {
  boundaryCrossing,
  captureTerritory,
  distanceMeters,
  findBoundaryClosure,
  findLoopClosure,
  isInsideTerritory,
  MIN_AREA_M2,
  MIN_PERIMETER_M,
  outerRings,
  type LngLat,
  type TerritoryGeometry,
  type TerritoryShape,
} from './territory';
import { accuracyQuality, createGpsFilter, formatAccuracy } from './gpsFilter';
import {
  GeoError,
  getGeoOnce,
  isGeoSupported,
  isNativeGeo,
  watchGeo,
  type GeoErrorKind,
  type GeoFix,
} from './geolocation';
import { buildMapStyle } from './map/style';
import { palette } from './map/palette';
import {
  createClientRunId,
  describeRejection,
  ensureAnonymousSession,
  fetchCityAt,
  fetchLeaderboard,
  fetchOnlineTerritories,
  loadProfileName,
  saveProfileName,
  submitRun,
  type CityInfo,
  type LeaderboardRow,
  type RunPoint,
} from './online';
import 'maplibre-gl/dist/maplibre-gl.css';
import './style.css';

declare const __APP_VERSION__: string;
declare const __BUILD_DATE__: string;

const WORLD_CENTER: LngLat = [12, 22]; // мировой вид, пока позиция неизвестна
const WORLD_ZOOM = 1.4;
const RUN_SPEED = 3; // м/с
const TRAIL_MIN_STEP = 1.2; // м между точками следа
const MAX_FRAME_DT = 0.1; // с, защита от скачка после сворачивания вкладки
const GEO_STALE_MS = 2500;
const SEGMENT_GAP_MS = 15000; // с, пауза GPS, после которой трек начинается заново
const DISTANCE_BONUS_PER_METER = 2; // очков за каждый метр дистанции
const STORAGE_KEY = 'runwave:territories:v2';
const TEST_STORAGE_KEY = 'runwave:territories:test:v1';
const SETTINGS_KEY = 'runwave:settings:v1';
const BEST_RUN_KEY = 'runwave:best-run:v1';
const HINT_KEY = 'runwave:hint:v1';
const ACTIVE_RUN_KEY = 'runwave:active-run:v1';
const LAST_POSITION_KEY = 'runwave:last-position:v1';
const LAST_POSITION_SAVE_MS = 5000; // как часто запоминаем позицию для следующего запуска
const FLASH_DURATION_MS = 1100; // мс, анимация вспышки новой территории
const CAPTURE_BANNER_MS = 2600; // мс, сколько висит плашка захвата
const LABEL_MIN_MARGIN_PX = 8; // зазор между меткой площади и границей территории, px
const M_PER_MILE = 1609.344;
const M_PER_FOOT = 0.3048;
const BUILDINGS_3D_LAYER_ID = 'building-3d';
const DEFAULT_PITCH = 50; // наклон карты вне бега
const RUN_PITCH = 45; // наклон в режиме бега
const HEADING_MIN_STEP = 2; // м, минимальный шаг для пересчёта направления движения
const FOLLOW_STIFFNESS = 5; // плавность догона камеры за игроком
const TURN_STIFFNESS = 3; // плавность поворота камеры по направлению движения
const PLAYER_STIFFNESS = 9; // плавность движения маркера игрока
const HEADING_STIFFNESS = 6; // плавность доворота стрелки направления
const ACCURACY_PULSE_MS = 700; // период пульсации круга точности GPS

type Units = 'metric' | 'imperial';

/** Реальные забеги и тестовая имитация хранятся и считаются раздельно. */
type GameMode = 'real' | 'test';

interface RunSnapshot {
  area: number;
  score: number;
}

interface ActiveRunJournal {
  points: RunPoint[];
  rings: LngLat[][];
  /** UUID забега: повтор отправки должен вернуть тот же результат. */
  clientRunId: string;
  distance: number;
  time: number;
  savedAt: number;
}

interface StoredSettings {
  units?: Units;
  timeScale?: number;
  buildings3d?: boolean;
  lightMap?: boolean;
  rotateByHeading?: boolean;
  online?: boolean;
  geo?: boolean;
}

function readStoredSettings(): StoredSettings | null {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    return raw ? (JSON.parse(raw) as StoredSettings | null) : null;
  } catch {
    return null;
  }
}

function isWeakDevice(): boolean {
  const memory = (navigator as Navigator & { deviceMemory?: number }).deviceMemory;
  const cores = navigator.hardwareConcurrency;
  return (memory !== undefined && memory <= 4) || (cores !== undefined && cores <= 4);
}

/** Телефоны и планшеты: там реальный GPS включается по умолчанию. */
function isTouchDevice(): boolean {
  return (
    navigator.maxTouchPoints > 0 || window.matchMedia('(hover: none) and (pointer: coarse)').matches
  );
}

const initialSettings = readStoredSettings();
let buildings3d = initialSettings?.buildings3d === true;
let lightMap =
  typeof initialSettings?.lightMap === 'boolean' ? initialSettings.lightMap : isWeakDevice();
let rotateByHeading = initialSettings?.rotateByHeading === true;
let onlineEnabled = initialSettings?.online !== false;

/** Позиция с прошлого запуска: стартовая камера не должна прыгать в Москву. */
function readLastPosition(): LngLat | null {
  try {
    const raw = localStorage.getItem(LAST_POSITION_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { lon?: unknown; lat?: unknown } | null;
    if (!parsed) return null;
    const lon = Number(parsed.lon);
    const lat = Number(parsed.lat);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
    if (Math.abs(lon) > 180 || Math.abs(lat) > 90) return null;
    return [lon, lat];
  } catch {
    return null;
  }
}

const savedPosition = readLastPosition();

function byId<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Не найден элемент #${id}`);
  return element as T;
}

const distanceEl = byId('distance');
const timeEl = byId('time');
const speedEl = byId('speed');
const speedUnitEl = byId('speed-unit');
const scoreEl = byId('score');
const scoreLabelEl = byId('score-label');
const gpsPillEl = byId('gps-pill');
const gpsAccuracyEl = byId('gps-accuracy');
const runButton = byId<HTMLButtonElement>('btn-run');
const menuButton = byId<HTMLButtonElement>('btn-menu');
const menuCloseButton = byId<HTMLButtonElement>('btn-menu-close');
const menuEl = byId('menu');
const scrimEl = byId('scrim');
const locateButton = byId<HTMLButtonElement>('btn-locate');
const timescaleButton = byId<HTMLButtonElement>('btn-timescale');
const geoButton = byId<HTMLButtonElement>('btn-geo');
const geoDescEl = byId('geo-desc');
const buildings3dButton = byId<HTMLButtonElement>('btn-buildings-3d');
const lightMapButton = byId<HTMLButtonElement>('btn-light-map');
const rotateHeadingButton = byId<HTMLButtonElement>('btn-rotate-heading');
const unitsMetricButton = byId<HTMLButtonElement>('btn-units-metric');
const unitsImperialButton = byId<HTMLButtonElement>('btn-units-imperial');
const territoriesToggleButton = byId<HTMLButtonElement>('btn-territories');
const territoriesPanelEl = byId('territories-panel');
const hintCardEl = byId<HTMLDivElement>('hint-card');
const hintCloseButton = byId<HTMLButtonElement>('btn-hint-close');
const runHintEl = byId<HTMLDivElement>('run-hint');
const runHintStartButton = byId<HTMLButtonElement>('btn-run-hint-start');
const runHintCancelButton = byId<HTMLButtonElement>('btn-run-hint-cancel');
const geoHelpEl = byId<HTMLDivElement>('geo-help');
const geoHelpCloseButton = byId<HTMLButtonElement>('btn-geo-help-close');
const captureBannerEl = byId<HTMLDivElement>('capture-banner');
const captureBannerTitleEl = byId('capture-banner-title');
const captureBannerAreaEl = byId('capture-banner-area');
const summarySubtitleEl = byId('summary-subtitle');
const summaryEl = byId<HTMLDivElement>('run-summary');
const summaryCloseButton = byId<HTMLButtonElement>('btn-summary-close');
const sumDistanceEl = byId('sum-distance');
const sumTimeEl = byId('sum-time');
const sumAreaEl = byId('sum-area');
const sumScoreEl = byId('sum-score');
const statAreaEl = byId('stat-area');
const statCountEl = byId('stat-count');
const statBestEl = byId('stat-best');
const statTestEl = byId<HTMLParagraphElement>('stat-test');
const versionEl = byId('app-version');
const buildDateEl = byId('build-date');
const statusEl = byId('status');
const territoryCountEl = byId('territory-count');
const territoryListEl = byId<HTMLUListElement>('territory-list');
const territoryEmptyEl = byId('territory-empty');
const clearButton = byId<HTMLButtonElement>('btn-clear');
const onlineToggleButton = byId<HTMLButtonElement>('btn-online');
const onlineStatusEl = byId('online-status');
const onlineNameInput = byId<HTMLInputElement>('online-name');
const onlineNameButton = byId<HTMLButtonElement>('btn-online-name');
const onlineRefreshButton = byId<HTMLButtonElement>('btn-online-refresh');
const onlineCityEl = byId('online-city');
const onlineLeaderboardEl = byId<HTMLOListElement>('online-leaderboard');
const onlineGoalEl = byId('online-goal');
const onlineRecoverButton = byId<HTMLButtonElement>('btn-online-recover');
const sumOnlineEl = byId<HTMLParagraphElement>('sum-online');
const seasonPillEl = byId<HTMLButtonElement>('season-pill');
const seasonPillRankEl = byId('season-pill-rank');
const seasonPillPointsEl = byId('season-pill-points');

const hasSavedPosition = savedPosition !== null;

const map = new MapLibreMap({
  container: 'map',
  style: buildMapStyle({ light: lightMap }),
  center: savedPosition ?? [WORLD_CENTER[0], WORLD_CENTER[1]],
  zoom: hasSavedPosition ? 15.2 : WORLD_ZOOM,
  pitch: hasSavedPosition ? DEFAULT_PITCH : 0,
  bearing: hasSavedPosition ? -18 : 0,
  attributionControl: false,
  maxPitch: 70,
});

const playerEl = document.createElement('div');
playerEl.className = hasSavedPosition ? 'player' : 'player player--hidden';
playerEl.innerHTML =
  '<span class="player-halo"></span><span class="player-arrow"></span><span class="player-dot"></span>';
const playerArrowEl = (() => {
  const el = playerEl.querySelector<HTMLSpanElement>('.player-arrow');
  if (!el) throw new Error('Не найден маркер направления игрока');
  return el;
})();

const playerMarker = new Marker({ element: playerEl, anchor: 'center' })
  .setLngLat(savedPosition ?? [WORLD_CENTER[0], WORLD_CENTER[1]])
  .addTo(map);

// ——— Состояние ———

let position: LngLat = savedPosition
  ? [savedPosition[0], savedPosition[1]]
  : [WORLD_CENTER[0], WORLD_CENTER[1]];
let hasPosition = hasSavedPosition;
let displayPosition: LngLat = [position[0], position[1]];
let waypoints: LngLat[] = [];
const waypointMarkers: Marker[] = [];
let trail: LngLat[] = [];
let trailSpeeds: number[] = [];
let running = false;
let runMode: GameMode = 'real';
let timeScale = 1;
let units: Units = 'metric';
let runTime = 0; // секунды модельного времени
let distance = 0; // метры
let currentSpeed = 0; // м/с
// На телефоне по умолчанию реальный GPS, на десктопе — имитация кликами.
let geoActive = typeof initialSettings?.geo === 'boolean' ? initialSettings.geo : isTouchDevice();
let geoWatchStop: (() => void) | null = null;
let geoCentered = false;
let lastGeoFix = 0;
let lastGeoErrorAt = 0;
let accuracyMeters: number | null = null;
let segmentBreak = false;
let lastPositionSavedAt = 0;
const geoFilter = createGpsFilter();

let followPlayer = true;
let runSnapshot: RunSnapshot | null = null;
let bestRunDistance = 0;

let travelHeading = 0; // направление движения, градусы от севера
let displayHeading = 0; // сглаженный угол стрелки игрока
let pitchTarget: number | null = null; // куда плавно ведём наклон камеры

// ——— Онлайн-состояние ———

let onlineUserId: string | null = null;
let onlineReady = false;
let onlineBusy = false;
let onlineInitPromise: Promise<void> | null = null;
let onlineFetchTimer: number | null = null;
let onlineCityId: string | null = null;
let onlineCityName: string | null = null;
let leaderboardRows: LeaderboardRow[] = [];
let runPoints: RunPoint[] = [];
let runRings: LngLat[][] = [];
let runClientId = '';
let lastRunPointTime = 0;
let geoPermission: 'unknown' | 'granted' | 'denied' | 'prompt' = 'unknown';
let activeRunSavedAt = 0;

// ——— Геометрия ———

function lerp(a: LngLat, b: LngLat, t: number): LngLat {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

/** Направление движения по кратчайшей дуге, в градусах от севера. */
function headingBetween(from: LngLat, to: LngLat): number {
  const lat1 = (from[1] * Math.PI) / 180;
  const lat2 = (to[1] * Math.PI) / 180;
  const dLon = ((to[0] - from[0]) * Math.PI) / 180;
  const y = Math.sin(dLon) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

function shortestAngle(from: number, to: number): number {
  return ((((to - from) % 360) + 540) % 360) - 180;
}

/** Сколько метров на экране в одном пикселе на данной широте и зуме. */
function metersPerPixel(lat: number, zoom: number): number {
  return (156543.03392 * Math.cos((lat * Math.PI) / 180)) / 2 ** zoom;
}

function lineFeature(points: LngLat[]): Feature<LineString> {
  return {
    type: 'Feature',
    properties: {},
    geometry: { type: 'LineString', coordinates: points },
  };
}

/** Круг точности GPS: одна точка, радиус слоя считается в пикселях. */
function emptyPointCollection(): FeatureCollection<Point> {
  return { type: 'FeatureCollection', features: [] };
}

function shapeFeature(
  shape: TerritoryShape,
  properties: Record<string, number> = {},
): Feature<TerritoryShape> {
  return { type: 'Feature', properties, geometry: shape };
}

function emptyCollection(): FeatureCollection<TerritoryShape> {
  return { type: 'FeatureCollection', features: [] };
}

// ——— Источники и слои карты ———

/** След режется на отрезки: у каждого своя скорость — по ней красится линия. */
function trailCollection(): FeatureCollection<LineString> {
  const features: Feature<LineString>[] = [];
  for (let index = 1; index < trail.length; index += 1) {
    features.push({
      type: 'Feature',
      properties: { speed: trailSpeeds[index] ?? 0 },
      geometry: { type: 'LineString', coordinates: [trail[index - 1], trail[index]] },
    });
  }
  return { type: 'FeatureCollection', features };
}

function updateTrail(): void {
  const source = map.getSource('trail') as GeoJSONSource | undefined;
  if (!source) return;
  source.setData(trailCollection());
}

function resetTrail(): void {
  trail = [];
  trailSpeeds = [];
  updateTrail();
}

function updateRoute(): void {
  const source = map.getSource('route') as GeoJSONSource | undefined;
  if (!source) return;
  source.setData(lineFeature(waypoints.length > 1 ? waypoints : []));
}

function applyBuildings3D(): void {
  const existing = map.getLayer(BUILDINGS_3D_LAYER_ID);

  if (!buildings3d) {
    if (existing) map.removeLayer(BUILDINGS_3D_LAYER_ID);
    return;
  }

  if (existing || !map.getLayer('building')) return;

  // Объёмные дома ставим над дорогами, но под подписями, POI и игровыми слоями:
  // иначе крыши перекрывают номера домов и значки.
  const beforeId = map.getLayer('poi-runner-dot')
    ? 'poi-runner-dot'
    : map.getLayer('highway_name_other')
      ? 'highway_name_other'
      : map.getLayer('territories-fill')
        ? 'territories-fill'
        : undefined;
  map.addLayer(
    {
      id: BUILDINGS_3D_LAYER_ID,
      type: 'fill-extrusion',
      source: 'openmaptiles',
      'source-layer': 'building',
      minzoom: 14,
      filter: ['match', ['geometry-type'], ['MultiPolygon', 'Polygon'], true, false],
      paint: {
        // Низкие дома темнее, высокие светлее — масса домов читается как объём.
        // В лёгкой карте — плоский цвет без градиента, чтобы не грузить слабые телефоны.
        'fill-extrusion-color': lightMap
          ? palette.building.extrusion
          : [
              'interpolate',
              ['linear'],
              ['coalesce', ['get', 'render_height'], 8],
              0,
              palette.building.fill,
              8,
              palette.building.extrusion,
              20,
              palette.building.extrusionTop,
              50,
              palette.building.extrusionHigh,
            ],
        'fill-extrusion-vertical-gradient': !lightMap,
        'fill-extrusion-height': ['coalesce', ['get', 'render_height'], 8],
        'fill-extrusion-base': ['coalesce', ['get', 'render_min_height'], 0],
        'fill-extrusion-opacity': lightMap ? 0.85 : 0.95,
      },
    },
    beforeId,
  );
}

/** Игровые слои добавляются заново после каждой смены подложки. */
function addOverlayLayers(): void {
  if (!map.getSource('territories')) {
    map.addSource('territories', { type: 'geojson', data: territoryCollection() });
  }
  if (!map.getLayer('territories-fill')) {
    map.addLayer({
      id: 'territories-fill',
      type: 'fill',
      source: 'territories',
      paint: {
        // Тестовые территории из имитации — другим цветом, чтобы не путать с реальными.
        'fill-color': [
          'case',
          ['==', ['get', 'test'], 1],
          palette.overlay.territoryTest,
          palette.overlay.territory,
        ],
        'fill-opacity': 0.24,
      },
    });
  }
  if (!map.getLayer('territories-glow')) {
    map.addLayer({
      id: 'territories-glow',
      type: 'line',
      source: 'territories',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': [
          'case',
          ['==', ['get', 'test'], 1],
          palette.overlay.territoryTest,
          palette.overlay.territory,
        ],
        'line-width': 12,
        'line-blur': 14,
        'line-opacity': 0.55,
      },
    });
  }
  if (!map.getLayer('territories-outline')) {
    map.addLayer({
      id: 'territories-outline',
      type: 'line',
      source: 'territories',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': [
          'case',
          ['==', ['get', 'test'], 1],
          palette.overlay.territoryTestOutline,
          palette.overlay.territoryOutline,
        ],
        'line-width': 2,
        'line-opacity': 0.9,
      },
    });
  }

  if (!map.getSource('territory-flash')) {
    map.addSource('territory-flash', { type: 'geojson', data: emptyCollection() });
  }
  if (!map.getLayer('territory-flash-fill')) {
    map.addLayer({
      id: 'territory-flash-fill',
      type: 'fill',
      source: 'territory-flash',
      paint: {
        'fill-color': palette.overlay.territoryFlash,
        'fill-opacity': 0,
      },
    });
  }
  if (!map.getLayer('territory-flash-line')) {
    map.addLayer({
      id: 'territory-flash-line',
      type: 'line',
      source: 'territory-flash',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': palette.overlay.territory,
        'line-width': 2,
        'line-blur': 0,
        'line-opacity': 0,
      },
    });
  }

  // Круг точности GPS: полупрозрачный, пульсирует, радиус — в метрах точности.
  if (!map.getSource('gps-accuracy')) {
    map.addSource('gps-accuracy', { type: 'geojson', data: emptyPointCollection() });
  }
  if (!map.getLayer('gps-accuracy-circle')) {
    map.addLayer({
      id: 'gps-accuracy-circle',
      type: 'circle',
      source: 'gps-accuracy',
      paint: {
        'circle-color': palette.overlay.accuracy,
        'circle-opacity': 0.1,
        'circle-radius': 24,
        'circle-stroke-color': palette.overlay.accuracy,
        'circle-stroke-width': 1.5,
        'circle-stroke-opacity': 0.4,
      },
    });
  }

  if (!map.getSource('trail')) {
    map.addSource('trail', { type: 'geojson', data: trailCollection() });
  }
  if (!map.getLayer('trail-glow')) {
    map.addLayer({
      id: 'trail-glow',
      type: 'line',
      source: 'trail',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': palette.overlay.trail,
        'line-width': 18,
        'line-blur': 18,
        'line-opacity': 0.5,
      },
    });
  }
  if (!map.getLayer('trail-core')) {
    map.addLayer({
      id: 'trail-core',
      type: 'line',
      source: 'trail',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        // Цвет по скорости: медленнее — холоднее, быстрее — ярче.
        'line-color': [
          'interpolate',
          ['linear'],
          ['get', 'speed'],
          0,
          palette.overlay.trailCold,
          2,
          palette.overlay.trail,
          4,
          palette.overlay.trailFast,
          6,
          '#ffffff',
        ],
        'line-width': ['interpolate', ['linear'], ['get', 'speed'], 0, 2.6, 6, 4.6],
        'line-blur': 0.8,
        'line-opacity': 0.95,
      },
    });
  }

  if (!map.getSource('route')) {
    map.addSource('route', { type: 'geojson', data: lineFeature([]) });
  }
  if (!map.getLayer('route-line')) {
    map.addLayer({
      id: 'route-line',
      type: 'line',
      source: 'route',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': palette.overlay.route,
        'line-width': 2,
        'line-dasharray': [1.5, 1.5],
        'line-opacity': 0.7,
      },
    });
  }

  // Территории других игроков из Supabase. Свой слой — ниже локальных,
  // чтобы текущая игра всегда оставалась сверху.
  if (!map.getSource('online-territories')) {
    map.addSource('online-territories', { type: 'geojson', data: emptyCollection() });
  }
  const onlineBeforeId = map.getLayer('territories-fill') ? 'territories-fill' : undefined;
  if (!map.getLayer('online-territories-fill')) {
    map.addLayer(
      {
        id: 'online-territories-fill',
        type: 'fill',
        source: 'online-territories',
        paint: {
          'fill-color': palette.online.territory,
          'fill-opacity': 0.16,
        },
      },
      onlineBeforeId,
    );
  }
  if (!map.getLayer('online-territories-line')) {
    map.addLayer(
      {
        id: 'online-territories-line',
        type: 'line',
        source: 'online-territories',
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: {
          'line-color': palette.online.outline,
          'line-width': 1.4,
          'line-opacity': 0.55,
        },
      },
      onlineBeforeId,
    );
  }

  updateTrail();
  updateRoute();
  updateTerritories();
  updateFlashSource();
  applyBuildings3D();
  scheduleOnlineTerritories(0);
}

map.on('style.load', addOverlayLayers);
map.on('load', addOverlayLayers);
map.on('moveend', () => scheduleOnlineTerritories());

// ——— Территории ———

interface TerritoryRecord extends TerritoryGeometry {
  id: string;
  capturedAt: number;
}

interface StoredState {
  version: 2;
  territories: TerritoryRecord[];
  bonusSaved: number;
}

interface GameBucket {
  territories: TerritoryRecord[];
  bonusSaved: number; // очки за дистанцию, уже попавшие в сохранение
  bonusAnchorDistance: number; // дистанция на момент последней синхронизации бонуса
  labels: TerritoryLabel[];
}

const buckets: Record<GameMode, GameBucket> = {
  real: { territories: [], bonusSaved: 0, bonusAnchorDistance: 0, labels: [] },
  test: { territories: [], bonusSaved: 0, bonusAnchorDistance: 0, labels: [] },
};

/** Текущий режим: в беге он фиксируется на старте, вне бега зависит от GPS. */
function currentMode(): GameMode {
  return running ? runMode : geoActive ? 'real' : 'test';
}

let flash: { shape: TerritoryShape; startedAt: number } | null = null;

function isLngLat(value: unknown): value is LngLat {
  return (
    Array.isArray(value) &&
    value.length === 2 &&
    value.every((part) => typeof part === 'number' && Number.isFinite(part))
  );
}

function isRing(value: unknown): value is LngLat[] {
  return Array.isArray(value) && value.length >= 4 && value.every(isLngLat);
}

function isPolygonShape(value: unknown): value is Polygon {
  if (!value || typeof value !== 'object') return false;
  const geometry = value as Partial<Polygon>;
  return (
    geometry.type === 'Polygon' &&
    Array.isArray(geometry.coordinates) &&
    geometry.coordinates.length > 0 &&
    geometry.coordinates.every(isRing)
  );
}

function isMultiPolygonShape(value: unknown): value is MultiPolygon {
  if (!value || typeof value !== 'object') return false;
  const geometry = value as Partial<MultiPolygon>;
  return (
    geometry.type === 'MultiPolygon' &&
    Array.isArray(geometry.coordinates) &&
    geometry.coordinates.length > 0 &&
    geometry.coordinates.every(
      (rings) => Array.isArray(rings) && rings.length > 0 && rings.every(isRing),
    )
  );
}

function isTerritoryShape(value: unknown): value is TerritoryShape {
  return isPolygonShape(value) || isMultiPolygonShape(value);
}

function isTerritoryRecord(value: unknown): value is TerritoryRecord {
  if (!value || typeof value !== 'object') return false;
  const record = value as Partial<TerritoryRecord>;
  return (
    typeof record.id === 'string' &&
    isTerritoryShape(record.shape) &&
    isLngLat(record.centroid) &&
    typeof record.area === 'number' &&
    Number.isFinite(record.area) &&
    record.area > 0 &&
    typeof record.perimeter === 'number' &&
    Number.isFinite(record.perimeter) &&
    typeof record.capturedAt === 'number'
  );
}

function totalArea(mode: GameMode): number {
  return buckets[mode].territories.reduce((sum, territory) => sum + territory.area, 0);
}

/** Бонус за дистанцию: в текущем режиме он ещё растёт, в другом — уже сохранён. */
function distanceBonus(mode: GameMode): number {
  const bucket = buckets[mode];
  const live =
    mode === currentMode() ? Math.max(0, distance - bucket.bonusAnchorDistance) : 0;
  return Math.round(bucket.bonusSaved + live * DISTANCE_BONUS_PER_METER);
}

function totalScore(mode: GameMode): number {
  return Math.round(totalArea(mode) + distanceBonus(mode));
}

function syncBonus(mode: GameMode): void {
  const bucket = buckets[mode];
  const gained = Math.max(0, distance - bucket.bonusAnchorDistance) * DISTANCE_BONUS_PER_METER;
  bucket.bonusSaved = Math.round(bucket.bonusSaved + gained);
  bucket.bonusAnchorDistance = distance;
}

function formatArea(squareMeters: number): string {
  return `${Math.round(squareMeters).toLocaleString('ru-RU')} м²`;
}

function formatPerimeter(meters: number): string {
  return `${Math.round(meters).toLocaleString('ru-RU')} м`;
}

function territoryFeatures(mode: GameMode): Feature<TerritoryShape>[] {
  return buckets[mode].territories.map((territory) =>
    shapeFeature(territory.shape, {
      area: Math.round(territory.area),
      test: mode === 'test' ? 1 : 0,
    }),
  );
}

/** На карте видны и реальные, и тестовые территории — тестовые помечены цветом. */
function territoryCollection(): FeatureCollection<TerritoryShape> {
  return {
    type: 'FeatureCollection',
    features: [...territoryFeatures('real'), ...territoryFeatures('test')],
  };
}

function updateTerritories(): void {
  const source = map.getSource('territories') as GeoJSONSource | undefined;
  source?.setData(territoryCollection());
}

function updateFlashSource(): void {
  const source = map.getSource('territory-flash') as GeoJSONSource | undefined;
  if (!source) return;
  source.setData(flash ? shapeFeature(flash.shape) : emptyCollection());
}

function updateFlash(now: number): void {
  if (!flash) return;

  // Метка времени кадра может быть раньше момента захвата — держим прогресс в [0, 1],
  // иначе maplibre отвергает opacity > 1.
  const progress = Math.min(Math.max((now - flash.startedAt) / FLASH_DURATION_MS, 0), 1);
  const fade = 1 - progress;

  if (map.getLayer('territory-flash-fill')) {
    map.setPaintProperty('territory-flash-fill', 'fill-opacity', 0.9 * fade * fade);
  }
  if (map.getLayer('territory-flash-line')) {
    map.setPaintProperty('territory-flash-line', 'line-opacity', fade);
    map.setPaintProperty('territory-flash-line', 'line-width', 2 + 12 * progress);
    map.setPaintProperty('territory-flash-line', 'line-blur', 10 * fade);
  }

  if (progress >= 1) {
    flash = null;
    updateFlashSource();
  }
}

interface TerritoryLabel {
  marker: Marker;
  element: HTMLDivElement;
  shape: TerritoryShape;
}

/** Метка площади — в центре тяжести территории. */
function addTerritoryLabel(territory: TerritoryRecord, mode: GameMode): void {
  const element = document.createElement('div');
  element.className = mode === 'test' ? 'territory-label territory-label--test' : 'territory-label';
  element.textContent =
    mode === 'test' ? `${formatArea(territory.area)} · тест` : formatArea(territory.area);

  const marker = new Marker({ element, anchor: 'center' })
    .setLngLat(territory.centroid)
    .addTo(map);

  const label: TerritoryLabel = { marker, element, shape: territory.shape };
  buckets[mode].labels.push(label);
  fitLabel(label);
}

/** Метка скрывается, если на экране для неё нет места. */
function fitLabel(label: TerritoryLabel): void {
  const width = label.element.offsetWidth;
  const height = label.element.offsetHeight;
  if (!width || !height) return;

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const ring of outerRings(label.shape)) {
    for (const point of ring) {
      const projected = map.project([point[0], point[1]]);
      minX = Math.min(minX, projected.x);
      minY = Math.min(minY, projected.y);
      maxX = Math.max(maxX, projected.x);
      maxY = Math.max(maxY, projected.y);
    }
  }

  const fits =
    maxX - minX >= width + LABEL_MIN_MARGIN_PX * 2 &&
    maxY - minY >= height + LABEL_MIN_MARGIN_PX * 2;
  label.element.classList.toggle('territory-label--hidden', !fits);
}

function updateLabelVisibility(): void {
  for (const mode of ['real', 'test'] as const) {
    for (const label of buckets[mode].labels) fitLabel(label);
  }
}

map.on('moveend', updateLabelVisibility);
map.on('resize', updateLabelVisibility);

function renderScore(): void {
  const mode = currentMode();
  setText(scoreEl, formatScore(totalScore(mode)));
  setText(scoreLabelEl, mode === 'test' ? 'Очки · тест' : 'Очки');
  renderMenuStats();
}

function renderMenuStats(): void {
  // Реальная статистика: тестовые забеги и территории в неё не попадают.
  setText(statAreaEl, formatArea(totalArea('real')));
  setText(statCountEl, String(buckets.real.territories.length));
  setText(statBestEl, bestRunDistance > 0 ? formatDistance(bestRunDistance) : '—');

  const testArea = totalArea('test');
  const testCount = buckets.test.territories.length;
  statTestEl.hidden = testArea <= 0 && testCount === 0;
  if (!statTestEl.hidden) {
    setText(statTestEl, `Тест: ${formatArea(testArea)} · территорий ${testCount}`);
  }
}

function renderTerritoryList(): void {
  territoryListEl.replaceChildren();

  const entries = [
    ...buckets.real.territories.map((territory, index) => ({ territory, index, test: false })),
    ...buckets.test.territories.map((territory, index) => ({ territory, index, test: true })),
  ];

  for (let position = entries.length - 1; position >= 0; position -= 1) {
    const { territory, index, test } = entries[position];
    const item = document.createElement('li');
    item.className = test ? 'territory-item territory-item--test' : 'territory-item';

    const badge = document.createElement('span');
    badge.className = 'territory-index';
    badge.textContent = String(index + 1);

    const meta = document.createElement('div');
    meta.className = 'territory-meta';

    const area = document.createElement('span');
    area.className = 'territory-area';
    area.textContent = formatArea(territory.area);

    const perimeter = document.createElement('span');
    perimeter.className = 'territory-perimeter';
    perimeter.textContent = `периметр ${formatPerimeter(territory.perimeter)}`;

    meta.append(area, perimeter);

    if (test) {
      const testBadge = document.createElement('span');
      testBadge.className = 'territory-test';
      testBadge.textContent = 'тест';
      meta.append(testBadge);
    }

    item.append(badge, meta);
    territoryListEl.append(item);
  }

  setText(territoryCountEl, String(entries.length));
  territoryEmptyEl.hidden = entries.length > 0;
}

function saveBucket(mode: GameMode, key: string): void {
  const bucket = buckets[mode];
  // Пустой тестовый режим не держим в хранилище.
  if (mode === 'test' && bucket.territories.length === 0 && bucket.bonusSaved === 0) {
    try {
      localStorage.removeItem(key);
    } catch {
      // приватный режим: удалять нечего
    }
    return;
  }

  try {
    const state: StoredState = {
      version: 2,
      territories: bucket.territories,
      bonusSaved: bucket.bonusSaved,
    };
    localStorage.setItem(key, JSON.stringify(state));
  } catch {
    // приватный режим или переполнение хранилища: территории просто не переживут перезагрузку
  }
}

function saveState(): void {
  saveBucket('real', STORAGE_KEY);
  saveBucket('test', TEST_STORAGE_KEY);
}

function loadBucket(mode: GameMode, key: string): void {
  const bucket = buckets[mode];
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return;

    const parsed = JSON.parse(raw) as Partial<StoredState> | null;
    if (!parsed) return;

    if (Array.isArray(parsed.territories)) {
      bucket.territories = parsed.territories.filter(isTerritoryRecord);
    }
    if (typeof parsed.bonusSaved === 'number' && Number.isFinite(parsed.bonusSaved)) {
      bucket.bonusSaved = Math.max(0, Math.round(parsed.bonusSaved));
    }
  } catch {
    bucket.territories = [];
    bucket.bonusSaved = 0;
  }
}

function loadState(): void {
  loadBucket('real', STORAGE_KEY);
  loadBucket('test', TEST_STORAGE_KEY);
}

function loadSettings(): void {
  const parsed = readStoredSettings();
  if (!parsed) return;
  if (parsed.units === 'imperial') units = 'imperial';
  if (parsed.timeScale === 10) timeScale = 10;
}

function saveSettings(): void {
  try {
    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify({
        units,
        timeScale,
        buildings3d,
        lightMap,
        rotateByHeading,
        online: onlineEnabled,
        geo: geoActive,
      } satisfies StoredSettings),
    );
  } catch {
    // настройки просто не переживут перезагрузку
  }
}

function loadBestRun(): void {
  try {
    const raw = localStorage.getItem(BEST_RUN_KEY);
    if (!raw) return;
    const parsed = JSON.parse(raw) as { distance?: unknown } | null;
    if (parsed && typeof parsed.distance === 'number' && Number.isFinite(parsed.distance)) {
      bestRunDistance = Math.max(0, parsed.distance);
    }
  } catch {
    bestRunDistance = 0;
  }
}

function saveBestRun(): void {
  try {
    localStorage.setItem(BEST_RUN_KEY, JSON.stringify({ distance: Math.round(bestRunDistance) }));
  } catch {
    // рекорд просто не переживёт перезагрузку
  }
}

function ownedShapes(mode: GameMode): TerritoryShape[] {
  return buckets[mode].territories.map((territory) => territory.shape);
}

/** Размещает замкнутый контур: в очки идёт только новая площадь. */
function commitCapture(ring: LngLat[]): boolean {
  const mode = currentMode();
  const bucket = buckets[mode];
  // В очки идёт только площадь, которой у игрока ещё не было: свои территории
  // объединяются, и их площадь вычитается из нового контура.
  const captured = captureTerritory(ring, ownedShapes(mode), {
    minArea: MIN_AREA_M2,
    minPerimeter: MIN_PERIMETER_M,
  });
  // Контур мал или целиком лежит на своей территории.
  if (!captured) return false;

  const territory: TerritoryRecord = {
    ...captured,
    id: `territory-${Date.now()}-${bucket.territories.length + 1}`,
    capturedAt: Date.now(),
  };

  bucket.territories.push(territory);
  syncBonus(mode);
  addTerritoryLabel(territory, mode);
  updateTerritories();

  flash = { shape: captured.shape, startedAt: performance.now() };
  updateFlashSource();

  renderScore();
  renderTerritoryList();
  saveState();

  const testMark = mode === 'test' ? ' (тест)' : '';
  showCaptureBanner(captured.area, mode);
  playCaptureSound();
  showStatus(`Территория захвачена${testMark}: +${formatArea(captured.area)}`);
  if ('vibrate' in navigator) navigator.vibrate(30);

  // Тестовые забеги не уходят в онлайн и не смешиваются с реальными.
  if (running && onlineEnabled && mode === 'real') {
    runRings.push(ring.map(([lon, lat]) => [lon, lat] as LngLat));
    saveActiveRun(true);
  }

  // След сброшен: новый начнётся при выходе за границу уже обновлённой территории.
  resetTrail();
  return true;
}

/**
 * Пытается замкнуть текущий след.
 * Сначала — присоединение к своей границе (дуга плюс участок границы),
 * затем старые способы: возврат к началу и пересечение своего следа.
 */
function tryCaptureTerritory(): boolean {
  const owned = ownedShapes(currentMode());

  const boundaryClosure = findBoundaryClosure(trail, owned);
  if (boundaryClosure && commitCapture(boundaryClosure.ring)) return true;

  const closure = findLoopClosure(trail);
  return closure ? commitCapture(closure.ring) : false;
}

/**
 * Ведёт след: внутри своей территории следа нет, он начинается на границе
 * в момент выхода за неё. После неудачного возврата внутрь короткий выход
 * отбрасывается, чтобы шум GPS у границы не давал ложных захватов.
 */
function advanceTrail(previous: LngLat, next: LngLat): void {
  const owned = ownedShapes(currentMode());
  const hasTerritory = owned.length > 0;
  const inside = hasTerritory && isInsideTerritory(next, owned);

  if (trail.length === 0) {
    if (inside) return;

    // Точка выхода — пересечение шага с границей: след начинается ровно на ней.
    const start = (hasTerritory && boundaryCrossing(previous, next, owned)) || next;
    trail = [[start[0], start[1]]];
    trailSpeeds = [currentSpeed];
    updateTrail();
    return;
  }

  const tail = trail[trail.length - 1];
  if (distanceMeters(tail, next) < TRAIL_MIN_STEP) return;

  trail.push([next[0], next[1]]);
  trailSpeeds.push(currentSpeed);
  updateTrail();

  if (tryCaptureTerritory()) return;

  // Вернулись внутрь, но захват не засчитан: дуга была слишком короткой.
  if (inside) resetTrail();
}

function clearTerritories(mode: GameMode): void {
  const bucket = buckets[mode];
  bucket.territories = [];
  bucket.bonusSaved = 0;
  bucket.bonusAnchorDistance = distance;
  flash = null;

  for (const label of bucket.labels) label.marker.remove();
  bucket.labels.length = 0;

  updateTerritories();
  updateFlashSource();
  renderScore();
  renderTerritoryList();
  saveState();
}

// ——— Интерфейс ———

let statusTimer: number | undefined;

function showStatus(message: string): void {
  statusEl.textContent = message;
  statusEl.classList.add('visible');
  window.clearTimeout(statusTimer);
  statusTimer = window.setTimeout(() => statusEl.classList.remove('visible'), 4500);
}

// ——— Эффект захвата: плашка и звук ———

let captureBannerTimer: number | undefined;

function showCaptureBanner(area: number, mode: GameMode): void {
  captureBannerTitleEl.textContent =
    mode === 'test' ? 'Территория захвачена · тест' : 'Территория захвачена';
  captureBannerAreaEl.textContent = `+${formatArea(area)}`;
  captureBannerEl.hidden = false;
  captureBannerEl.classList.remove('visible');
  // Перезапуск анимации, если захваты идут подряд.
  void captureBannerEl.offsetWidth;
  captureBannerEl.classList.add('visible');

  window.clearTimeout(captureBannerTimer);
  captureBannerTimer = window.setTimeout(() => {
    captureBannerEl.classList.remove('visible');
    captureBannerEl.hidden = true;
  }, CAPTURE_BANNER_MS);
}

// Звук создаётся только после нажатия «Старт бега»: иначе iOS его блокирует.
let audioContext: AudioContext | null = null;

function unlockAudio(): void {
  try {
    const AudioCtor =
      window.AudioContext ??
      (window as Window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AudioCtor) return;
    audioContext ??= new AudioCtor();
    void audioContext.resume();
  } catch {
    audioContext = null;
  }
}

function playCaptureSound(): void {
  const context = audioContext;
  if (!context || context.state !== 'running') return;

  const start = context.currentTime;
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  oscillator.type = 'triangle';
  oscillator.frequency.setValueAtTime(660, start);
  oscillator.frequency.exponentialRampToValueAtTime(1180, start + 0.16);
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(0.16, start + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.32);
  oscillator.connect(gain);
  gain.connect(context.destination);
  oscillator.start(start);
  oscillator.stop(start + 0.34);
}

function setText(element: HTMLElement, text: string): void {
  if (element.textContent !== text) element.textContent = text;
}

const compactScoreFormat = new Intl.NumberFormat('ru-RU', {
  notation: 'compact',
  maximumFractionDigits: 1,
});

function formatScore(value: number): string {
  const rounded = Math.round(value);
  return rounded >= 10000 ? compactScoreFormat.format(rounded) : rounded.toLocaleString('ru-RU');
}

function formatDistance(meters: number): string {
  if (units === 'imperial') {
    const miles = meters / M_PER_MILE;
    return miles < 0.1 ? `${Math.round(meters / M_PER_FOOT)} фт` : `${miles.toFixed(2)} ми`;
  }
  return meters < 1000 ? `${Math.floor(meters)} м` : `${(meters / 1000).toFixed(2)} км`;
}

function formatSpeedValue(mps: number): string {
  return (units === 'imperial' ? mps * 2.2369363 : mps * 3.6).toFixed(1);
}

function formatTime(totalSeconds: number): string {
  const total = Math.floor(totalSeconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const mm = String(minutes).padStart(2, '0');
  const ss = String(seconds).padStart(2, '0');
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}

function renderHud(): void {
  setText(distanceEl, formatDistance(distance));
  setText(timeEl, formatTime(runTime));
  setText(speedEl, formatSpeedValue(currentSpeed));
}

function applyUnits(): void {
  unitsMetricButton.setAttribute('aria-pressed', String(units === 'metric'));
  unitsImperialButton.setAttribute('aria-pressed', String(units === 'imperial'));
  speedUnitEl.textContent = units === 'imperial' ? 'миль/ч' : 'км/ч';
  renderHud();
  renderMenuStats();
}

function applyTimeScale(): void {
  timescaleButton.setAttribute('aria-checked', String(timeScale === 10));
}

function applyGeoSwitch(): void {
  geoButton.setAttribute('aria-checked', String(geoActive));
  geoDescEl.textContent = geoActive
    ? 'Вкл.: GPS телефона. Не блокируй экран.'
    : 'Выкл.: имитация кликами, данные помечаются «тест»';
}

function applyMapSettings(): void {
  buildings3dButton.setAttribute('aria-checked', String(buildings3d));
  lightMapButton.setAttribute('aria-checked', String(lightMap));
  rotateHeadingButton.setAttribute('aria-checked', String(rotateByHeading));
}

// ——— Онлайн ———

function setOnlineStatus(text: string): void {
  onlineStatusEl.textContent = text;
}

function saveActiveRun(force = false): void {
  // В журнал для онлайна попадают только реальные забеги.
  if (!running || !onlineEnabled || currentMode() !== 'real') return;

  const now = Date.now();
  if (!force && now - activeRunSavedAt < 3000) return;
  activeRunSavedAt = now;

  const journal: ActiveRunJournal = {
    points: runPoints,
    rings: runRings,
    clientRunId: runClientId,
    distance,
    time: runTime,
    savedAt: now,
  };

  try {
    localStorage.setItem(ACTIVE_RUN_KEY, JSON.stringify(journal));
  } catch {
    // приватный режим — восстановление недоступно
  }
}

function readActiveRun(): ActiveRunJournal | null {
  try {
    const raw = localStorage.getItem(ACTIVE_RUN_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<ActiveRunJournal> | null;
    if (!parsed || !Array.isArray(parsed.points) || parsed.points.length < 2) return null;
    if (!Array.isArray(parsed.rings)) return null;

    return {
      points: parsed.points.filter(
        (point): point is RunPoint =>
          typeof point === 'object' &&
          point !== null &&
          Number.isFinite(point.lon) &&
          Number.isFinite(point.lat) &&
          Number.isFinite(point.t) &&
          Number.isFinite(point.accuracy),
      ),
      rings: parsed.rings,
      clientRunId:
        typeof parsed.clientRunId === 'string' && parsed.clientRunId
          ? parsed.clientRunId
          : createClientRunId(),
      distance: Number(parsed.distance ?? 0),
      time: Number(parsed.time ?? 0),
      savedAt: Number(parsed.savedAt ?? 0),
    };
  } catch {
    return null;
  }
}

function clearActiveRun(): void {
  try {
    localStorage.removeItem(ACTIVE_RUN_KEY);
  } catch {
    // ignore
  }
  onlineRecoverButton.hidden = true;
}

function restoreActiveRunButton(): void {
  const journal = readActiveRun();
  if (!journal || !onlineEnabled || !onlineReady) {
    onlineRecoverButton.hidden = true;
    return;
  }

  onlineRecoverButton.hidden = false;
  onlineRecoverButton.textContent = `Отправить сохранённый забег (${formatDistance(journal.distance)})`;
}

function setOnlineCity(city: CityInfo): void {
  onlineCityId = city.cityId;
  onlineCityName = city.cityName;

  if (!city.cityId) {
    onlineCityEl.textContent = 'Город: не определён — общий рейтинг';
    return;
  }

  const district = city.districtName ? ` · ${city.districtName}` : '';
  onlineCityEl.textContent = `Город: ${city.cityName ?? '—'}${district}`;
}

function updateSeasonHud(): void {
  if (!onlineEnabled || !onlineReady || leaderboardRows.length === 0) {
    seasonPillEl.hidden = true;
    onlineGoalEl.textContent =
      onlineEnabled && onlineReady ? 'Пробеги забег — и попадёшь в рейтинг.' : '';
    return;
  }

  const leader = leaderboardRows[0];
  const me = onlineUserId
    ? leaderboardRows.find((row) => row.userId === onlineUserId)
    : undefined;

  seasonPillEl.hidden = false;

  if (me) {
    seasonPillRankEl.textContent = `#${me.rank}`;
    seasonPillPointsEl.textContent = `${formatScore(me.points)} очк.`;
    seasonPillEl.title = `${onlineCityName ?? 'Сезон'} · место ${me.rank} из ${leaderboardRows.length}`;

    if (me.rank === 1) {
      onlineGoalEl.textContent = `Ты первый${onlineCityName ? ` в ${onlineCityName}` : ''}. Держи темп!`;
    } else {
      const third = leaderboardRows.find((row) => row.rank === 3);
      const target = me.rank <= 3 ? leader : third ?? leader;
      const gap = Math.max(0, target.points - me.points);
      onlineGoalEl.textContent =
        me.rank <= 3
          ? `До 1-го места: ${formatScore(gap)} очков.`
          : `До топ-3: ${formatScore(gap)} очков.`;
    }
  } else {
    seasonPillRankEl.textContent = '—';
    seasonPillPointsEl.textContent = 'Сезон';
    seasonPillEl.title = onlineCityName ? `Сезон · ${onlineCityName}` : 'Сезон';
    onlineGoalEl.textContent = leader
      ? `Лидер: ${leader.displayName} — ${formatScore(leader.points)} очков.`
      : '';
  }
}

function renderOnlineLeaderboard(rows: LeaderboardRow[]): void {
  leaderboardRows = rows;
  onlineLeaderboardEl.replaceChildren();

  if (rows.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'online-empty';
    empty.textContent = onlineEnabled
      ? 'Пока нет результатов. Пробеги забег — и попадёшь в рейтинг.'
      : 'Онлайн выключен.';
    onlineLeaderboardEl.append(empty);
    updateSeasonHud();
    return;
  }

  for (const row of rows.slice(0, 12)) {
    const item = document.createElement('li');
    item.className = 'online-row';
    if (row.rank <= 3) item.classList.add('online-row--top');
    if (onlineUserId !== null && row.userId === onlineUserId) {
      item.classList.add('online-row--me');
    }
    item.title = `${formatArea(row.areaM2)} · ${formatDistance(row.distanceM)} · забегов: ${row.runsCount}`;

    const rank = document.createElement('span');
    rank.className = 'online-rank';
    rank.textContent = String(row.rank);

    const name = document.createElement('span');
    name.className = 'online-name-cell';
    name.textContent = row.displayName;

    const points = document.createElement('span');
    points.className = 'online-points';
    points.textContent = String(Math.round(row.points));

    item.append(rank, name, points);
    onlineLeaderboardEl.append(item);
  }

  updateSeasonHud();
}

async function refreshOnlineTerritories(): Promise<string | null> {
  if (!onlineEnabled || !onlineReady) return null;

  const source = map.getSource('online-territories') as GeoJSONSource | undefined;
  if (!source) return null;

  const bounds = map.getBounds();
  const { data, error } = await fetchOnlineTerritories({
    west: bounds.getWest(),
    south: bounds.getSouth(),
    east: bounds.getEast(),
    north: bounds.getNorth(),
  });

  if (error) return error;
  if (data) source.setData(data);
  return null;
}

async function refreshLeaderboard(): Promise<string | null> {
  if (!onlineEnabled || !onlineReady) return null;

  const { rows, error } = await fetchLeaderboard(onlineCityId);
  if (error) return error;

  renderOnlineLeaderboard(rows);
  return null;
}

function scheduleOnlineTerritories(delay = 500): void {
  if (!onlineEnabled || !onlineReady) return;

  if (onlineFetchTimer !== null) window.clearTimeout(onlineFetchTimer);
  onlineFetchTimer = window.setTimeout(() => {
    onlineFetchTimer = null;
    void refreshOnlineTerritories().then((error) => {
      if (error) console.warn('online territories:', error);
    });
  }, delay);
}

async function initOnline(): Promise<void> {
  if (!onlineEnabled) return;
  if (onlineInitPromise) return onlineInitPromise;

  onlineInitPromise = (async () => {
    onlineReady = false;
    setOnlineStatus('Подключение к Supabase…');

    const session = await ensureAnonymousSession();
    if (!onlineEnabled) return;

    if (session.error || !session.userId) {
      setOnlineStatus(session.error ?? 'Не удалось войти в онлайн');
      return;
    }

    onlineUserId = session.userId;
    const name = await loadProfileName();
    onlineNameInput.value = name;
    // Анонимные пользователи, созданные до установки схемы, могли остаться без профиля.
    void saveProfileName(name);

    const city = await fetchCityAt(position[0], position[1]);
    if (city) {
      setOnlineCity(city);
    } else {
      onlineCityId = null;
      onlineCityEl.textContent = 'Город: —';
    }

    onlineReady = true;
    const [territoriesError, leaderboardError] = await Promise.all([
      refreshOnlineTerritories(),
      refreshLeaderboard(),
    ]);

    if (territoriesError ?? leaderboardError) {
      setOnlineStatus(territoriesError ?? leaderboardError ?? 'Онлайн недоступен');
    } else {
      setOnlineStatus(`Онлайн: ${name}`);
      restoreActiveRunButton();
    }
  })().finally(() => {
    onlineInitPromise = null;
  });

  return onlineInitPromise;
}

function applyOnline(): void {
  onlineToggleButton.setAttribute('aria-checked', String(onlineEnabled));
  onlineNameInput.disabled = !onlineEnabled;

  if (!onlineEnabled) {
    onlineReady = false;
    onlineUserId = null;
    leaderboardRows = [];
    setOnlineStatus('Офлайн: только локальная игра');
    onlineCityEl.textContent = 'Город: —';
    onlineGoalEl.textContent = '';
    seasonPillEl.hidden = true;
    onlineRecoverButton.hidden = true;
    renderOnlineLeaderboard([]);
    const source = map.getSource('online-territories') as GeoJSONSource | undefined;
    source?.setData(emptyCollection());
    return;
  }

  void initOnline();
}

function refreshOnlineNow(): void {
  if (!onlineEnabled) return;
  if (!onlineReady) {
    void initOnline();
    return;
  }

  setOnlineStatus('Обновление…');
  void Promise.all([refreshOnlineTerritories(), refreshLeaderboard()]).then(
    ([territoriesError, leaderboardError]) => {
      const error = territoriesError ?? leaderboardError;
      if (error) {
        setOnlineStatus(error);
      } else {
        setOnlineStatus(`Онлайн: ${onlineNameInput.value.trim() || 'Игрок'}`);
      }
    },
  );
}

function pushRunPoint(lon: number, lat: number, t: number, accuracy: number): void {
  if (!running || !onlineEnabled || !onlineReady || currentMode() !== 'real') return;
  if (!Number.isFinite(lon) || !Number.isFinite(lat) || !Number.isFinite(t)) return;
  if (t <= lastRunPointTime) return;
  if (runPoints.length >= 10_000) return;

  runPoints.push({ lon, lat, t, accuracy });
  lastRunPointTime = t;
  saveActiveRun();
}

function rejectionText(reason: string | undefined): string {
  return describeRejection(reason);
}

async function submitOnlineRun(
  points: RunPoint[],
  rings: LngLat[][],
  clientRunId = runClientId,
): Promise<boolean> {
  if (!onlineEnabled || !onlineReady || onlineBusy) return false;

  onlineBusy = true;
  setOnlineStatus('Отправка забега…');

  const { result, error } = await submitRun(
    points,
    rings.map((ring) => ring.map(([lon, lat]) => [lon, lat] as [number, number])),
    clientRunId || createClientRunId(),
  );
  onlineBusy = false;

  if (error) {
    setOnlineStatus(error);
    showStatus(`Онлайн: ${error}`);
    if (!summaryEl.hidden) {
      sumOnlineEl.textContent = 'Онлайн: забег не отправлен — проверь связь';
      sumOnlineEl.hidden = false;
    }
    return false;
  }
  if (!result) return false;

  if (result.status === 'rejected') {
    const message = rejectionText(result.reason);
    setOnlineStatus(`Забег не засчитан: ${message}`);
    showStatus(`Онлайн: ${message}`);
    if (!summaryEl.hidden) {
      sumOnlineEl.textContent = `Онлайн: забег не засчитан — ${message}`;
      sumOnlineEl.hidden = false;
    }
    return true;
  }

  if (result.cityId) {
    const origin = points[0];
    const city = await fetchCityAt(origin.lon, origin.lat);
    if (city) setOnlineCity(city);
  }

  await refreshLeaderboard();

  const pointsText = result.pointsAwarded ?? 0;
  const me = onlineUserId
    ? leaderboardRows.find((row) => row.userId === onlineUserId)
    : undefined;
  const rankText = me ? ` · место #${me.rank}` : '';
  const summaryText = `Онлайн: +${pointsText} очков${rankText}`;

  setOnlineStatus(summaryText);
  showStatus(`Онлайн: +${pointsText} очков, ${formatArea(result.areaM2 ?? 0)}`);
  if (!summaryEl.hidden) {
    sumOnlineEl.textContent = summaryText;
    sumOnlineEl.hidden = false;
  }
  sumOnlineEl.hidden = false;
  scheduleOnlineTerritories(0);
  return true;
}

async function saveOnlineName(): Promise<void> {
  if (!onlineEnabled) {
    setOnlineStatus('Онлайн выключен');
    return;
  }
  if (!onlineReady) {
    setOnlineStatus('Сначала дождись подключения к онлайн');
    return;
  }

  const error = await saveProfileName(onlineNameInput.value);
  if (error) {
    setOnlineStatus(error);
    return;
  }

  const name = onlineNameInput.value.trim() || 'Игрок';
  onlineNameInput.value = name;
  setOnlineStatus(`Онлайн: ${name}`);
  void refreshLeaderboard();
}

// ——— Меню ———

function openMenu(): void {
  menuEl.classList.add('open');
  menuEl.setAttribute('aria-hidden', 'false');
  menuButton.setAttribute('aria-expanded', 'true');
  scrimEl.hidden = false;
  requestAnimationFrame(() => scrimEl.classList.add('open'));
  menuCloseButton.focus({ preventScroll: true });
}

function closeMenu(): void {
  if (!menuEl.classList.contains('open')) return;
  menuEl.classList.remove('open');
  menuEl.setAttribute('aria-hidden', 'true');
  menuButton.setAttribute('aria-expanded', 'false');
  scrimEl.classList.remove('open');
  scrimEl.hidden = true;
  menuButton.focus({ preventScroll: true });
}

menuButton.addEventListener('click', openMenu);
menuCloseButton.addEventListener('click', closeMenu);
scrimEl.addEventListener('click', closeMenu);

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  if (!summaryEl.hidden) {
    hideRunSummary();
    return;
  }
  closeMenu();
});

territoriesToggleButton.addEventListener('click', () => {
  const expanded = territoriesToggleButton.getAttribute('aria-expanded') === 'true';
  territoriesToggleButton.setAttribute('aria-expanded', String(!expanded));
  territoriesPanelEl.hidden = expanded;
});

// ——— Итог бега ———

function showRunSummary(
  summary: {
    distance: number;
    time: number;
    area: number;
    score: number;
  },
  mode: GameMode,
): void {
  setText(sumDistanceEl, formatDistance(summary.distance));
  setText(sumTimeEl, formatTime(summary.time));
  setText(sumAreaEl, formatArea(summary.area));
  setText(sumScoreEl, `+${formatScore(summary.score)}`);
  setText(
    summarySubtitleEl,
    mode === 'test'
      ? 'Тестовый забег: не идёт в реальную статистику'
      : 'Хорошая работа',
  );
  sumOnlineEl.hidden = true;
  sumOnlineEl.textContent = '';
  summaryEl.hidden = false;
  summaryCloseButton.focus({ preventScroll: true });
}

function hideRunSummary(): void {
  if (summaryEl.hidden) return;
  summaryEl.hidden = true;
  runButton.focus({ preventScroll: true });
}

summaryCloseButton.addEventListener('click', hideRunSummary);
summaryEl.addEventListener('click', (event) => {
  if (event.target === summaryEl) hideRunSummary();
});

// ——— Экран не гаснет ———

// Нативная запись работает в фоне, Wake Lock там не нужен и только мешает.
if (isNativeGeo) document.body.classList.add('is-native');

const wakeLockApi: WakeLock | null = 'wakeLock' in navigator ? navigator.wakeLock : null;
let wakeLock: WakeLockSentinel | null = null;
let wakeLockWarned = false;

function warnWakeLock(message: string): void {
  if (wakeLockWarned) return;
  wakeLockWarned = true;
  showStatus(message);
}

async function requestWakeLock(): Promise<void> {
  if (isNativeGeo) return;
  if (!wakeLockApi) {
    // Запасной вариант: ничего не блокируем, но честно предупреждаем.
    warnWakeLock('Браузер не умеет держать экран включённым — он может погаснуть');
    return;
  }
  if (wakeLock || document.visibilityState !== 'visible') return;
  try {
    const lock = await wakeLockApi.request('screen');
    wakeLock = lock;
    lock.addEventListener('release', () => {
      if (wakeLock === lock) wakeLock = null;
    });
  } catch {
    warnWakeLock('Не удалось запретить блокировку экрана — он может погаснуть');
  }
}

async function releaseWakeLock(): Promise<void> {
  if (isNativeGeo) return;
  const lock = wakeLock;
  wakeLock = null;
  if (!lock) return;
  try {
    await lock.release();
  } catch {
    // уже отпущен системой
  }
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') {
    if (running) {
      saveActiveRun(true);
      // В браузере экран погас или вкладка ушла в фон: следующий трек начнётся заново.
      // В нативном приложении сервис продолжает писать точки в фоне.
      if (!isNativeGeo) breakSegment();
    }
    return;
  }

  if (!running) {
    if (geoActive && geoWatchStop === null) restartGeoWatch();
    return;
  }

  if (!isNativeGeo) {
    void requestWakeLock();
    breakSegment('GPS был на паузе, трек продолжен');
  }

  // После сна/свёрнутого приложения GPS-подписка могла остановиться.
  if (geoActive) restartGeoWatch();
});

document.addEventListener('freeze', () => {
  if (running) saveActiveRun(true);
});

// ——— Бег ———

function setRunning(value: boolean): void {
  running = value;
  runButton.textContent = running ? 'Стоп бега' : 'Старт бега';
  runButton.classList.toggle('running', running);
  // В беге камера наклоняется сильнее, вне бега возвращается к обзорному наклону.
  pitchTarget = running ? RUN_PITCH : DEFAULT_PITCH;
  if (running) {
    // Первые замеры после старта GPS ещё прогревается — фильтр их пропустит.
    geoFilter.reset();
    geoCentered = false;
    lastGeoFix = performance.now();
    segmentBreak = false;
    setFollow(true);
    void requestWakeLock();
  } else {
    currentSpeed = 0;
    segmentBreak = false;
    void releaseWakeLock();
  }
  // В нативном режиме уведомление о фоновой записи нужно только во время бега.
  if (isNativeGeo && geoActive) restartGeoWatch();
  renderScore();
}

function startRun(): void {
  const mode: GameMode = geoActive ? 'real' : 'test';

  syncBonus(mode);
  runMode = mode;
  runSnapshot = { area: totalArea(mode), score: totalScore(mode) };
  distance = 0;
  buckets[mode].bonusAnchorDistance = 0;
  runTime = 0;
  currentSpeed = 0;
  runPoints = [];
  runRings = [];
  runClientId = createClientRunId();
  lastRunPointTime = 0;
  clearActiveRun();
  activeRunSavedAt = 0;
  if (!hintCardEl.hidden) dismissFirstRunHint();
  setRunning(true);
  renderHud();
  renderScore();
}

function stopRun(): void {
  const mode = runMode;
  const snapshot = runSnapshot;
  const summary = snapshot
    ? {
        distance,
        time: runTime,
        area: Math.max(0, totalArea(mode) - snapshot.area),
        score: Math.max(0, totalScore(mode) - snapshot.score),
      }
    : null;

  saveActiveRun(true);

  const points = runPoints;
  const rings = runRings;
  runPoints = [];
  runRings = [];
  lastRunPointTime = 0;

  runSnapshot = null;
  setRunning(false);
  renderHud();

  if (!summary) return;
  // Рекорд считается только по реальным забегам.
  if (mode === 'real' && summary.distance >= 1 && summary.distance > bestRunDistance) {
    bestRunDistance = summary.distance;
    saveBestRun();
    renderMenuStats();
  }
  if (summary.distance >= 1) showRunSummary(summary, mode);

  const canSubmit =
    mode === 'real' && onlineEnabled && summary.distance >= 10 && points.length >= 2;
  if (!canSubmit) {
    clearActiveRun();
  } else {
    void submitOnlineRun(points, rings, runClientId).then((handled) => {
      if (handled) {
        clearActiveRun();
        runClientId = '';
      } else {
        restoreActiveRunButton();
      }
    });
  }
}

// ——— Подсказка перед стартом ———

let runHintSeen = false;

function requestStartRun(): void {
  unlockAudio();
  // В нативном приложении запись идёт в фоне — подсказка про экран не нужна.
  if (isNativeGeo) {
    startRun();
    return;
  }
  if (!runHintSeen) {
    runHintSeen = true;
    // Подсказки не должны накладываться друг на друга.
    hintCardEl.hidden = true;
    runHintEl.hidden = false;
    runHintStartButton.focus({ preventScroll: true });
    return;
  }
  startRun();
}

runButton.addEventListener('click', () => {
  if (running) stopRun();
  else requestStartRun();
});

runHintStartButton.addEventListener('click', () => {
  runHintEl.hidden = true;
  unlockAudio();
  startRun();
});

runHintCancelButton.addEventListener('click', () => {
  runHintEl.hidden = true;
  runButton.focus({ preventScroll: true });
});

// ——— Маршрут и движение ———

function placePlayer(next: LngLat): void {
  if (!hasPosition) {
    hasPosition = true;
    displayPosition = [next[0], next[1]];
    playerEl.classList.remove('player--hidden');
  }
  position = next;
}

function movePlayerTo(next: LngLat, forceHeading = false): void {
  const previous = position;
  placePlayer(next);
  if (forceHeading || distanceMeters(previous, next) >= HEADING_MIN_STEP) {
    travelHeading = headingBetween(previous, next);
  }
}

/**
 * Камера плавно догоняет игрока, в беге держит наклон 45°
 * и, если включён переключатель, разворачивается по направлению движения.
 */
function updateCamera(dt: number): void {
  if (map.isEasing()) return;

  const turn = 1 - Math.exp(-dt * TURN_STIFFNESS);

  let bearing = map.getBearing();
  if (running && rotateByHeading) {
    bearing += shortestAngle(bearing, travelHeading) * turn;
  }

  let pitch = map.getPitch();
  if (pitchTarget !== null) {
    pitch += (pitchTarget - pitch) * turn;
    if (Math.abs(pitchTarget - pitch) < 0.05) pitchTarget = null;
  }

  let center: { lng: number; lat: number } | null = null;
  if (followPlayer && hasPosition) {
    const current = map.getCenter();
    const follow = 1 - Math.exp(-dt * FOLLOW_STIFFNESS);
    const lng = current.lng + (displayPosition[0] - current.lng) * follow;
    const lat = current.lat + (displayPosition[1] - current.lat) * follow;
    if (distanceMeters([lng, lat], displayPosition) > 0.4) center = { lng, lat };
  }

  const bearingMoved = Math.abs(shortestAngle(map.getBearing(), bearing)) > 0.05;
  const pitchMoved = Math.abs(pitch - map.getPitch()) > 0.05;
  if (!center && !bearingMoved && !pitchMoved) return;

  map.jumpTo({
    ...(center ? { center } : {}),
    ...(bearingMoved ? { bearing } : {}),
    ...(pitchMoved ? { pitch } : {}),
  });
}

/** Маркер плавно догоняет позицию, стрелка доворачивается по направлению движения. */
function updatePlayerVisual(dt: number): void {
  if (!hasPosition) return;

  const follow = 1 - Math.exp(-dt * PLAYER_STIFFNESS);
  displayPosition = lerp(displayPosition, position, follow);
  // Резкий скачок (первый фикс, новый сегмент) не растягиваем в анимацию.
  if (distanceMeters(displayPosition, position) > 60) {
    displayPosition = [position[0], position[1]];
  }
  playerMarker.setLngLat(displayPosition);

  const turn = 1 - Math.exp(-dt * HEADING_STIFFNESS);
  displayHeading =
    (displayHeading + shortestAngle(displayHeading, travelHeading) * turn + 360) % 360;
  playerArrowEl.style.transform = `rotate(${displayHeading}deg)`;
}

function setFollow(value: boolean): void {
  followPlayer = value;
  locateButton.setAttribute('aria-pressed', String(value));
}

// Карту подвинули руками — автоследование выключается до нажатия «на мне».
map.on('dragstart', () => {
  if (followPlayer) setFollow(false);
});
map.on('rotatestart', () => {
  if (followPlayer) setFollow(false);
});

locateButton.addEventListener('click', () => {
  setFollow(true);

  if (geoActive) {
    map.easeTo({
      center: position,
      zoom: Math.max(map.getZoom(), 16),
      duration: 700,
    });
    return;
  }

  void locateMe(true);
});

function addWaypoint(point: LngLat): void {
  // Первый клик в режиме имитации просто ставит игрока на карту.
  if (!hasPosition) {
    placePlayer(point);
    setFollow(true);
    map.easeTo({ center: point, zoom: Math.max(map.getZoom(), 16), duration: 700 });
    return;
  }

  waypoints.push(point);

  const element = document.createElement('div');
  element.className = 'waypoint';
  waypointMarkers.push(new Marker({ element, anchor: 'center' }).setLngLat(point).addTo(map));

  updateRoute();
  if (!running) startRun();
}

function clearWaypoints(): void {
  waypoints = [];
  for (const marker of waypointMarkers) marker.remove();
  waypointMarkers.length = 0;
  updateRoute();
}

function dropWaypoint(): void {
  waypoints.shift();
  const marker = waypointMarkers.shift();
  marker?.remove();
  updateRoute();
}

function registerMove(next: LngLat, meters: number): void {
  const previous = position;
  // Шаг симуляции меньше порога 2 м, поэтому направление обновляем принудительно.
  movePlayerTo(next, true);
  if (!running) return;

  currentSpeed = RUN_SPEED;
  distance += meters;
  advanceTrail(previous, next);
}

function simulate(dt: number): void {
  let budget = RUN_SPEED * timeScale * dt;
  let moved = 0;

  while (budget > 0 && waypoints.length > 0) {
    const target = waypoints[0];
    const remaining = distanceMeters(position, target);

    if (remaining <= budget) {
      registerMove(target, remaining);
      budget -= remaining;
      moved += remaining;
      dropWaypoint();
    } else {
      const ratio = budget / remaining;
      registerMove(lerp(position, target, ratio), budget);
      moved += budget;
      budget = 0;
    }
  }

  currentSpeed = moved > 0 ? RUN_SPEED : 0;
}

map.on('click', (event) => {
  if (geoActive) {
    showStatus('В режиме реальной геолокации маршрут по клику отключён');
    return;
  }
  addWaypoint([event.lngLat.lng, event.lngLat.lat]);
});

// ——— Реальная геолокация ———

function renderGpsAccuracy(accuracy: number): void {
  const quality = accuracyQuality(accuracy);
  gpsPillEl.dataset.quality = quality;
  gpsAccuracyEl.textContent = formatAccuracy(accuracy);
  gpsPillEl.title =
    quality === 'good'
      ? 'Хороший сигнал GPS'
      : quality === 'fair'
        ? 'Средний сигнал GPS'
        : 'Слабый сигнал GPS: замеры отбрасываются';
}

function renderGpsOff(): void {
  accuracyMeters = null;
  updateAccuracyCircle();
  if (!geoActive) {
    gpsPillEl.dataset.quality = 'test';
    gpsAccuracyEl.textContent = 'Тест: имитация';
    gpsPillEl.title = 'Имитация кликами: территории и забеги помечаются «тест»';
    return;
  }
  gpsPillEl.dataset.quality = 'off';
  gpsAccuracyEl.textContent = 'GPS выкл';
  gpsPillEl.title = 'Замеры GPS не используются';
}

let accuracyCircleKey = '';

/** Круг точности GPS вокруг игрока: радиус в пикселях пересчитывается по зуму. */
function updateAccuracyCircle(): void {
  const source = map.getSource('gps-accuracy') as GeoJSONSource | undefined;
  if (!source) return;

  if (!geoActive || !hasPosition || accuracyMeters === null) {
    if (accuracyCircleKey !== '') {
      accuracyCircleKey = '';
      source.setData(emptyPointCollection());
    }
    return;
  }

  const zoom = Math.round(map.getZoom() * 10) / 10;
  const key = `${displayPosition[0].toFixed(6)},${displayPosition[1].toFixed(6)},${zoom},${Math.round(accuracyMeters)}`;
  if (key === accuracyCircleKey) return;
  accuracyCircleKey = key;

  const feature: Feature<Point> = {
    type: 'Feature',
    properties: {},
    geometry: { type: 'Point', coordinates: displayPosition },
  };
  source.setData({ type: 'FeatureCollection', features: [feature] });

  const radius = accuracyMeters / metersPerPixel(displayPosition[1], map.getZoom());
  map.setPaintProperty('gps-accuracy-circle', 'circle-radius', Math.max(6, Math.min(radius, 600)));
}

// Радиус круга задан в пикселях — при зуме его нужно пересчитать.
map.on('zoom', updateAccuracyCircle);

let lastAccuracyPulseAt = 0;

/** Пульсация круга точности: дешёвая, обновляется ~12 раз в секунду. */
function updateAccuracyPulse(now: number): void {
  if (now - lastAccuracyPulseAt < 80) return;
  lastAccuracyPulseAt = now;
  if (!map.getLayer('gps-accuracy-circle') || accuracyMeters === null || !geoActive) return;

  const pulse = 0.5 + 0.5 * Math.sin(now / ACCURACY_PULSE_MS);
  map.setPaintProperty('gps-accuracy-circle', 'circle-opacity', 0.08 + 0.06 * pulse);
  map.setPaintProperty('gps-accuracy-circle', 'circle-stroke-opacity', 0.28 + 0.28 * pulse);
}

function saveLastPosition(point: LngLat, force = false): void {
  const now = Date.now();
  if (!force && now - lastPositionSavedAt < LAST_POSITION_SAVE_MS) return;
  lastPositionSavedAt = now;
  try {
    localStorage.setItem(LAST_POSITION_KEY, JSON.stringify({ lon: point[0], lat: point[1] }));
  } catch {
    // приватный режим: стартовая камера просто останется мировой
  }
}

/** Новый сегмент трека: разрыв GPS не должен стать прямой линией и дистанцией. */
function breakSegment(message?: string): void {
  if (!running) return;
  segmentBreak = true;
  geoFilter.reset();
  currentSpeed = 0;
  resetTrail();
  if (message) showStatus(message);
}

function handlePosition(fix: GeoFix): void {
  const now = performance.now();
  const raw: LngLat = [fix.lon, fix.lat];

  // Сигнал пропадал (экран гас, вкладка спала) — трек продолжаем новым сегментом.
  if (running && lastGeoFix > 0 && now - lastGeoFix > SEGMENT_GAP_MS) {
    breakSegment('GPS был на паузе, трек продолжен');
  }
  lastGeoFix = now;
  renderGpsAccuracy(fix.accuracy);

  const result = geoFilter.push({ point: raw, accuracy: fix.accuracy, time: now });

  if (result.accepted && result.point) {
    const point = result.point;
    const firstFix = !geoCentered;
    const firstEver = !hasPosition;
    geoCentered = true;

    if (firstFix && followPlayer) {
      // Из мирового вида — плавный перелёт, а не прыжок через полкарты.
      if (firstEver) {
        map.flyTo({
          center: point,
          zoom: Math.max(map.getZoom(), 16),
          pitch: DEFAULT_PITCH,
          duration: 1600,
          essential: true,
        });
      } else {
        map.easeTo({ center: point, zoom: Math.max(map.getZoom(), 16), duration: 900 });
      }
    }

    const previous = position;
    const broke = segmentBreak;
    segmentBreak = false;
    // Направление берём из GPS, а если его нет — из последнего сегмента.
    movePlayerTo(point);

    const heading = fix.heading;
    if (typeof heading === 'number' && Number.isFinite(heading)) travelHeading = heading;

    if (broke) {
      // После паузы GPS маркер появляется на новом месте, а не едет через город.
      displayPosition = [point[0], point[1]];
    }

    if (running) {
      if (result.speedMps > 0) currentSpeed = currentSpeed * 0.6 + result.speedMps * 0.4;
      distance += broke ? 0 : result.stepMeters;
      advanceTrail(broke ? point : previous, point);
      pushRunPoint(point[0], point[1], fix.timestamp, fix.accuracy);
      saveLastPosition(point);
    }

    if (firstEver) {
      saveLastPosition(point, true);
      if (onlineEnabled && onlineReady) void refreshOnlineCity();
    }

    updateAccuracyCircle();
    return;
  }

  if (result.standing) currentSpeed = 0;
  else if (!running) placePlayer(raw);
}

function showGeoHelp(): void {
  geoHelpEl.hidden = false;
  geoHelpCloseButton.focus({ preventScroll: true });
}

function handleGeoError(kind: GeoErrorKind): void {
  if (kind === 'denied') {
    geoPermission = 'denied';
    showGeoHelp();
    stopGeolocation();
    return;
  }

  const now = performance.now();
  if (now - lastGeoErrorAt < 20000) return;
  lastGeoErrorAt = now;
  showStatus(kind === 'timeout' ? 'GPS не отвечает — ищем спутники…' : 'Не удалось получить геопозицию');
}

async function locateMe(center: boolean, silent = false): Promise<void> {
  if (!isGeoSupported()) {
    if (!silent) showStatus('Браузер не поддерживает геолокацию');
    return;
  }

  try {
    const fix = await getGeoOnce();
    geoPermission = 'granted';
    const point: LngLat = [fix.lon, fix.lat];

    if (!running) {
      placePlayer(point);
    }
    saveLastPosition(point, true);

    if (center) {
      map.easeTo({
        center: point,
        zoom: Math.max(map.getZoom(), 16),
        pitch: DEFAULT_PITCH,
        duration: 800,
      });
      setFollow(true);
    }

    if (!silent) showStatus('Геопозиция найдена');

    if (onlineEnabled && onlineReady) {
      void refreshOnlineCity();
    }
  } catch (error) {
    const kind = error instanceof GeoError ? error.kind : 'unavailable';
    if (kind === 'denied') {
      geoPermission = 'denied';
      showGeoHelp();
    }
    if (!silent) showStatus('Не удалось определить геопозицию');
  }
}

async function refreshOnlineCity(): Promise<void> {
  if (!onlineReady) return;
  const city = await fetchCityAt(position[0], position[1]);
  if (!city) return;
  setOnlineCity(city);
  void refreshLeaderboard();
}

function restartGeoWatch(): void {
  if (!isGeoSupported() || !geoActive) return;

  stopGeoWatch();
  geoWatchStop = watchGeo(handlePosition, handleGeoError, {
    background: running,
    maximumAge: 0,
  });
}

function stopGeoWatch(): void {
  if (geoWatchStop === null) return;
  geoWatchStop();
  geoWatchStop = null;
}

function startGeolocation(initial = false): void {
  if (!isGeoSupported()) {
    showStatus('Браузер не поддерживает геолокацию');
    if (!geoActive) renderGpsOff();
    return;
  }

  geoActive = true;
  accuracyMeters = null;
  geoFilter.reset();
  geoCentered = false;
  lastGeoFix = performance.now();
  currentSpeed = 0;
  segmentBreak = false;
  clearWaypoints();
  gpsPillEl.dataset.quality = 'waiting';
  gpsAccuracyEl.textContent = '±… м';
  gpsPillEl.title = 'Ждём первый замер GPS';
  applyGeoSwitch();
  setFollow(true);
  showStatus(
    hasPosition
      ? isNativeGeo
        ? 'GPS включён'
        : 'GPS включён. Не блокируй экран во время бега'
      : 'Определяем местоположение…',
  );
  renderScore();

  stopGeoWatch();
  geoWatchStop = watchGeo(handlePosition, handleGeoError, {
    background: running,
    maximumAge: initial ? 0 : 1000,
  });
}

function stopGeolocation(): void {
  stopGeoWatch();
  geoActive = false;
  accuracyMeters = null;
  geoFilter.reset();
  currentSpeed = 0;
  renderGpsOff();
  applyGeoSwitch();
  renderScore();
}

// ——— Кнопки меню ———

geoButton.addEventListener('click', () => {
  if (geoActive) stopGeolocation();
  else startGeolocation();
  saveSettings();
});

geoHelpCloseButton.addEventListener('click', () => {
  geoHelpEl.hidden = true;
  menuButton.focus({ preventScroll: true });
});

timescaleButton.addEventListener('click', () => {
  timeScale = timeScale === 1 ? 10 : 1;
  applyTimeScale();
  saveSettings();
});

unitsMetricButton.addEventListener('click', () => {
  units = 'metric';
  applyUnits();
  saveSettings();
});

unitsImperialButton.addEventListener('click', () => {
  units = 'imperial';
  applyUnits();
  saveSettings();
});

buildings3dButton.addEventListener('click', () => {
  buildings3d = !buildings3d;
  applyMapSettings();
  saveSettings();
  applyBuildings3D();
});

lightMapButton.addEventListener('click', () => {
  lightMap = !lightMap;
  applyMapSettings();
  saveSettings();
  map.setStyle(buildMapStyle({ light: lightMap }), { diff: false });
});

rotateHeadingButton.addEventListener('click', () => {
  rotateByHeading = !rotateByHeading;
  applyMapSettings();
  saveSettings();
});

onlineToggleButton.addEventListener('click', () => {
  onlineEnabled = !onlineEnabled;
  applyOnline();
  saveSettings();
});

onlineNameButton.addEventListener('click', () => {
  void saveOnlineName();
});

onlineRefreshButton.addEventListener('click', refreshOnlineNow);

onlineRecoverButton.addEventListener('click', () => {
  const journal = readActiveRun();
  if (!journal || journal.points.length < 2) {
    clearActiveRun();
    return;
  }
  if (!onlineReady) {
    setOnlineStatus('Сначала дождись подключения к онлайн');
    return;
  }

  onlineRecoverButton.disabled = true;
  void submitOnlineRun(journal.points, journal.rings, journal.clientRunId).then(
    (handled) => {
      onlineRecoverButton.disabled = false;
      if (handled) clearActiveRun();
    },
  );
});

seasonPillEl.addEventListener('click', () => {
  openMenu();
  requestAnimationFrame(() => {
    document
      .querySelector('[aria-label="Онлайн"]')
      ?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  });
});

clearButton.addEventListener('click', () => {
  const confirmed = window.confirm(
    'Сбросить все данные? Территории, очки и рекорд будут удалены без возможности вернуть.',
  );
  if (!confirmed) return;

  setRunning(false);
  runSnapshot = null;
  clearWaypoints();
  resetTrail();
  distance = 0;
  runTime = 0;
  currentSpeed = 0;
  geoFilter.reset();
  geoCentered = false;
  segmentBreak = false;
  bestRunDistance = 0;
  runPoints = [];
  runRings = [];
  lastRunPointTime = 0;
  clearActiveRun();

  clearTerritories('real'); // обнуляет и очки, и bonusAnchorDistance
  clearTerritories('test');
  renderHud();
  renderScore();
  saveBestRun();

  try {
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(TEST_STORAGE_KEY);
    localStorage.removeItem(BEST_RUN_KEY);
    localStorage.removeItem(LAST_POSITION_KEY);
  } catch {
    // приватный режим: удалять нечего
  }
  showStatus('Все данные сброшены');
});

// ——— Подсказка первого запуска ———

function setupFirstRunHint(): void {
  let seen = false;
  try {
    seen = localStorage.getItem(HINT_KEY) === '1';
  } catch {
    seen = true;
  }
  if (seen) return;
  hintCardEl.hidden = false;
}

function dismissFirstRunHint(): void {
  hintCardEl.hidden = true;
  try {
    localStorage.setItem(HINT_KEY, '1');
  } catch {
    // подсказка просто появится снова
  }
}

hintCloseButton.addEventListener('click', dismissFirstRunHint);

// ——— Версия сборки ———

function renderBuildInfo(): void {
  setText(versionEl, `v${__APP_VERSION__}`);
  const date = new Date(__BUILD_DATE__);
  setText(buildDateEl, Number.isNaN(date.getTime()) ? '—' : date.toLocaleDateString('ru-RU'));
}

// ——— Цикл симуляции ———

let lastFrameTime = performance.now();

function tick(now: number): void {
  const dt = Math.min((now - lastFrameTime) / 1000, MAX_FRAME_DT);
  lastFrameTime = now;

  if (running) {
    runTime += dt * timeScale;
    if (geoActive) {
      if (now - lastGeoFix > GEO_STALE_MS) currentSpeed = 0;
    } else {
      simulate(dt);
    }
  }

  updateFlash(now);
  updatePlayerVisual(dt);
  updateCamera(dt);
  updateAccuracyPulse(now);
  renderHud();
  requestAnimationFrame(tick);
}

// Бонус за дистанцию, набранный после последнего захвата, тоже должен пережить перезагрузку.
window.addEventListener('pagehide', () => {
  syncBonus(currentMode());
  saveState();
  saveActiveRun(true);
  if (geoActive && hasPosition) saveLastPosition(position, true);
  void releaseWakeLock();
});

loadState();
loadSettings();
loadBestRun();
for (const territory of buckets.real.territories) addTerritoryLabel(territory, 'real');
for (const territory of buckets.test.territories) addTerritoryLabel(territory, 'test');
renderScore();
renderTerritoryList();
renderHud();
applyUnits();
applyTimeScale();
applyGeoSwitch();
applyMapSettings();
applyOnline();
renderGpsOff();
renderBuildInfo();
setupFirstRunHint();
setFollow(true);

if (!isNativeGeo && 'permissions' in navigator) {
  void navigator.permissions
    .query({ name: 'geolocation' })
    .then((status) => {
      const applyPermission = (): void => {
        geoPermission =
          status.state === 'granted'
            ? 'granted'
            : status.state === 'denied'
              ? 'denied'
              : 'prompt';
        if (geoPermission === 'denied' && geoActive) showGeoHelp();
      };
      applyPermission();
      status.onchange = applyPermission;
    })
    .catch(() => {
      // Permissions API может быть недоступен — останется запрос при первом старте.
    });
}

// На телефоне сразу просим реальную позицию: старт не должен быть в чужом городе.
if (geoActive) {
  startGeolocation(true);
}

requestAnimationFrame(tick);

// TEMP: screenshot hook, will be removed
(window as unknown as { __rwMap?: unknown }).__rwMap = map;