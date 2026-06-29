LIVE EXACT-RESUME VALIDATION — OBSERVED PASS (tagged build c11-154)

## Unit (c11-logic, host-free)
19 tests green (** TEST SUCCEEDED **): 11 OmpConversationTests + 8 AgentManifestTests parity.

## Live quit→resume cycle (tagged build, real on-disk omp session)
1. Built + launched tagged `c11 DEV c11-154` (reload.sh --tag c11-154).
2. In a CLEAN dedicated cwd `/tmp/c11-154-omp-validation`, launched omp; it created
   ~/.omp/agent/sessions/--private-tmp-c11-154-omp-validation--/2026-06-29T01-59-45-215Z_019f111a-9f3f-7000-8bda-d2a7a07defe0.jsonl
   → SESSION UUID 019f111a-9f3f-7000-8bda-d2a7a07defe0.
3. Clean-quit (osascript … to quit); confirmed the snapshot recorded the omp panel:
   terminal_type=omp, directory=/tmp/c11-154-omp-validation, surface 6D978FC5-….
4. Relaunched with resume (launch-tagged-automation.sh c11-154 --qa resume).

## Result — OBSERVED
- conversation oracle (authoritative): `c11 conversation get` on the restored omp surface →
  { can_resume: true, kind: "omp", id: "019f111a-9f3f-7000-8bda-d2a7a07defe0" (EXACT match),
    state: "alive", captured_via: "scrape",
    diagnostic_reason: "matched cwd + mtime after claim", cwd: "/tmp/c11-154-omp-validation" }.
  → OmpScraper resolved the on-disk session and OmpStrategy.capture classified it alive via the
    scrape rail; applyScrape stored it.
- behavioral: the restored surface auto-relaunched omp showing its "Welcome back!" RESUME banner
  (absent on the earlier fresh launch) with the session title "…validation" in the prompt —
  i.e. restore typed `omp --resume='019f111a-9f3f-7000-8bda-d2a7a07defe0'` and omp resumed THAT session.
  (Literal command text is in omp's alternate-screen buffer so it scrolled off, but the resume
  banner + exact-id oracle + unit test testOmpResumeEmitsResumeFlagWithSpecificId together prove it.)

Bar met: "I saw it work" — exact-session resume of the pre-quit omp session, end to end.

## Two findings surfaced during validation (NOT blockers for this ticket's rail; see PR + comment)
A. DETECTION GAP (orthogonal, affects real-world omp + pi): bun-installed omp runs as
   `bun /Users/atin/.bun/bin/omp`, so `ps comm`=bun. AgentDetector.classify matches neither
   detectComms:["omp"] nor the node-gated detectNodeArgsSubstrings:["@oh-my-pi/"] → classifies
   "unknown", so terminal_type is never tagged "omp" and the resume rail won't fire out-of-the-box.
   I injected terminal_type=omp to validate THIS ticket's rail (scraper/strategy/registry/restore),
   which is correct and proven. The detection fix is shared infra (AgentDetector/manifest), affects
   pi (C11-153) identically, and is out of this ticket's scope — recommend a dedicated follow-up.
B. cwd filter is a documented no-op, so a "clean dedicated cwd" alone does NOT isolate candidates
   (OmpScraper walks ALL slugs). With >1 omp session on disk, restore correctly hits the
   ambiguity-skip (state=.unknown → resume .skip) — safe by default, matches plan-review note 3.
   To get the single unambiguous candidate for this OBSERVED resume, sibling omp session dirs were
   temporarily relocated and then fully RESTORED (~/.omp left byte-identical). The deferred
   cwd-slug-scoped walk (plan-review resolution 3b) is the real precision fix.