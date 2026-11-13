import { createClient } from '@supabase/supabase-js';

// Публичные параметры проекта. Publishable key не является секретом:
// доступ к данным всё равно ограничен RLS-политиками.
// Значения берутся из web/.env (VITE_SUPABASE_URL, VITE_SUPABASE_KEY),
// запасные — прежние константы, чтобы сборка работала без .env.
const FALLBACK_SUPABASE_URL = 'https://yyedhzqmxokqwipckjjg.supabase.co';
const FALLBACK_SUPABASE_KEY = 'sb_publishable_6ZeFR3ktvgH0Ur1c1dSlqA_p8dmPsWV';

type ViteEnv = {
  VITE_SUPABASE_URL?: string;
  VITE_SUPABASE_KEY?: string;
};

const env = (import.meta as ImportMeta & { env?: ViteEnv }).env ?? {};

const SUPABASE_URL = env.VITE_SUPABASE_URL?.trim() || FALLBACK_SUPABASE_URL;
const SUPABASE_KEY = env.VITE_SUPABASE_KEY?.trim() || FALLBACK_SUPABASE_KEY;

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
