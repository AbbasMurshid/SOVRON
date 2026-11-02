import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { getSupabaseConfig } from "./config";

let client: SupabaseClient | null = null;
export function getBrowserSupabase() {
  const config = getSupabaseConfig();
  if (!config) return null;
  client ??= createBrowserClient(config.url, config.key);
  return client;
}
