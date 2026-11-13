import type { FeatureCollection, Geometry } from 'geojson';
import { supabase } from './supabase';

export interface RunPoint {
  lon: number;
  lat: number;
  t: number;
  accuracy: number;
}

export interface SubmitResult {
  status: 'accepted' | 'rejected';
  reason?: string;
  runId?: string;
  seasonId?: string;
  cityId?: string | null;
  pointsAwarded?: number;
  areaM2?: number;
  stolenAreaM2?: number;
  territoryId?: string | null;
  protectedUntil?: string | null;
}

export interface LeaderboardRow {
  rank: number;
  userId: string;
  displayName: string;
  points: number;
  distanceM: number;
  areaM2: number;
  runsCount: number;
}

export interface CityInfo {
  cityId: string | null;
  cityName: string | null;
  districtId: string | null;
  districtName: string | null;
}

export interface OnlineTerritoryProperties {
  id: string;
  ownerId: string;
  areaM2: number;
  capturedAt: string;
  protectedUntil: string;
}

export type OnlineTerritories = FeatureCollection<Geometry, OnlineTerritoryProperties>;

/** UUID забега: один и тот же для повторов и восстановления после сбоя. */
export function createClientRunId(): string {
  const uuid = globalThis.crypto?.randomUUID?.();
  if (uuid) return uuid;

  // Запасной вариант для старых WebView без crypto.randomUUID.
  const bytes = new Uint8Array(16);
  globalThis.crypto?.getRandomValues?.(bytes);
  for (let i = 0; i < bytes.length; i += 1) {
    if (bytes[i] === 0) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Человеческий текст для кодов отклонения забега с сервера. */
export function describeRejection(reason: string | undefined): string {
  switch (reason) {
    case 'speed':
      return 'скорость выше 7 м/с';
    case 'accuracy':
      return 'точность GPS хуже 25 м';
    case 'accuracy_missing':
      return 'нет данных о точности GPS';
    case 'jump':
      return 'нереальный скачок координат';
    case 'timestamps':
      return 'нарушен порядок времени';
    case 'future_timestamp':
      return 'время забега из будущего — проверь часы устройства';
    case 'late_submission':
      return 'забег отправлен слишком поздно после финиша';
    case 'too_many_points':
      return 'слишком много точек';
    case 'too_many_runs':
      return 'слишком много забегов за сутки';
    case 'daily_points_cap':
      return 'дневной лимит очков исчерпан';
    case 'duplicate_points':
      return 'трек состоит из повторяющихся точек';
    case 'regular_intervals':
      return 'трек слишком ровный — похоже на подделку';
    case 'area_implausible':
      return 'площадь не сходится с пройденной дистанцией';
    case 'ring_off_track':
      return 'контур территории собран не из точек трека';
    case 'ring_not_closed':
      return 'контур не замкнут по треку';
    case 'ring_not_ordered':
      return 'контур собран не по порядку трека';
    case 'ring_boundary_arc':
      return 'дуга от границы своей территории не замкнулась — захват не засчитан';
    case 'ring_untracked':
      return 'контур территории не совпал с треком и не засчитан';
    default:
      return 'трек не прошёл проверку';
  }
}

export interface Bbox {
  west: number;
  south: number;
  east: number;
  north: number;
}

let currentUserId: string | null = null;

export function getOnlineUserId(): string | null {
  return currentUserId;
}

function friendly(message: string): string {
  const text = message.toLowerCase();

  if (
    text.includes('anonymous sign-ins are disabled') ||
    text.includes('anonymous_provider_disabled')
  ) {
    return 'Анонимный вход выключен в Supabase. Включи Authentication → Providers → Anonymous.';
  }
  if (text.includes('failed to fetch') || text.includes('networkerror')) {
    return 'Нет связи с Supabase. Проверь интернет и URL проекта.';
  }
  if (text.includes('submit_run_v2')) {
    return 'База не обновлена: примени supabase/migrations/0005_run_security.sql в SQL Editor.';
  }
  if (
    text.includes('could not find the function') ||
    text.includes('schema cache') ||
    text.includes('does not exist')
  ) {
    return 'База не настроена: выполни supabase/setup.sql в SQL Editor.';
  }
  if (text.includes('jwt expired')) {
    return 'Сессия истекла. Обнови страницу.';
  }
  return message;
}

export async function ensureAnonymousSession(): Promise<{
  userId: string | null;
  error: string | null;
}> {
  const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) {
    return { userId: null, error: friendly(sessionError.message) };
  }

  if (sessionData.session) {
    currentUserId = sessionData.session.user.id;
    return { userId: currentUserId, error: null };
  }

  const { data, error } = await supabase.auth.signInAnonymously();
  if (error) {
    return { userId: null, error: friendly(error.message) };
  }

  currentUserId = data.user?.id ?? data.session?.user.id ?? null;
  return {
    userId: currentUserId,
    error: currentUserId ? null : 'Не удалось создать анонимную сессию',
  };
}

export async function loadProfileName(): Promise<string> {
  if (!currentUserId) return 'Игрок';

  const { data } = await supabase
    .from('profiles')
    .select('display_name')
    .eq('user_id', currentUserId)
    .maybeSingle();

  const name = (data as { display_name?: unknown } | null)?.display_name;
  return typeof name === 'string' && name.trim() ? name : 'Игрок';
}

export async function saveProfileName(name: string): Promise<string | null> {
  if (!currentUserId) return 'Нет онлайн-сессии';

  const displayName = name.trim().slice(0, 40) || 'Игрок';
  const { error } = await supabase
    .from('profiles')
    .upsert({ user_id: currentUserId, display_name: displayName }, { onConflict: 'user_id' });

  return error ? friendly(error.message) : null;
}

export async function submitRun(
  points: RunPoint[],
  rings: Array<Array<[number, number]>> = [],
  clientRunId: string = createClientRunId(),
): Promise<{ result: SubmitResult | null; error: string | null }> {
  // client_run_id делает отправку идемпотентной: повтор с тем же ключом
  // возвращает прежний результат и ничего не начисляет.
  const { data, error } = await supabase.rpc('submit_run_v2', {
    p_points: points,
    p_rings: rings,
    p_client_run_id: clientRunId,
  });
  if (error) return { result: null, error: friendly(error.message) };

  const raw = (data ?? {}) as Record<string, unknown>;
  const status = raw.status === 'rejected' ? 'rejected' : 'accepted';

  return {
    result: {
      status,
      reason: typeof raw.reason === 'string' ? raw.reason : undefined,
      runId: typeof raw.run_id === 'string' ? raw.run_id : undefined,
      seasonId: typeof raw.season_id === 'string' ? raw.season_id : undefined,
      cityId: typeof raw.city_id === 'string' ? raw.city_id : null,
      pointsAwarded: Number(raw.points_awarded ?? 0),
      areaM2: Number(raw.area_m2 ?? 0),
      stolenAreaM2: Number(raw.stolen_area_m2 ?? 0),
      territoryId: typeof raw.territory_id === 'string' ? raw.territory_id : null,
      protectedUntil:
        typeof raw.protected_until === 'string' ? raw.protected_until : null,
    },
    error: null,
  };
}

export async function fetchCityAt(lon: number, lat: number): Promise<CityInfo | null> {
  const { data, error } = await supabase.rpc('city_at_point', {
    p_lon: lon,
    p_lat: lat,
  });
  if (error) return null;

  const row = (Array.isArray(data) ? data[0] : data) as
    | {
        city_id?: string | null;
        city_name?: string | null;
        district_id?: string | null;
        district_name?: string | null;
      }
    | null
    | undefined;

  if (!row) {
    return { cityId: null, cityName: null, districtId: null, districtName: null };
  }

  return {
    cityId: row.city_id ?? null,
    cityName: row.city_name ?? null,
    districtId: row.district_id ?? null,
    districtName: row.district_name ?? null,
  };
}

export async function fetchOnlineTerritories(
  bbox: Bbox,
): Promise<{ data: OnlineTerritories | null; error: string | null }> {
  const west = Math.max(-180, Math.min(180, bbox.west));
  const east = Math.max(-180, Math.min(180, bbox.east));
  const south = Math.max(-85, Math.min(85, bbox.south));
  const north = Math.max(-85, Math.min(85, bbox.north));

  // Пересечение антимеридиана не поддерживаем: для игры это не нужно.
  if (west >= east || south >= north) {
    return { data: { type: 'FeatureCollection', features: [] }, error: null };
  }

  const { data, error } = await supabase.rpc('territories_bbox_geojson', {
    p_west: west,
    p_south: south,
    p_east: east,
    p_north: north,
  });

  if (error) return { data: null, error: friendly(error.message) };

  const rows = (Array.isArray(data) ? data : []) as Array<{
    id?: string;
    owner_id?: string;
    area_m2?: number;
    captured_at?: string;
    protected_until?: string;
    geojson?: Geometry;
  }>;

  return {
    data: {
      type: 'FeatureCollection',
      features: rows
        .filter((row) => row.geojson && row.id && row.owner_id)
        .map((row) => ({
          type: 'Feature' as const,
          properties: {
            id: String(row.id),
            ownerId: String(row.owner_id),
            areaM2: Number(row.area_m2 ?? 0),
            capturedAt: String(row.captured_at ?? ''),
            protectedUntil: String(row.protected_until ?? ''),
          },
          geometry: row.geojson as Geometry,
        })),
    },
    error: null,
  };
}

export async function fetchLeaderboard(
  cityId: string | null,
): Promise<{ rows: LeaderboardRow[]; error: string | null }> {
  const { data, error } = await supabase.rpc('season_leaderboard', {
    p_city_id: cityId,
    p_district_id: null,
    p_limit: 200,
  });

  if (error) return { rows: [], error: friendly(error.message) };

  const rows = (Array.isArray(data) ? data : []) as Array<{
    rank?: number | string;
    user_id?: string;
    display_name?: string;
    points?: number;
    distance_m?: number;
    area_m2?: number;
    runs_count?: number;
  }>;

  return {
    rows: rows
      .filter((row) => row.user_id)
      .map((row) => ({
        rank: Number(row.rank ?? 0),
        userId: String(row.user_id),
        displayName: String(row.display_name ?? 'Игрок'),
        points: Number(row.points ?? 0),
        distanceM: Number(row.distance_m ?? 0),
        areaM2: Number(row.area_m2 ?? 0),
        runsCount: Number(row.runs_count ?? 0),
      })),
    error: null,
  };
}
