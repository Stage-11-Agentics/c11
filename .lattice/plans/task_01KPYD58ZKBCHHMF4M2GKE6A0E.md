# C11-15: Reorder first-launch onboarding: TCC primer before initial shell spawn, Full Disk Access as primary CTA

## Problem

On first launch, new users are hit with a cascade of macOS permission prompts (Documents / Desktop / Downloads / iCloud Drive / removable volumes) the instant they open c11. The prior TCC primer (merged in #55 / #56) was supposed to contextualize these — but in practice the race is already lost by the time the primer appears.

Flow in `Sources/AppDelegate.swift:6202-6218` (`sendWelcomeCommandWhenReady`):

1. welcome workspace opens
2. `runWhenInitialTerminalReady` — **initial Ghostty surface spawns a shell** → rc files execute → protected-folder access → prompts fire, attributed to c11
3. `performQuadLayout` (sends `c11 welcome\n`)
4. 1.2 s delay
5. AgentSkills sheet (if relevant)
6. TCC primer sheet

By step 6, the user has already seen five dialogs. The primer explains prompts that already fired.

## Web research (Apr 2026)

- `NS*UsageDescription` keys in Info.plist **do not trigger prompts on their own.** They only customize the prompt copy when the corresponding API is called. Unused keys (Music, Photos, Contacts, Calendar, Reminders, Camera) are cosmetic noise at worst — not the cause of the cascade the user is seeing.
- The cascade is caused by shell activity. When Ghostty spawns a shell, macOS treats c11 as the *responsible process*. Every protected folder the shell's rc files touch fires a prompt. Universal across iTerm2, Warp, Ghostty — documented in [Ghostty Discussion #4496](https://github.com/ghostty-org/ghostty/discussions/4496) and [iTerm2's FDA wiki](https://gitlab.com/gnachman/iterm2/-/wikis/Fulldiskaccess).
- **Full Disk Access is THE industry-accepted fix.** One-time grant, suppresses the entire cascade. The posix_spawn "shed the responsible-process bit" workaround is blocked by `TIOCSCTTY` / `setsid` requirements (Ghostty issue #9263).
- Local Network (macOS 15+) is a separate single prompt, not a cascade. Not in scope here.

## Fix

Two coordinated changes:

### 1. Reorder `sendWelcomeCommandWhenReady` so the primer resolves BEFORE the initial shell spawns

- Welcome workspace is created but the initial terminal pane does not yet spawn a shell.
- TCC primer sheet presents immediately on first launch.
- User chooses Full Disk Access (opens Settings → Privacy & Security) or "Continue without it."
- *Then* the shell spawns, `c11 welcome` prints, quad layout assembles.

Exact call site: `Sources/AppDelegate.swift:6202-6218`. Current order is `runWhenInitialTerminalReady { … performQuadLayout + sendText … presentAgentSkillsOnboarding → chained TCC primer }`. New order: TCC primer first (via `shouldPresent` gate), then Agent Skills (if applicable), then the shell-spawning steps.

### 2. Promote Full Disk Access to primary button in `Sources/TCCPrimerView.swift`

- **Primary**: "Grant Full Disk Access" — opens the Settings pane.
- **Secondary**: "Continue without it" — closes the sheet, shell spawns, cascade may fire.
- Copy refreshed to make FDA the recommended path and acknowledge this is the industry-standard approach for mature terminal emulators.

## Scope

- Fresh installs only. `TCCPrimer.migrateExistingUserIfNeeded` at `AppDelegate.swift:2348` stays as-is — users who already saw the old primer are not re-prompted with the new one.
- English copy changes require xcstrings updates for the six supported locales (ja, uk, ko, zh-Hans, zh-Hant, ru). Delegate to a translator sub-agent after English lands.
- Follow-up ticket tracks FDA runtime detection + auto-continue (the primer currently doesn't notice when the user grants FDA and comes back; user has to click "Continue without it" even though they did grant it).

## Acceptance

- On a fresh install (fresh UserDefaults suite — tagged dev build), launching c11 shows the TCC primer as the first surface, not a shell pane with prompts flying.
- Clicking "Grant Full Disk Access" opens the Settings pane.
- Clicking "Continue without it" closes the sheet and lets the welcome workspace + shell continue.
- Existing users (pre-migration) do NOT see the new primer.
- Localized copy lands for all six locales.
