import type { StyleSpecification } from 'maplibre-gl';
import rawStyle from './style.json';
import { palette } from './palette';

interface RawLayer {
  id: string;
  type: string;
  paint?: Record<string, unknown>;
  layout?: Record<string, unknown>;
  filter?: unknown;
  minzoom?: number;
  maxzoom?: number;
  [key: string]: unknown;
}

interface RawStyle {
  version: number;
  sources: Record<string, unknown>;
  sprite?: string;
  glyphs?: string;
  layers: RawLayer[];
}

const base = rawStyle as unknown as RawStyle;

/** Подписи только по-русски, с запасным вариантом из основного name. */
const RUSSIAN_NAME = ['coalesce', ['get', 'name:ru'], ['get', 'name']];

const MAJOR_ROADS = ['primary', 'secondary', 'tertiary', 'trunk'];

/** Пешеходные и беговые пути: в данных OpenMapTiles это подклассы class=path. */
const PEDESTRIAN_SUBCLASSES = ['footway', 'pedestrian', 'cycleway', 'steps', 'path', 'corridor'];

/** Значки, полезные бегуну: остановки, вода, спортплощадки, туалеты. */
const RUNNER_POI_CLASSES = [
  'bus',
  'drinking_water',
  'water',
  'toilets',
  'pitch',
  'playground',
  'sports_centre',
  'stadium',
  'swimming',
  'soccer',
];

/** Служебные и мелкие подписи, которые не нужны на игровой карте. */
const ALWAYS_HIDDEN = new Set(['road_oneway', 'road_oneway_opposite', 'place_other']);

/** Облегчённая версия: без мелкой зелени, аэропортов, железных дорог и мелких подписей. */
const LIGHT_HIDDEN = new Set([
  'landcover_ice_shelf',
  'landcover_glacier',
  'landcover_wood',
  'landuse_residential',
  'aeroway-taxiway',
  'aeroway-runway-casing',
  'aeroway-area',
  'aeroway-runway',
  'road_area_pier',
  'road_pier',
  'railway_transit',
  'railway_transit_dashline',
  'railway_minor',
  'railway_minor_dashline',
  'railway',
  'railway_dashline',
  'boundary_state',
  'place_village',
  'place_town',
  'place_state',
  'place_country_other',
  'place_country_minor',
  'water_name',
]);

function polygonMatch(): unknown {
  return ['match', ['geometry-type'], ['MultiPolygon', 'Polygon'], true, false];
}

function pointMatch(): unknown {
  return ['match', ['geometry-type'], ['MultiPoint', 'Point'], true, false];
}

function setPaint(layer: RawLayer, props: Record<string, unknown>): void {
  layer.paint = { ...(layer.paint ?? {}), ...props };
}

function setLayout(layer: RawLayer, props: Record<string, unknown>): void {
  layer.layout = { ...(layer.layout ?? {}), ...props };
}

function tuneLabel(
  layer: RawLayer,
  color: string,
  size?: unknown,
  font = 'Noto Sans Regular',
  haloWidth = 1.2,
): void {
  setLayout(layer, {
    'text-field': RUSSIAN_NAME,
    'text-font': [font],
    ...(size === undefined ? {} : { 'text-size': size }),
  });
  setPaint(layer, {
    'text-color': color,
    'text-halo-color': palette.label.halo,
    'text-halo-width': haloWidth,
    'text-halo-blur': 0,
  });
}

/** Газоны, скверы и зелень во дворах: еле заметный тёмно-зелёный. */
function grassLayer(): RawLayer {
  return {
    id: 'landcover_grass',
    type: 'fill',
    source: 'openmaptiles',
    'source-layer': 'landcover',
    minzoom: 12,
    filter: ['all', polygonMatch(), ['match', ['get', 'class'], ['grass'], true, false]],
    paint: {
      'fill-color': palette.land.grass,
      'fill-opacity': ['interpolate', ['linear'], ['zoom'], 12, 0.35, 15, 0.6, 18, 0.7],
    },
  };
}

/** Спортплощадки, дворовые газоны и стадионы из landuse. */
function landuseGreenLayer(): RawLayer {
  return {
    id: 'landuse_green',
    type: 'fill',
    source: 'openmaptiles',
    'source-layer': 'landuse',
    minzoom: 13,
    filter: [
      'all',
      polygonMatch(),
      ['match', ['get', 'class'], ['pitch', 'playground', 'stadium', 'track', 'garden', 'park'], true, false],
    ],
    paint: {
      'fill-color': palette.land.pitch,
      'fill-opacity': ['interpolate', ['linear'], ['zoom'], 13, 0.4, 16, 0.55],
    },
  };
}

/** Номера домов: мелко и приглушённо, только на крупном масштабе. */
function houseNumberLayer(): RawLayer {
  return {
    id: 'housenumber',
    type: 'symbol',
    source: 'openmaptiles',
    'source-layer': 'housenumber',
    minzoom: 17,
    layout: {
      'text-field': ['get', 'housenumber'],
      'text-font': ['Noto Sans Regular'],
      'text-size': ['interpolate', ['linear'], ['zoom'], 17, 9, 20, 11],
      'text-max-width': 5,
      'text-padding': 2,
    },
    paint: {
      'text-color': palette.label.housenumber,
      'text-halo-color': palette.label.halo,
      'text-halo-width': 1,
      'text-halo-blur': 0.3,
      'text-opacity': 0.9,
    },
  };
}

/** Только самые полезные для бегуна значки, из спрайта OpenFreeMap. */
function poiLayer(): RawLayer {
  return {
    id: 'poi-runner',
    type: 'symbol',
    source: 'openmaptiles',
    'source-layer': 'poi',
    minzoom: 16,
    filter: ['all', pointMatch(), ['match', ['get', 'class'], RUNNER_POI_CLASSES, true, false]],
    layout: {
      'icon-image': [
        'match',
        ['get', 'class'],
        'bus',
        'bus',
        'drinking_water',
        'drinking_water',
        'water',
        'water',
        'toilets',
        'toilets',
        'pitch',
        'pitch',
        'playground',
        'playground',
        'sports_centre',
        'pitch',
        'stadium',
        'pitch',
        'swimming',
        'swimming',
        'soccer',
        'soccer',
        'circle-stroked',
      ],
      'icon-size': ['interpolate', ['linear'], ['zoom'], 16, 0.4, 19, 0.6],
      'icon-padding': 3,
      'symbol-sort-key': ['coalesce', ['get', 'rank'], 99],
    },
    paint: {
      'icon-opacity': 0.6,
    },
  };
}

function insertBefore(layers: RawLayer[], beforeId: string, layer: RawLayer): void {
  const index = layers.findIndex((item) => item.id === beforeId);
  if (index === -1) layers.push(layer);
  else layers.splice(index, 0, layer);
}

function tuneLayer(layer: RawLayer, light: boolean): void {
  switch (layer.id) {
    case 'background':
      setPaint(layer, { 'background-color': palette.background });
      break;

    case 'water':
      setPaint(layer, { 'fill-color': palette.water, 'fill-antialias': false });
      break;

    case 'landcover_ice_shelf':
      setPaint(layer, { 'fill-color': palette.land.ice, 'fill-opacity': 0.5 });
      break;

    case 'landcover_glacier':
      setPaint(layer, { 'fill-color': palette.land.glacier, 'fill-opacity': 0.6 });
      break;

    case 'landuse_residential':
      // Дворы: тот же слой, но теперь виден и на крупном масштабе — совсем слабым тоном.
      layer.maxzoom = 22;
      setPaint(layer, {
        'fill-color': palette.land.residential,
        'fill-opacity': ['interpolate', ['linear'], ['zoom'], 6, 0.4, 12, 0.5, 16, 0.35],
      });
      break;

    case 'landcover_wood':
      if (layer.paint) delete layer.paint['fill-pattern'];
      setPaint(layer, { 'fill-color': palette.land.wood, 'fill-opacity': 0.75 });
      break;

    case 'landuse_park':
      setPaint(layer, { 'fill-color': palette.land.park, 'fill-opacity': 0.8 });
      break;

    case 'waterway':
      setPaint(layer, { 'line-color': palette.waterway, 'line-opacity': 0.8 });
      break;

    case 'water_name':
      tuneLabel(layer, palette.label.water, 11);
      break;

    case 'building':
      // В объёмном режиме крыши подсвечивает fill-extrusion, здесь — контур и заливка крыши.
      setPaint(layer, {
        'fill-color': light ? palette.building.fill : palette.building.roof,
        'fill-outline-color': light ? 'rgba(0, 0, 0, 0)' : palette.building.outline,
      });
      break;

    case 'aeroway-taxiway':
      setPaint(layer, { 'line-color': palette.road.taxiway });
      break;

    case 'aeroway-runway-casing':
      setPaint(layer, { 'line-color': palette.road.motorwayCasing });
      break;

    case 'aeroway-area':
      setPaint(layer, { 'fill-color': palette.land.aeroway });
      break;

    case 'aeroway-runway':
      setPaint(layer, { 'line-color': palette.road.runway });
      break;

    case 'road_area_pier':
      setPaint(layer, { 'fill-color': palette.land.pier });
      break;

    case 'road_pier':
      setPaint(layer, { 'line-color': palette.land.pier });
      break;

    case 'highway_path':
      // Пешеходные дорожки: светлее проезжей части, тонкий пунктир, с 15-го зума.
      layer.minzoom = 15;
      layer.filter = [
        'all',
        ['match', ['geometry-type'], ['LineString', 'MultiLineString'], true, false],
        [
          'any',
          ['==', ['get', 'class'], 'path'],
          ['match', ['get', 'subclass'], PEDESTRIAN_SUBCLASSES, true, false],
        ],
      ];
      setLayout(layer, { 'line-cap': 'round', 'line-join': 'round' });
      setPaint(layer, {
        'line-color': palette.road.path,
        'line-opacity': 0.85,
        'line-dasharray': [2, 2],
        'line-width': ['interpolate', ['linear'], ['zoom'], 15, 0.9, 18, 1.6, 20, 2.4],
      });
      break;

    case 'highway_minor':
      setPaint(layer, {
        'line-color': palette.road.minor,
        'line-opacity': palette.road.minorOpacity,
        'line-width': ['interpolate', ['exponential', 1.55], ['zoom'], 13, 1.2, 20, 14],
      });
      break;

    case 'highway_major_casing':
      setPaint(layer, {
        'line-color': palette.road.majorCasing,
        'line-width': ['interpolate', ['exponential', 1.3], ['zoom'], 10, 2.2, 20, 17],
      });
      break;

    case 'highway_major_inner':
      setPaint(layer, {
        'line-color': palette.road.major,
        'line-width': ['interpolate', ['exponential', 1.3], ['zoom'], 10, 1.5, 20, 14],
      });
      break;

    case 'highway_major_subtle':
      setPaint(layer, { 'line-color': palette.road.majorSubtle, 'line-opacity': 0.6 });
      break;

    case 'highway_motorway_casing':
      setPaint(layer, {
        'line-color': palette.road.motorwayCasing,
        'line-width': ['interpolate', ['exponential', 1.4], ['zoom'], 5.8, 0, 6, 2.4, 20, 30],
      });
      break;

    case 'highway_motorway_inner':
      setPaint(layer, {
        'line-color': palette.road.motorway,
        'line-width': ['interpolate', ['exponential', 1.4], ['zoom'], 4, 1.6, 6, 1.2, 20, 22],
      });
      break;

    case 'highway_motorway_subtle':
      setPaint(layer, { 'line-color': palette.road.motorway });
      break;

    case 'railway_transit':
    case 'railway_minor':
    case 'railway':
      setPaint(layer, { 'line-color': palette.road.rail });
      break;

    case 'railway_transit_dashline':
    case 'railway_minor_dashline':
    case 'railway_dashline':
      setPaint(layer, { 'line-color': palette.road.railDash });
      break;

    case 'boundary_state':
      setPaint(layer, { 'line-color': palette.boundary.state, 'line-opacity': 0.8 });
      break;

    case 'boundary_country_z0-4':
    case 'boundary_country_z5-':
      setPaint(layer, { 'line-color': palette.boundary.country, 'line-opacity': 0.85 });
      break;

    case 'highway_name_other':
      layer.filter = [
        'all',
        ['match', ['geometry-type'], ['LineString', 'MultiLineString'], true, false],
        ['match', ['get', 'class'], MAJOR_ROADS, true, false],
      ];
      setLayout(layer, { 'text-transform': 'none', 'symbol-spacing': 300 });
      tuneLabel(layer, palette.label.road, 11, 'Noto Sans Regular', 1.5);
      break;

    case 'highway_name_motorway':
      setLayout(layer, {
        'text-field': [
          'coalesce',
          ['get', 'name:ru'],
          ['get', 'name'],
          ['to-string', ['get', 'ref']],
        ],
        'text-font': ['Noto Sans Regular'],
        'text-size': 11,
      });
      setPaint(layer, {
        'text-color': palette.label.motorway,
        'text-halo-color': palette.label.halo,
        'text-halo-width': 1.5,
        'text-halo-blur': 0,
      });
      break;

    case 'place_suburb':
      layer.minzoom = 11;
      setLayout(layer, { 'text-transform': 'none', 'text-letter-spacing': 0.06 });
      tuneLabel(
        layer,
        palette.label.suburb,
        ['interpolate', ['linear'], ['zoom'], 11, 11, 14, 13],
        'Noto Sans Bold',
        1.6,
      );
      break;

    case 'place_village':
    case 'place_town':
      setLayout(layer, { 'text-transform': 'none' });
      tuneLabel(layer, palette.label.color, 11, 'Noto Sans Bold', 1.5);
      break;

    case 'place_city':
      setLayout(layer, { 'text-transform': 'none' });
      tuneLabel(
        layer,
        palette.label.city,
        ['interpolate', ['linear'], ['zoom'], 7, 11.5, 12, 14],
        'Noto Sans Bold',
        1.8,
      );
      break;

    case 'place_city_large':
      setLayout(layer, { 'text-transform': 'none' });
      tuneLabel(
        layer,
        palette.label.city,
        ['interpolate', ['linear'], ['zoom'], 2, 12.5, 6, 15, 11, 18],
        'Noto Sans Bold',
        1.8,
      );
      break;

    case 'place_state':
      tuneLabel(layer, palette.label.state, 11.5, 'Noto Sans Bold', 1.6);
      break;

    case 'place_country_other':
    case 'place_country_minor':
    case 'place_country_major':
      tuneLabel(layer, palette.label.country, undefined, 'Noto Sans Bold', 1.6);
      break;
  }
}

export interface MapStyleOptions {
  /** Облегчённая подложка для слабых телефонов. */
  light?: boolean;
}

export function buildMapStyle({ light = false }: MapStyleOptions = {}): StyleSpecification {
  const layers: RawLayer[] = [];

  for (const layer of base.layers) {
    if (ALWAYS_HIDDEN.has(layer.id)) continue;
    if (light && LIGHT_HIDDEN.has(layer.id)) continue;

    const tuned = JSON.parse(JSON.stringify(layer)) as RawLayer;
    tuneLayer(tuned, light);
    layers.push(tuned);
  }

  if (!light) {
    insertBefore(layers, 'waterway', grassLayer());
    insertBefore(layers, 'waterway', landuseGreenLayer());
    insertBefore(layers, 'highway_name_other', houseNumberLayer());
    insertBefore(layers, 'highway_name_other', poiLayer());
  }

  return {
    version: 8,
    sources: base.sources,
    sprite: base.sprite,
    glyphs: base.glyphs,
    layers,
  } as unknown as StyleSpecification;
}
