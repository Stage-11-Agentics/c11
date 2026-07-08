# Web deploy flags — operator decisions (2026-07-08)

PR #316 rebuilt `web/`'s env contract and flagged five values for confirmation before any deploy. Operator answers, recorded so nobody re-litigates them:

| Flag | Decision |
|---|---|
| Site deployment itself | **There is no public c11 site today and none is being deployed now.** c11 is distributed via the GitHub repo, releases, and Homebrew. `web/` stays in-repo, buildable, undeployed. Every flag below activates only if/when a deploy is decided. |
| `NEXT_PUBLIC_SITE_URL` | Deferred (no site). |
| `C11_FEEDBACK_TO_EMAIL` | No feedback inbox exists today. The app's in-app feedback already no-ops safely (empty `CMUX_FEEDBACK_API_URL` default → "Feedback is unavailable" fallback, founders contact `hello@stage11.ai`). Deferred. |
| Legal entity | **Stage 11 Agentics** for site legal pages, whenever they ship. Legal copy still needs human review at that time. |
| `NEXT_PUBLIC_POSTHOG_*` | **Create a fresh PostHog project when the site deploys** (`stage11-c11-web` per platform naming). Note: the Stage 11 PostHog *account* does not exist yet (`platform/posthog.md`, status Onboarding) — account creation is the first step, owned at deploy time. |
| Social handles | X/Twitter: **@Stage_11** (the only Stage 11 social presence). No LinkedIn. Wire cards at deploy time. |

Release impact: **none of these block the app release.** The packaged app has no live dependency on web/ or these env values.
