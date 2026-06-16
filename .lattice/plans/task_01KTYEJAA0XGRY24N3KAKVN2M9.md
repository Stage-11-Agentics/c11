# C11-134: Sentry: add workspace-shape breadcrumbs (surface counts, portal events) for hang triage

Sentry AppHang events for c11 currently carry only app-lifecycle, update-probe, and http breadcrumbs (see C11-1 event e52679c6db26497d84f81ed77dd482b8). There is no record of workspace shape at hang time, so we cannot correlate hangs with browser-surface count, pane count, or portal churn - the exact correlation needed during the 2026-06-12 multi-browser freeze triage.

DELIVERABLE
Add sentryBreadcrumb() calls (SentryHelper.swift already provides the helper, telemetry-consent gated) for:
- Surface lifecycle: browser/terminal/markdown surface created/closed, with per-type counts after the change (e.g. {browsers: 3, terminals: 7, markdown: 1}).
- Workspace/pane shape changes: pane split/close, workspace switch (counts only, no titles/URLs - privacy posture: no user content in breadcrumbs).
- Portal bind/detach events (the C11-18 portal lifecycle events already exist behind C11_PORTAL_DEBUG; mirror the bind/detach/orphan signals as breadcrumbs at low volume).
Keep volume low (state-change only, no per-frame events). Validate by triggering a test event and confirming breadcrumbs render in the Sentry UI.

Motivation: next fleet AppHang report should answer "how many browser surfaces were open?" without operator archaeology. Related: C11-132.
