/**
 * Единая палитра карты и игровых слоёв.
 * Стиль подложки собирается из этих цветов в ./style.ts.
 */
export const palette = {
  background: '#06070a',

  water: '#0a1b30',
  waterway: '#0c2138',

  land: {
    residential: '#080a0d',
    park: '#08110e',
    wood: '#07100d',
    ice: '#0a0d12',
    glacier: '#0a0d12',
    aeroway: '#0d1014',
    pier: '#06070a',
  },

  building: {
    fill: '#050609',
    outline: 'rgba(150, 190, 215, 0.03)',
    extrusion: '#080a0d',
    extrusionTop: '#0c0f13',
  },

  road: {
    path: '#101318',
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
    color: '#737b87',
    halo: '#05070a',
    water: '#4d6d8a',
    road: '#6f7783',
    motorway: '#8a929e',
    city: '#8a929e',
    state: '#6c7480',
    country: '#7c8490',
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
