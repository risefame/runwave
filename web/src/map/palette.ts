/**
 * Единая палитра карты и игровых слоёв.
 * Стиль подложки собирается из этих цветов в ./style.ts.
 */
export const palette = {
  background: '#06070a',

  water: '#0a1b30',
  waterway: '#0c2138',

  land: {
    residential: '#0a0f0d',
    park: '#0c1a13',
    grass: '#0d1d16',
    pitch: '#0b1912',
    wood: '#091610',
    ice: '#0a0d12',
    glacier: '#0a0d12',
    aeroway: '#0d1014',
    pier: '#06070a',
  },

  building: {
    /** Стены: чуть светлее фона, но темнее крыш. */
    fill: '#0b0f14',
    /** Крыши и подсветка контура. */
    roof: '#11161e',
    outline: 'rgba(150, 190, 215, 0.22)',
    extrusion: '#0d1319',
    extrusionTop: '#16202a',
    extrusionHigh: '#202b38',
  },

  road: {
    path: '#3a4553',
    minor: '#1a1f26',
    minorOpacity: 0.9,
    major: '#272e38',
    majorSubtle: '#1e242c',
    majorCasing: '#0b0d10',
    motorway: '#303844',
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
    color: '#818b99',
    halo: '#04060a',
    water: '#4d6d8a',
    road: '#a6b1bf',
    motorway: '#b4bfca',
    city: '#c2ccd8',
    suburb: '#a3aebc',
    state: '#848e9c',
    country: '#919ba9',
    housenumber: '#5f6a77',
  },

  /** Точечные маркеры POI, для которых нет подходящего значка в спрайте. */
  poi: {
    transit: '#5b9bd5',
    water: '#4b9fbd',
    sport: '#5aa377',
    facility: '#8d97a6',
  },

  overlay: {
    territory: '#22e6ff',
    territoryOutline: '#d9fdff',
    territoryFlash: '#eaffff',
    /** Территории и следы тестового режима: фиолетовые, чтобы не путать с реальными. */
    territoryTest: '#b38bff',
    territoryTestOutline: '#e6dcff',
    trail: '#00e5ff',
    trailCore: '#d9fdff',
    trailCold: '#2f7bff',
    trailFast: '#9dffef',
    accuracy: '#22e6ff',
    route: '#8f7bff',
  },

  /** Чужие территории из Supabase: тёплый янтарный, чтобы не путать со своими. */
  online: {
    territory: '#ffb454',
    outline: '#ffe0a8',
  },
} as const;
