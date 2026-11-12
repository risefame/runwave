import { Map as MapLibreMap, Marker, type GeoJSONSource } from 'maplibre-gl';
import type { Feature, FeatureCollection, LineString, MultiPolygon, Polygon } from 'geojson';
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
import { buildMapStyle } from './map/style';
import { palette } from './map/palette';
import 'maplibre-gl/dist/maplibre-gl.css';
import './style.css';

declare const __APP_VERSION__: string;
declare const __BUILD_DATE__: string;

const START_POINT: LngLat = [37.6173, 55.7558]; // Москва
const RUN_SPEED = 3; // м/с
const TRAIL_MIN_STEP = 1.2; // м между точками следа
const MAX_FRAME_DT = 0.1; // с, защита от скачка после сворачивания вкладки
const GEO_STALE_MS = 2500;
const DISTANCE_BONUS_PER_METER = 2; // очков за каждый метр дистанции
const STORAGE_KEY = 'runwave:territories:v2';
const SETTINGS_KEY = 'runwave:settings:v1';
const BEST_RUN_KEY = 'runwave:best-run:v1';
const HINT_KEY = 'runwave:hint:v1';
const FLASH_DURATION_MS = 1100; // мс, анимация вспышки новой территории
const LABEL_MIN_MARGIN_PX = 8; // зазор между меткой площади и границей территории, px
const M_PER_MILE = 1609.344;
const M_PER_FOOT = 0.3048;
const BUILDINGS_3D_LAYER_ID = 'building-3d';

type Units = 'metric' | 'imperial';

interface RunSnapshot {
  area: number;
  score: number;
}

interface StoredSettings {
  units?: Units;
  timeScale?: number;
  buildings3d?: boolean;
  lightMap?: boolean;
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

const initialSettings = readStoredSettings();
let buildings3d = initialSettings?.buildings3d === true;
let lightMap =
  typeof initialSettings?.lightMap === 'boolean' ? initialSettings.lightMap : isWeakDevice();

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
const unitsMetricButton = byId<HTMLButtonElement>('btn-units-metric');
const unitsImperialButton = byId<HTMLButtonElement>('btn-units-imperial');
const territoriesToggleButton = byId<HTMLButtonElement>('btn-territories');
const territoriesPanelEl = byId('territories-panel');
const hintCardEl = byId<HTMLDivElement>('hint-card');
const hintCloseButton = byId<HTMLButtonElement>('btn-hint-close');
const summaryEl = byId<HTMLDivElement>('run-summary');
const summaryCloseButton = byId<HTMLButtonElement>('btn-summary-close');
const sumDistanceEl = byId('sum-distance');
const sumTimeEl = byId('sum-time');
const sumAreaEl = byId('sum-area');
const sumScoreEl = byId('sum-score');
const statAreaEl = byId('stat-area');
const statCountEl = byId('stat-count');
const statBestEl = byId('stat-best');
const versionEl = byId('app-version');
const buildDateEl = byId('build-date');
const statusEl = byId('status');
const territoryCountEl = byId('territory-count');
const territoryListEl = byId<HTMLUListElement>('territory-list');
const territoryEmptyEl = byId('territory-empty');
const clearButton = byId<HTMLButtonElement>('btn-clear');

const map = new MapLibreMap({
  container: 'map',
  style: buildMapStyle({ light: lightMap }),
  center: START_POINT,
  zoom: 15.2,
  pitch: 50,
  bearing: -18,
  attributionControl: false,
  maxPitch: 70,
});

const playerEl = document.createElement('div');
playerEl.className = 'player';
playerEl.innerHTML = '<span class="player-halo"></span><span class="player-dot"></span>';

const playerMarker = new Marker({ element: playerEl, anchor: 'center' })
  .setLngLat(START_POINT)
  .addTo(map);

// ——— Состояние ———

let position: LngLat = [START_POINT[0], START_POINT[1]];
let waypoints: LngLat[] = [];
const waypointMarkers: Marker[] = [];
let trail: LngLat[] = [];
let running = false;
let timeScale = 1;
let units: Units = 'metric';
let runTime = 0; // секунды модельного времени
let distance = 0; // метры
let currentSpeed = 0; // м/с
let geoActive = false;
let geoWatchId: number | null = null;
let geoCentered = false;
let lastGeoFix = 0;
const geoFilter = createGpsFilter();

let followPlayer = true;
let runSnapshot: RunSnapshot | null = null;
let bestRunDistance = 0;

// ——— Геометрия ———

function lerp(a: LngLat, b: LngLat, t: number): LngLat {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

function lineFeature(points: LngLat[]): Feature<LineString> {
  return {
    type: 'Feature',
    properties: {},
    geometry: { type: 'LineString', coordinates: points },
  };
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

function updateTrail(): void {
  const source = map.getSource('trail') as GeoJSONSource | undefined;
  if (!source) return;
  source.setData(lineFeature(trail.length > 1 ? trail : []));
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

  // Слой домов вставляем под территории и след, чтобы игра всегда была сверху.
  const beforeId = map.getLayer('territories-fill') ? 'territories-fill' : undefined;
  map.addLayer(
    {
      id: BUILDINGS_3D_LAYER_ID,
      type: 'fill-extrusion',
      source: 'openmaptiles',
      'source-layer': 'building',
      minzoom: 14,
      filter: ['match', ['geometry-type'], ['MultiPolygon', 'Polygon'], true, false],
      paint: {
        'fill-extrusion-color': [
          'interpolate',
          ['linear'],
          ['coalesce', ['get', 'render_height'], 0],
          0,
          palette.building.fill,
          40,
          palette.building.extrusion,
          120,
          palette.building.extrusionTop,
        ],
        'fill-extrusion-height': ['coalesce', ['get', 'render_height'], 8],
        'fill-extrusion-base': ['coalesce', ['get', 'render_min_height'], 0],
        'fill-extrusion-opacity': 0.9,
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
        'fill-color': palette.overlay.territory,
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
        'line-color': palette.overlay.territory,
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
        'line-color': palette.overlay.territoryOutline,
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

  if (!map.getSource('trail')) {
    map.addSource('trail', { type: 'geojson', data: lineFeature([]) });
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
        'line-color': palette.overlay.trailCore,
        'line-width': 3.5,
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

  updateTrail();
  updateRoute();
  updateTerritories();
  updateFlashSource();
  applyBuildings3D();
}

map.on('style.load', addOverlayLayers);
map.on('load', addOverlayLayers);

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

let territories: TerritoryRecord[] = [];
let bonusSaved = 0; // очки за дистанцию, уже попавшие в сохранение
let bonusAnchorDistance = 0; // дистанция на момент последней синхронизации бонуса
let flash: { shape: TerritoryShape; startedAt: number } | null = null;
const territoryLabels: TerritoryLabel[] = [];

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

function totalArea(): number {
  return territories.reduce((sum, territory) => sum + territory.area, 0);
}

function currentDistanceBonus(): number {
  return Math.round(bonusSaved + (distance - bonusAnchorDistance) * DISTANCE_BONUS_PER_METER);
}

function totalScore(): number {
  return Math.round(totalArea() + currentDistanceBonus());
}

function syncBonus(): void {
  bonusSaved = currentDistanceBonus();
  bonusAnchorDistance = distance;
}

function formatArea(squareMeters: number): string {
  return `${Math.round(squareMeters).toLocaleString('ru-RU')} м²`;
}

function formatPerimeter(meters: number): string {
  return `${Math.round(meters).toLocaleString('ru-RU')} м`;
}

function territoryCollection(): FeatureCollection<TerritoryShape> {
  return {
    type: 'FeatureCollection',
    features: territories.map((territory) =>
      shapeFeature(territory.shape, { area: Math.round(territory.area) }),
    ),
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
function addTerritoryLabel(territory: TerritoryRecord): void {
  const element = document.createElement('div');
  element.className = 'territory-label';
  element.textContent = formatArea(territory.area);

  const marker = new Marker({ element, anchor: 'center' })
    .setLngLat(territory.centroid)
    .addTo(map);

  const label: TerritoryLabel = { marker, element, shape: territory.shape };
  territoryLabels.push(label);
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
  for (const label of territoryLabels) fitLabel(label);
}

map.on('moveend', updateLabelVisibility);
map.on('resize', updateLabelVisibility);

function renderScore(): void {
  setText(scoreEl, formatScore(totalScore()));
  renderMenuStats();
}

function renderMenuStats(): void {
  setText(statAreaEl, formatArea(totalArea()));
  setText(statCountEl, String(territories.length));
  setText(statBestEl, bestRunDistance > 0 ? formatDistance(bestRunDistance) : '—');
}

function renderTerritoryList(): void {
  territoryListEl.replaceChildren();

  for (let index = territories.length - 1; index >= 0; index -= 1) {
    const territory = territories[index];
    const item = document.createElement('li');
    item.className = 'territory-item';

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
    item.append(badge, meta);
    territoryListEl.append(item);
  }

  setText(territoryCountEl, String(territories.length));
  territoryEmptyEl.hidden = territories.length > 0;
}

function saveState(): void {
  try {
    const state: StoredState = { version: 2, territories, bonusSaved };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    // приватный режим или переполнение хранилища: территории просто не переживут перезагрузку
  }
}

function loadState(): void {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return;

    const parsed = JSON.parse(raw) as Partial<StoredState> | null;
    if (!parsed) return;

    if (Array.isArray(parsed.territories)) {
      territories = parsed.territories.filter(isTerritoryRecord);
    }
    if (typeof parsed.bonusSaved === 'number' && Number.isFinite(parsed.bonusSaved)) {
      bonusSaved = Math.max(0, Math.round(parsed.bonusSaved));
    }
  } catch {
    territories = [];
    bonusSaved = 0;
  }
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
      JSON.stringify({ units, timeScale, buildings3d, lightMap } satisfies StoredSettings),
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

function ownedShapes(): TerritoryShape[] {
  return territories.map((territory) => territory.shape);
}

/** Размещает замкнутый контур: в очки идёт только новая площадь. */
function commitCapture(ring: LngLat[]): boolean {
  // В очки идёт только площадь, которой у игрока ещё не было: свои территории
  // объединяются, и их площадь вычитается из нового контура.
  const captured = captureTerritory(ring, ownedShapes(), {
    minArea: MIN_AREA_M2,
    minPerimeter: MIN_PERIMETER_M,
  });
  // Контур мал или целиком лежит на своей территории.
  if (!captured) return false;

  const territory: TerritoryRecord = {
    ...captured,
    id: `territory-${Date.now()}-${territories.length + 1}`,
    capturedAt: Date.now(),
  };

  territories.push(territory);
  syncBonus();
  addTerritoryLabel(territory);
  updateTerritories();

  flash = { shape: captured.shape, startedAt: performance.now() };
  updateFlashSource();

  renderScore();
  renderTerritoryList();
  saveState();
  showStatus(`Территория захвачена: +${formatArea(captured.area)}`);

  // След сброшен: новый начнётся при выходе за границу уже обновлённой территории.
  trail = [];
  updateTrail();
  return true;
}

/**
 * Пытается замкнуть текущий след.
 * Сначала — присоединение к своей границе (дуга плюс участок границы),
 * затем старые способы: возврат к началу и пересечение своего следа.
 */
function tryCaptureTerritory(): boolean {
  const owned = ownedShapes();

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
  const owned = ownedShapes();
  const hasTerritory = owned.length > 0;
  const inside = hasTerritory && isInsideTerritory(next, owned);

  if (trail.length === 0) {
    if (inside) return;

    // Точка выхода — пересечение шага с границей: след начинается ровно на ней.
    const start = (hasTerritory && boundaryCrossing(previous, next, owned)) || next;
    trail = [[start[0], start[1]]];
    updateTrail();
    return;
  }

  const tail = trail[trail.length - 1];
  if (distanceMeters(tail, next) < TRAIL_MIN_STEP) return;

  trail.push([next[0], next[1]]);
  updateTrail();

  if (tryCaptureTerritory()) return;

  // Вернулись внутрь, но захват не засчитан: дуга была слишком короткой.
  if (inside) {
    trail = [];
    updateTrail();
  }
}

function clearTerritories(): void {
  territories = [];
  bonusSaved = 0;
  bonusAnchorDistance = distance;
  flash = null;

  for (const label of territoryLabels) label.marker.remove();
  territoryLabels.length = 0;

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
    ? 'Вкл.: GPS телефона'
    : 'Выкл.: имитация кликами по карте';
}

function applyMapSettings(): void {
  buildings3dButton.setAttribute('aria-checked', String(buildings3d));
  lightMapButton.setAttribute('aria-checked', String(lightMap));
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

function showRunSummary(summary: {
  distance: number;
  time: number;
  area: number;
  score: number;
}): void {
  setText(sumDistanceEl, formatDistance(summary.distance));
  setText(sumTimeEl, formatTime(summary.time));
  setText(sumAreaEl, formatArea(summary.area));
  setText(sumScoreEl, `+${formatScore(summary.score)}`);
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

const wakeLockApi: WakeLock | null = 'wakeLock' in navigator ? navigator.wakeLock : null;
let wakeLock: WakeLockSentinel | null = null;
let wakeLockWarned = false;

function warnWakeLock(message: string): void {
  if (wakeLockWarned) return;
  wakeLockWarned = true;
  showStatus(message);
}

async function requestWakeLock(): Promise<void> {
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
  if (document.visibilityState === 'visible' && running) void requestWakeLock();
});

// ——— Бег ———

function setRunning(value: boolean): void {
  running = value;
  runButton.textContent = running ? 'Стоп бега' : 'Старт бега';
  runButton.classList.toggle('running', running);
  if (running) {
    // Первые замеры после старта GPS ещё прогревается — фильтр их пропустит.
    geoFilter.reset();
    geoCentered = false;
    lastGeoFix = performance.now();
    void requestWakeLock();
  } else {
    currentSpeed = 0;
    void releaseWakeLock();
  }
}

function startRun(): void {
  syncBonus();
  runSnapshot = { area: totalArea(), score: totalScore() };
  distance = 0;
  bonusAnchorDistance = 0;
  runTime = 0;
  currentSpeed = 0;
  if (!hintCardEl.hidden) dismissFirstRunHint();
  setRunning(true);
  renderHud();
  renderScore();
}

function stopRun(): void {
  const snapshot = runSnapshot;
  const summary = snapshot
    ? {
        distance,
        time: runTime,
        area: Math.max(0, totalArea() - snapshot.area),
        score: Math.max(0, totalScore() - snapshot.score),
      }
    : null;

  runSnapshot = null;
  setRunning(false);
  renderHud();

  if (!summary) return;
  if (summary.distance >= 1 && summary.distance > bestRunDistance) {
    bestRunDistance = summary.distance;
    saveBestRun();
    renderMenuStats();
  }
  if (summary.distance >= 1) showRunSummary(summary);
}

runButton.addEventListener('click', () => {
  if (running) stopRun();
  else startRun();
});

// ——— Маршрут и движение ———

function placePlayer(next: LngLat): void {
  position = next;
  playerMarker.setLngLat(next);
}

function movePlayerTo(next: LngLat, smooth: boolean): void {
  placePlayer(next);
  if (!followPlayer) return;
  if (smooth) {
    map.easeTo({ center: next, duration: 700 });
  } else {
    map.jumpTo({ center: next });
  }
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
  map.easeTo({
    center: position,
    zoom: Math.max(map.getZoom(), 16),
    duration: 700,
  });
});

function addWaypoint(point: LngLat): void {
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
  movePlayerTo(next, false);
  if (!running) return;

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
  gpsPillEl.dataset.quality = 'off';
  gpsAccuracyEl.textContent = 'GPS выкл';
  gpsPillEl.title = 'Замеры GPS не используются';
}

function handlePosition(reading: GeolocationPosition): void {
  const now = performance.now();
  const raw: LngLat = [reading.coords.longitude, reading.coords.latitude];
  lastGeoFix = now;
  renderGpsAccuracy(reading.coords.accuracy);

  const result = geoFilter.push({ point: raw, accuracy: reading.coords.accuracy, time: now });

  if (result.accepted && result.point) {
    const point = result.point;
    if (!geoCentered) {
      geoCentered = true;
      if (followPlayer) {
        map.easeTo({ center: point, zoom: Math.max(map.getZoom(), 16), duration: 900 });
      }
    }
    const previous = position;
    movePlayerTo(point, true);

    if (running) {
      distance += result.stepMeters;
      advanceTrail(previous, point);
      if (result.speedMps > 0) currentSpeed = currentSpeed * 0.6 + result.speedMps * 0.4;
    }
    return;
  }

  if (result.standing) currentSpeed = 0;
  else if (!running) placePlayer(raw);
}

function handleGeoError(error: GeolocationPositionError): void {
  showStatus(
    error.code === error.PERMISSION_DENIED
      ? 'Доступ к геолокации запрещён'
      : 'Не удалось получить геопозицию',
  );
  stopGeolocation();
}

function startGeolocation(): void {
  if (!('geolocation' in navigator)) {
    showStatus('Браузер не поддерживает геолокацию');
    return;
  }

  geoActive = true;
  geoFilter.reset();
  geoCentered = false;
  lastGeoFix = performance.now();
  currentSpeed = 0;
  clearWaypoints();
  gpsPillEl.dataset.quality = 'waiting';
  gpsAccuracyEl.textContent = '±… м';
  gpsPillEl.title = 'Ждём первый замер GPS';
  applyGeoSwitch();
  setFollow(true);
  showStatus('Следуем за реальной геолокацией');

  geoWatchId = navigator.geolocation.watchPosition(handlePosition, handleGeoError, {
    enableHighAccuracy: true,
    maximumAge: 1000,
    timeout: 15000,
  });
}

function stopGeolocation(): void {
  if (geoWatchId !== null) navigator.geolocation.clearWatch(geoWatchId);
  geoWatchId = null;
  geoActive = false;
  geoFilter.reset();
  currentSpeed = 0;
  renderGpsOff();
  applyGeoSwitch();
}

// ——— Кнопки меню ———

geoButton.addEventListener('click', () => {
  if (geoActive) stopGeolocation();
  else startGeolocation();
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

clearButton.addEventListener('click', () => {
  const confirmed = window.confirm(
    'Сбросить все данные? Территории, очки и рекорд будут удалены без возможности вернуть.',
  );
  if (!confirmed) return;

  setRunning(false);
  runSnapshot = null;
  clearWaypoints();
  trail = [];
  distance = 0;
  runTime = 0;
  currentSpeed = 0;
  geoFilter.reset();
  geoCentered = false;
  bestRunDistance = 0;

  clearTerritories(); // обнуляет и очки, и bonusAnchorDistance
  updateTrail();
  renderHud();
  renderScore();
  saveBestRun();

  try {
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(BEST_RUN_KEY);
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
  renderHud();
  requestAnimationFrame(tick);
}

// Бонус за дистанцию, набранный после последнего захвата, тоже должен пережить перезагрузку.
window.addEventListener('pagehide', () => {
  syncBonus();
  saveState();
  void releaseWakeLock();
});

loadState();
loadSettings();
loadBestRun();
for (const territory of territories) addTerritoryLabel(territory);
renderScore();
renderTerritoryList();
renderHud();
applyUnits();
applyTimeScale();
applyGeoSwitch();
applyMapSettings();
renderGpsOff();
renderBuildInfo();
setupFirstRunHint();
setFollow(true);
requestAnimationFrame(tick);