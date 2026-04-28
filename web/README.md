# c11 web

Marketing site and docs surface for [c11](https://github.com/Stage-11-Agentics/c11) — the macOS terminal multiplexer for the operator:agent pair.

Next.js (App Router) + `next-intl` for the multilingual surface. Localized message catalogs live under `messages/`.

## Local dev

```bash
bun install
bun dev
```

Then open <http://localhost:3777>.

## Build

```bash
bun run build
bun run start
```

## Layout

- `app/` — routes and layouts (locale-segmented under `app/[locale]/`).
- `messages/` — per-locale JSON message catalogs consumed by `next-intl`.
- `i18n/` — locale config and request-time loader.
- `proxy.ts` — edge redirects (legacy domain → canonical).
- `public/` — static assets.
