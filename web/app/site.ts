// Canonical public origin for the c11 marketing site.
//
// Operator-configurable at deploy via NEXT_PUBLIC_SITE_URL. The default is a
// Stage 11 domain (agents operate on stage11.systems); set the env var to the
// real production host before shipping. No trailing slash.
export const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ??
  "https://c11.stage11.systems";
