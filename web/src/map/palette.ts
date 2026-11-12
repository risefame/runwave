/**
 * Единая палитра карты и игровых слоёв.
 * Стиль подложки собирается из этих цветов в ./style.ts.
 */
export const palette = {
  background: '#06070a',

  water: '#0a1b30',
  waterway: '#0c2138',

  land: {
    residential: '#090c0b',
    park: '#0a1612',
    grass: '#0b1714',
    pitch: '#0a1411',
    wood: '#081310',
    ice: '#0a0d12',
    glacier: '#0a0d12',
    aeroway: '#0d1014',
    pier: '#06070a',
  },

  building: {
    /** Стены: чуть светлее фона, но темнее крыш. */
    fill: '#090b0f',
    /** Крыши и подсветка контура. */
    roof: '#0f1319',
    outline: 'rgba(150, 190, 215, 0.14)',
    extrusion: '#0b0f14',
    extrusionTop: '#18202a',
    extrusionHigh: '#222b37',
  },

  road: {
    path: '#2a313c',
    minor: '#16191f',
    minorOpacity: 0.85,
    major: '#232830',
    majorSubtle: '#1b2027',
    majorCasing: '#0b0d10',
    motorway: '#2b313a',
    motorwayCasing: '#0b0d10',
    rail: '#1a1e25',
    railDash: '#0a0c10',
    runway: '#1b2028',
    taxiway: '#141820',
  },

  boundary: {
    state: '#191d24',
    country: '#20262e',
  },

  label: {
    color: '#7d8695',
    halo: '#04060a',
    water: '#4d6d8a',
    road: '#9aa4b1',
    motorway: '#aab4c1',
    city: '#b3bdcb',
    suburb: '#96a1b0',
    state: '#7c8695',
    country: '#8b95a3',
    housenumber: '#57616d',
  },

  overlay: {
    territory: '#22e6ff',
    territoryOutline: '#d9fdff',
    territoryFlash: '#eaffff',
    trail: '#00e5ff',
    trailCore: '#d9fdff',
    route: '#8f7bff',
  },
} as const;
