/**
 * Единая палитра карты и игровых слоёв.
 * Стиль подложки собирается из этих цветов в ./style.ts.
 * Для светлой темы используется отдельный набор цветов.
 */
export type Theme = 'light' | 'dark';

export interface MapPalette {
  background: string;

  water: string;
  waterway: string;

  land: {
    residential: string;
    park: string;
    grass: string;
    pitch: string;
    wood: string;
    ice: string;
    glacier: string;
    aeroway: string;
    pier: string;
  };

  building: {
    /** Стены: чуть светлее фона, но темнее крыш. */
    fill: string;
    /** Крыши и подсветка контура. */
    roof: string;
    outline: string;
    extrusion: string;
    extrusionTop: string;
    extrusionHigh: string;
  };

  road: {
    path: string;
    minor: string;
    minorOpacity: number;
    major: string;
    majorSubtle: string;
    majorCasing: string;
    motorway: string;
    motorwayCasing: string;
    rail: string;
    railDash: string;
    runway: string;
    taxiway: string;
  };

  boundary: {
    state: string;
    country: string;
  };

  label: {
    color: string;
    halo: string;
    water: string;
    road: string;
    motorway: string;
    city: string;
    suburb: string;
    state: string;
    country: string;
    housenumber: string;
  };

  /** Точечные маркеры POI, для которых нет подходящего значка в спрайте. */
  poi: {
    transit: string;
    water: string;
    sport: string;
    facility: string;
  };

  overlay: {
    territory: string;
    territoryOutline: string;
    territoryFlash: string;
    /** Территории и следы тестового режима: фиолетовые, чтобы не путать с реальными. */
    territoryTest: string;
    territoryTestOutline: string;
    trail: string;
    trailCore: string;
    trailCold: string;
    trailFast: string;
    /** Цвет самого быстрого темпа: в тёмной теме белый, в светлой — глубокий бирюзовый. */
    trailMax: string;
    accuracy: string;
    route: string;
  };

  /** Чужие территории из Supabase: тёплый янтарный, чтобы не путать со своими. */
  online: {
    territory: string;
    outline: string;
  };
}

export const darkPalette: MapPalette = {
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
    fill: '#0b0f14',
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
    territoryTest: '#b38bff',
    territoryTestOutline: '#e6dcff',
    trail: '#00e5ff',
    trailCore: '#d9fdff',
    trailCold: '#2f7bff',
    trailFast: '#9dffef',
    trailMax: '#ffffff',
    accuracy: '#22e6ff',
    route: '#8f7bff',
  },

  online: {
    territory: '#ffb454',
    outline: '#ffe0a8',
  },
};

export const lightPalette: MapPalette = {
  background: '#eef2f7',

  water: '#b3d6ef',
  waterway: '#a5cce8',

  land: {
    residential: '#e7ecf2',
    park: '#d6ead9',
    grass: '#d9ecdd',
    pitch: '#cfe6d4',
    wood: '#d2e6d5',
    ice: '#f1f6fb',
    glacier: '#eef4fa',
    aeroway: '#e3e9f0',
    pier: '#dfe6ed',
  },

  building: {
    fill: '#e1e7ee',
    roof: '#dde4ec',
    outline: 'rgba(90, 112, 136, 0.25)',
    extrusion: '#dde4ec',
    extrusionTop: '#e7edf4',
    extrusionHigh: '#f0f4f9',
  },

  road: {
    path: '#b7c2cf',
    minor: '#ffffff',
    minorOpacity: 1,
    major: '#ffffff',
    majorSubtle: '#f4f8fc',
    majorCasing: '#d2dbe5',
    motorway: '#ffe0a8',
    motorwayCasing: '#e9c484',
    rail: '#c6d0db',
    railDash: '#eef3f8',
    runway: '#e4eaf1',
    taxiway: '#e9eff5',
  },

  boundary: {
    state: '#c3cdd8',
    country: '#a9b6c4',
  },

  label: {
    color: '#4b5866',
    halo: '#ffffff',
    water: '#4a7fa6',
    road: '#5a6774',
    motorway: '#6f5a35',
    city: '#2f3b48',
    suburb: '#45525f',
    state: '#5a6673',
    country: '#4a5663',
    housenumber: '#6b7987',
  },

  poi: {
    transit: '#3f7fbb',
    water: '#35819c',
    sport: '#3c8459',
    facility: '#7d8794',
  },

  overlay: {
    territory: '#0b9cbb',
    territoryOutline: '#03566b',
    territoryFlash: '#00c2e4',
    territoryTest: '#6f4de8',
    territoryTestOutline: '#4a2fb8',
    trail: '#008fb3',
    trailCore: '#04586b',
    trailCold: '#2a6bd6',
    trailFast: '#0a9c78',
    trailMax: '#053f4f',
    accuracy: '#0b9cbb',
    route: '#6a51e0',
  },

  online: {
    territory: '#d98a1f',
    outline: '#a8640f',
  },
};

export function paletteFor(theme: Theme): MapPalette {
  return theme === 'light' ? lightPalette : darkPalette;
}
