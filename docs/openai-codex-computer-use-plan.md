# OpenAI Codex Computer Use Plan

Status: implementation started. The initial provider-neutral Swift macOS adapter and OpenAI-specific Python runner live under `tools/computer-use/`.

Branch/worktree:

- Branch: `feat/openai-cua-runner`
- Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/openai-cua-runner`

Date: 2026-04-30

## Goal

Build an OpenAI-backed computer-use path for testing c11 the way an operator uses it: through the real macOS app UI, with screenshots, clicks, keyboard input, focus changes, menus, panels, drag gestures, and visual recovery when the app is not in the expected state.

This branch is the OpenAI side of an apples-to-apples comparison with the Anthropic computer-use effort running separately. The comparison should measure the agent's ability to operate c11 visually, not just mutate files or query the socket.

## Current OpenAI Landscape

There are two relevant OpenAI routes.

1. Codex app Computer Use plugin

   OpenAI's Codex app now has a macOS Computer Use plugin. The docs say to install it from Codex settings, then grant Screen Recording and Accessibility permissions. It lets Codex see and operate graphical macOS apps, including desktop apps and browser flows. It is currently documented as macOS-only at launch and unavailable in the EEA, UK, and Switzerland.

   This is the fastest path to let Codex itself operate c11 visually in an interactive session.

2. Responses API `computer` tool

   The developer API exposes a `computer` tool. The model inspects screenshots and returns actions such as `click`, `double_click`, `scroll`, `type`, `wait`, `keypress`, `drag`, `move`, and `screenshot`. Our code executes those actions in a harness, captures the next screenshot, and sends it back as `computer_call_output`.

   This is the right path for a reproducible comparison harness because we control the environment, artifacts, prompts, scenarios, scoring, retries, and state reset.

Official references:

- Codex app Computer Use: `https://developers.openai.com/codex/app/computer-use`
- API Computer Use guide: `https://developers.openai.com/api/docs/guides/tools-computer-use`
- CUA sample app: `https://github.com/openai/openai-cua-sample-app`

Implementation note: the runner targets the current GA Responses API `computer` tool shape: `tools=[{"type": "computer"}]`, `computer_call` outputs, and follow-up `computer_call_output` items sent with `previous_response_id`.

## Non-goals

- Do not replace c11 socket or CLI tests. Those remain the deterministic oracle and setup/reset layer.
- Do not make the c11 app depend on OpenAI, Anthropic, or any computer-use SDK.
- Do not add persistent writes to tenant configs such as `~/.codex`, `~/.claude`, shell rc files, or app-specific agent config.
- Do not automate Codex itself or terminal security prompts through the Codex app Computer Use plugin. OpenAI's Codex Computer Use docs explicitly call out restrictions around automating terminal apps, Codex itself, admin authentication, and security/privacy permission prompts.
- Do not treat screenshot-only success as enough when a deterministic state check exists.

## Principle

Computer use is the primary exercise path. The agent should complete workflows through the visible app UI whenever possible.

Socket and CLI access are support infrastructure:

- setup: launch tagged build, clean previous state, create deterministic initial conditions
- oracle: assert workspace/pane/surface state after the visual action
- artifact capture: collect logs, tree output, socket snapshots, and screenshots
- recovery: help diagnose failures without pretending a socket-only operation proved user behavior

The gold standard is: "Could a real operator have done this through the UI, and did the app visibly respond correctly?"

## Recommended Shape

Build a provider-neutral local macOS adapter and an OpenAI-specific orchestrator.

```text
tools/computer-use/
  mac-adapter/
    Package.swift
    Sources/CUAMacAdapter/
      main.swift
      WindowTarget.swift
      ScreenshotCapture.swift
      InputEvents.swift
      Accessibility.swift
      Permissions.swift
  openai-runner/
    pyproject.toml
    README.md
    openai_cua_runner/
      __main__.py
      responses_loop.py
      adapter_client.py
      scenarios.py
      artifacts.py
      c11_oracle.py
      safety.py
```

Rationale:

- Swift is the cleanest local choice for native macOS APIs: AppKit, CoreGraphics, ApplicationServices, AXUIElement, and TCC permission checks.
- Python is the fastest choice for the Responses API loop, JSON traces, scenario orchestration, and artifact handling.
- Keeping `mac-adapter` provider-neutral lets the Anthropic branch reuse or mirror the same OS bridge later, which makes the OpenAI-vs-Anthropic comparison fairer.

If the Anthropic branch independently creates a different adapter first, reconcile around a shared minimal JSON contract instead of rewriting both sides.

## Adapter Contract

The mac adapter should expose a small JSON-over-stdio CLI. Keep it boring and auditable.

Commands:

- `doctor`: report macOS version, TCC permissions, target app availability, screen scale, and whether the bundle id can be found.
- `launch`: optionally launch or activate a target app by bundle id or path.
- `observe`: capture a screenshot and return metadata.
- `act`: execute one computer-use action.
- `window-list`: list candidate windows for debugging target selection.
- `quit`: shut down any adapter session state.

Target selection:

- Prefer bundle id. For tagged c11 builds this should be `com.stage11.c11.debug.<tag-id>`.
- Fall back to app path only for launch.
- Require a matching visible window before executing input.
- Fail closed if the focused or frontmost app is not the allowed bundle id, unless the scenario explicitly permits a system dialog or permission prompt.

Coordinate model:

- The screenshot returned to the model defines the action coordinate space.
- The adapter maps screenshot pixels to global display points using the captured window bounds and backing scale factor.
- Store scale factor, window bounds, screenshot size, and display id with every observation artifact.

Supported actions:

- `click`
- `double_click`
- `move`
- `drag`
- `scroll`
- `type`
- `keypress`
- `wait`
- `screenshot`

Action execution:

- Mouse and keyboard events should use CoreGraphics events where practical.
- Accessibility actions are allowed for window targeting, raising, permission diagnosis, and controls where CGEvent is insufficient.
- Do not bypass the UI path for product behavior. For example, `AXPress` is acceptable for a known macOS permission prompt, but not as the default way to "test" c11 buttons if the user path is pointer hit-testing.

## OpenAI Runner Contract

The OpenAI runner should own:

- `OPENAI_API_KEY` discovery from environment only.
- Model/tool configuration for the Responses API `computer` tool.
- Prompt construction for each scenario.
- The computer-use loop: send task, receive `computer_call`, execute actions through the mac adapter, capture screenshot, send `computer_call_output`, repeat until final answer or failure.
- Safety policy: max actions, max wall time, app allowlist, sensitive-action prompts, and fail-closed target checks.
- Artifact writing.

Initial CLI:

```bash
python -m openai_cua_runner doctor
python -m openai_cua_runner smoke --tag openai-cua
python -m openai_cua_runner scenario launch-window --tag openai-cua
python -m openai_cua_runner scenario split-pane --tag openai-cua
```

Artifacts:

```text
artifacts/openai-cua-runs/<timestamp>-<scenario>/
  run.json
  prompt.md
  final.md
  actions.jsonl
  observations.jsonl
  screenshots/
    000-initial.png
    001-after-click.png
  c11/
    tree-before.json
    tree-after.json
    identify.json
  logs/
    c11-debug.log
```

Do not commit run artifacts. Add ignore rules when implementation begins.

## c11 Launch and Runtime Discipline

Use tagged builds only.

Build:

```bash
./scripts/reload.sh --tag openai-cua
```

Launch existing tagged build for automation:

```bash
./scripts/launch-tagged-automation.sh openai-cua --wait-socket 10
```

Expected derived values:

- App: `~/Library/Developer/Xcode/DerivedData/c11-openai-cua/Build/Products/Debug/c11 DEV openai-cua.app`
- Bundle id: `com.stage11.c11.debug.openai.cua`
- Socket: `/tmp/c11-debug-openai-cua.sock`
- Log: `/tmp/c11-debug-openai-cua.log`

The runner should not launch an untagged `c11 DEV.app`.

## Permission Plan

The first run will likely require human approval.

Required macOS permissions:

- Screen Recording, so screenshots include the target app.
- Accessibility, so the adapter can click, type, scroll, and inspect windows.

The runner must have a `doctor` command that detects missing permissions before attempting a scenario and prints exact remediation:

```text
System Settings > Privacy & Security > Screen Recording
System Settings > Privacy & Security > Accessibility
```

The runner should stop at missing TCC permissions, not spin or guess. Security and privacy prompts are a legitimate human-in-the-loop boundary.

## Safety Policy

Default safety rules:

- One target app per scenario.
- Bundle-id allowlist is required.
- Refuse to type into or click outside the allowed app window unless the step is explicitly marked as a system permission prompt.
- Refuse scenarios involving credentials, payments, account settings, admin prompts, or destructive file operations.
- Cap each run by action count and wall time.
- Save every model action and screenshot for review.
- Keep sensitive apps closed during runs.
- Require explicit operator approval before enabling browser scenarios against signed-in sessions.

The implementation should bias toward stopping with a high-quality artifact bundle rather than trying increasingly broad desktop interactions.

## Scenario Design

Scenarios should be small, observable, and repeatable. The initial suite should avoid fragile pixel-perfect coordinates and ask the model to inspect the screenshot before acting.

### Scenario 0: Doctor

Purpose: prove the environment is eligible.

Steps:

- Check `OPENAI_API_KEY`.
- Check adapter executable availability.
- Check Screen Recording and Accessibility.
- Check tagged c11 app exists or explain build command.
- Check target app window can be found after launch.
- Check socket path exists after launch.

Pass criteria:

- Clear pass/fail report with no model call required.

### Scenario 1: Launch Window

Purpose: first full visual loop.

Steps:

- Launch tagged c11.
- Use computer use to inspect the window.
- Ask the model to report whether the app appears ready.

Pass criteria:

- Screenshot captured.
- Model completes without needing actions or after a `wait`.
- Socket tree confirms at least one workspace, pane, and terminal surface.

### Scenario 2: Create Split

Purpose: first real user-like app interaction.

Preferred user path:

- Use visible UI or menu/keyboard shortcut to create a split, depending on the current c11 UX.

Pass criteria:

- Computer use performs the action visually.
- `c11 tree --json` against `/tmp/c11-debug-openai-cua.sock` shows pane count increased.
- Artifact includes before/after screenshot and before/after tree.

### Scenario 3: Focus and Type

Purpose: verify real terminal focus, keyboard event routing, and rendering.

Steps:

- Use computer use to click a visible terminal pane.
- Type a harmless command such as `printf 'openai-cua-ok\n'`.
- Press Enter.

Pass criteria:

- The visible terminal renders the expected output.
- `read-screen` or equivalent socket read confirms the output.
- This scenario must not use `c11 send` for the typing step.

### Scenario 4: Browser Surface

Purpose: verify a non-terminal surface through user-facing UI.

Steps:

- Create or select a browser surface through the UI path available in c11.
- Navigate to a deterministic local or data URL.

Pass criteria:

- Visual screenshot shows browser content.
- Socket/browser API confirms URL or title where available.

### Scenario 5: Markdown Surface

Purpose: verify surface creation and non-terminal rendering.

Steps:

- Open a known local markdown file in a markdown surface through the user-facing path.

Pass criteria:

- Visual screenshot shows rendered markdown.
- Socket tree confirms markdown surface type.

### Scenario 6: Sidebar Metadata

Purpose: compare model ability to inspect c11's agent-centric UI.

Steps:

- Use socket only to set up a deterministic metadata state.
- Ask computer use to inspect the sidebar and summarize visible status/title/description.

Pass criteria:

- Model identifies the correct visible state from screenshot.
- Socket remains the oracle for exact metadata.

### Scenario 7: Drag/Resize

Purpose: exercise pointer-drag behavior that socket tests cannot fully stand in for.

Steps:

- Ask computer use to drag a divider or resize affordance.

Pass criteria:

- Visual layout changes.
- Socket tree reports changed pane geometry.

This should come after launch/split/focus are stable because drag is the highest-fragility action class.

## Comparison Metrics

Capture the same metrics for OpenAI and Anthropic runs.

- Scenario result: pass, fail, blocked, inconclusive.
- Number of model turns.
- Number of UI actions.
- Wall-clock time.
- Recovery quality when initial UI state differs.
- Whether the model used visual evidence correctly.
- Whether it clicked/typed outside the target app.
- Whether it asked for clarification or stopped appropriately.
- Artifact completeness.
- Deterministic oracle result.

Use identical scenario prompts where provider APIs allow it.

## Implementation Phases

### Phase 0: Plan and Branch

Status: current phase.

Deliverables:

- Dedicated worktree and branch.
- This plan committed as a markdown artifact.
- No runner code yet.

### Phase 1: Operator Enablement for Codex App Plugin

Purpose: let the operator quickly try OpenAI's built-in Codex app computer use while the reproducible harness is being built.

Steps:

- In Codex app settings, open Computer Use and install the plugin.
- Grant Screen Recording and Accessibility when macOS prompts.
- Try one manual scoped task against the tagged c11 app:

```text
Use computer use to inspect the c11 DEV openai-cua app window and tell me whether the initial terminal surface is visible. Do not edit files.
```

Deliverables:

- Short note in the plan or follow-up docs with observed behavior, permission prompts, and limitations.

### Phase 2: Native Mac Adapter

Deliverables:

- Swift CLI with `doctor`, `window-list`, `observe`, and minimal `act`.
- Window-targeted screenshot capture.
- Click, keypress, type, wait.
- JSON action/result schema.
- Local artifact screenshots.

Implementation status: initial adapter added at `tools/computer-use/mac-adapter`. It also includes `launch`, frontmost bundle guardrails for input, `double_click`, `move`, `drag`, and `scroll`.

Validation:

- Run `doctor`.
- Launch tagged c11.
- Capture one screenshot.
- Execute one harmless focus/click action.

Expected human blocker:

- macOS TCC permissions may require operator approval.

### Phase 3: OpenAI Responses Loop

Deliverables:

- Python runner that calls the Responses API with `tools=[{"type": "computer"}]`.
- Loop handling `computer_call` and `computer_call_output`.
- Adapter subprocess client.
- Run artifacts.
- `launch-window` scenario.

Implementation status: initial runner added at `tools/computer-use/openai-runner`. It discovers `OPENAI_API_KEY` from the environment only, writes ignored artifact bundles, and handles current Responses API computer calls.

Validation:

- Complete Scenario 1 against tagged c11.
- Review trace for action correctness and screenshot fidelity.

### Phase 4: c11 Scenario Harness

Deliverables:

- Tagged build launcher integration.
- Socket oracle integration with `C11_SOCKET`/`CMUX_SOCKET`.
- Scenario definitions for launch, split, focus/type.
- Failure bundles with screenshots, logs, socket snapshots, and model trace.

Implementation status: `doctor`, `smoke`, `launch-window`, `create-split`, and `focus-and-type` CLI paths are implemented. Socket usage is limited to launch/oracle/artifact capture.

Validation:

- Complete Scenarios 1-3.
- Confirm typing scenario uses real keyboard events, not socket send.

### Phase 5: Broaden UI Coverage

Deliverables:

- Browser surface scenario.
- Markdown surface scenario.
- Sidebar metadata inspection scenario.
- Drag/resize scenario if stable.

Validation:

- Each scenario has both visual evidence and deterministic oracle where possible.

### Phase 6: Apples-to-Apples Comparison

Deliverables:

- Shared scenario prompt set.
- Shared scoring schema.
- OpenAI run summary.
- Comparison-ready artifact format for Anthropic branch.

Validation:

- At least three scenarios run through OpenAI with reusable artifacts.
- Anthropic branch can consume or mirror the same scenario definitions.

## Expected Files During Implementation

Likely new files:

- `docs/openai-codex-computer-use-plan.md`
- `tools/computer-use/mac-adapter/Package.swift`
- `tools/computer-use/mac-adapter/Sources/CUAMacAdapter/*.swift`
- `tools/computer-use/openai-runner/pyproject.toml`
- `tools/computer-use/openai-runner/README.md`
- `tools/computer-use/openai-runner/openai_cua_runner/*.py`
- `.gitignore` entries for `artifacts/openai-cua-runs/` if not already covered

Likely untouched files:

- c11 product source under `Sources/`
- localization catalogs
- build workflows
- tenant config files

## Testing and Validation Policy

Respect this repo's testing policy.

- Do not run the local test suite.
- Use tagged app builds for local visual validation.
- Use the runner's `doctor` and smoke scenarios for harness validation.
- Use GitHub Actions or the VM for broader tests if code outside `tools/` changes.
- Do not launch untagged DerivedData apps.

For this feature, the main validation is an end-to-end tagged-build visual run plus artifact review.

## Known Risks

### TCC Permissions

Screen Recording and Accessibility cannot be granted by the agent. The implementation must detect missing permissions and stop with clear instructions.

### Coordinate Drift

Screenshots are pixels; CGEvent coordinates are display points. Retina scaling and window title bars can cause off-by-scale or off-by-origin errors. Every observation must record scale and bounds.

### Wrong-window Actions

Computer use can interact with whatever is visible if guardrails are weak. The adapter must fail closed when the target bundle/window is not active or visible.

### Visual Nondeterminism

Animations, first-launch state, stale windows, and overlapping apps can confuse the model. Scenarios should start from a tagged launch, capture initial state, and keep instructions narrow.

### Socket Oracle Overreach

It is tempting to use socket commands for everything. The scenario definition must mark which steps are setup/oracle and which steps must be performed visually.

### Provider Comparison Bias

If OpenAI and Anthropic use different adapters, prompts, reset logic, or oracle checks, the comparison will be noisy. Keep scenario specs provider-neutral.

### Cost and Latency

Computer-use loops can be expensive because each step sends screenshots. Cap action count, screenshot detail, and wall time per scenario.

## Definition of Done for Implementation

The OpenAI implementation is done when:

- A clean tagged c11 build can be launched from the runner.
- `doctor` accurately reports API key, app, socket, and macOS permissions.
- The runner completes at least:
  - launch-window
  - create-split
  - focus-and-type
- Each completed scenario has:
  - prompt
  - action trace
  - screenshots
  - c11 socket oracle before/after
  - final result summary
- The focus-and-type scenario uses real macOS input events.
- Failures produce a useful artifact bundle instead of silent retries.
- No run artifacts, API keys, or tenant config changes are committed.
- The implementation is committed on `feat/openai-cua-runner`.

## Immediate Next Step After Plan Approval

Start Phase 1 and Phase 2:

1. Have the operator install/enable Codex app Computer Use if they want the immediate Codex-app path.
2. Implement the provider-neutral Swift mac adapter `doctor` and `observe` commands.
3. Launch tagged c11 with `openai-cua` and capture the first window screenshot.
4. Add the OpenAI runner only after the local screenshot/action loop is reliable.
