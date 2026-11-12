import type { StyleSpecification } from 'maplibre-gl';
import rawStyle from './style.json';
import { palette } from './palette';

interface RawLayer {
  id: string;
  type: string;
  paint?: Record<string, unknown>;
  layout?: Record<string, unknown>;
  filter?: unknown;
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
  'highway_path',
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

function setPaint(layer: RawLayer, props: Record<string, unknown>): void {
  layer.paint = { ...(layer.paint ?? {}), ...props };
}

function setLayout(layer: RawLayer, props: Record<string, unknown>): void {
  layer.layout = { ...(layer.layout ?? {}), ...props };
}

function tuneLabel(layer: RawLayer, color: string, size?: number): void {
  setLayout(layer, {
    'text-field': RUSSIAN_NAME,
    'text-font': ['Noto Sans Regular'],
    ...(size === undefined ? {} : { 'text-size': size }),
  });
  setPaint(layer, {
    'text-color': color,
    'text-halo-color': palette.label.halo,
    'text-halo-width': 1.2,
    'text-halo-blur': 0,
  });
}

function tuneLayer(layer: RawLayer): void {
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
      setPaint(layer, { 'fill-color': palette.land.residential, 'fill-opacity': 0.5 });
      break;

    case 'landcover_wood':
      if (layer.paint) delete layer.paint['fill-pattern'];
      setPaint(layer, { 'fill-color': palette.land.wood, 'fill-opacity': 0.5 });
      break;

    case 'landuse_park':
      setPaint(layer, { 'fill-color': palette.land.park });
      break;

    case 'waterway':
      setPaint(layer, { 'line-color': palette.waterway, 'line-opacity': 0.8 });
      break;

    case 'water_name':
      tuneLabel(layer, palette.label.water, 11);
      break;

    case 'building':
      setPaint(layer, {
        'fill-color': palette.building.fill,
        'fill-outline-color': palette.building.outline,
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
      setPaint(layer, { 'line-color': palette.road.path, 'line-opacity': 0.55 });
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
      tuneLabel(layer, palette.label.road, 10);
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
      });
      setPaint(layer, { 'text-color': palette.label.motorway });
      break;

    case 'place_suburb':
      layer.minzoom = 11;
      tuneLabel(layer, palette.label.color, 10);
      break;

    case 'place_village':
    case 'place_town':
      tuneLabel(layer, palette.label.color, 10);
      break;

    case 'place_city':
      tuneLabel(layer, palette.label.city, 11);
      break;

    case 'place_city_large':
      tuneLabel(layer, palette.label.city, 14);
      break;

    case 'place_state':
      tuneLabel(layer, palette.label.state, 11);
      break;

    case 'place_country_other':
    case 'place_country_minor':
    case 'place_country_major':
      tuneLabel(layer, palette.label.country);
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
    tuneLayer(tuned);
    layers.push(tuned);
  }

  return {
    version: 8,
    sources: base.sources,
    sprite: base.sprite,
    glyphs: base.glyphs,
    layers,
  } as unknown as StyleSpecification;
}
