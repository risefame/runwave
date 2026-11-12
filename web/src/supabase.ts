import { createClient } from '@supabase/supabase-js';

// Публичные ключи проекта. Publishable key не является секретом:
// доступ к данным всё равно ограничен RLS-политиками.
const SUPABASE_URL = 'https://yyedhzqmxokqwipckjjg.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_6ZeFR3ktvgH0Ur1c1dSlqA_p8dmPsWV';

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
