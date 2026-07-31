# Adversarial Plan Review

### Executive Summary
The plan is rigorous and detailed, especially around the core presentation mechanics, generic submodule extraction, and testing boundaries. However, it over-rotates on the isolated pure-function state machine and under-designs the system integration, edge cases, and human-agent feedback loops. The biggest concern is the strict decoupling of flags from terminal state, making "flags" purely manual toggles with zero automated lifecycles. This contradicts the core premise of a terminal multiplexer where state is derived from process behavior. Furthermore, the suppression mechanism is dangerously absolute and relies too heavily on "agent/operator discipline", risking silent failures.

### How Plans Like This Fail
- **The "Pure State" Fallacy**: The plan treats attention state as a neat, isolated projection. In reality, agent processes crash, enter infinite loops, or get SIGKILLed. A flag left up by a dead agent is a permanent false positive unless tied to the process lifecycle.
- **Cognitive Load Underestimation**: By pushing the burden of lowering flags entirely to the operator (or trusting agents to lower them), the system expects humans to perfectly maintain the attention state. Flags will rot. Operators will learn to ignore them.
- **The "Opt-in Transparency" Trap**: Suppression relies on operators remembering they suppressed something. When a suppressed agent goes off the rails or loops infinitely, the operator has zero visibility, creating a "silent failure" class.
- **UI/UX Bottlenecking**: A floating AppKit banner sounds clean in theory, but in practice, floating windows over PTYs often intercept clicks meant for the terminal, fail to follow scrolling/resizing perfectly, and can obscure critical top-line terminal output.

### Assumption Audit
1. **Assumption:** Agents will reliably raise and, crucially, *lower* flags when they unblock themselves. (Load-bearing)
   - *Likelihood to hold:* Low. Agents are notoriously bad at cleaning up after themselves. If an agent solves a problem it previously flagged, it will likely just continue working, leaving a stale flag.
2. **Assumption:** The operator will manually dismiss flags using the UI (X on banner) for every single blocker. (Load-bearing)
   - *Likelihood to hold:* Medium. Operators will do this initially, but as fleet size grows, manually dismissing banners becomes a chore, leading to flag blindness.
3. **Assumption:** A pure-UI banner overlay is safer than a PTY resize. (Cosmetic/Load-bearing UI)
   - *Likelihood to hold:* High for text preservation, but Low for interaction. Overlays obscure top-line terminal content, which often contains critical context (like a shell prompt, git status, or vim status line if scrolled).
4. **Assumption:** Suppressed agents don't need any visual indicator at rest. (Load-bearing for design)
   - *Likelihood to hold:* Medium. It looks clean, but an operator staring at 30 agents has no way to tell which ones are suppressed background tasks and which are just idle without querying metadata.

### Blind Spots
- **Process Death & Zombie Flags:** What happens to a flag if the underlying terminal process exits (0 or non-zero)? The plan says "Flags are sticky and clear only by explicit operator/agent lower." This implies a dead surface will keep a flag up forever until manually cleared.
- **Agent Spam / Flag Thrashing:** What if a malfunctioning agent in a loop calls `flag.raise` 100 times a second? The plan says "Repeated identical raise is idempotent," but what if it varies the reason string slightly each time? The UI will thrash, and the direct notification delivery will DOS the macOS notification center.
- **Suppression vs. Critical Errors:** The plan explicitly states: "suppressed surfaces deliver no system notification". If a suppressed agent hits a catastrophic kernel panic or out-of-memory error, and doesn't explicitly raise a flag before dying, it silently fails. The operator has no prompt to check on it.
- **Cross-Workspace Context Loss:** "No cross-workspace flag dashboard." If a flag is raised in a background workspace, the user only has the OS notification (which they might miss or clear). They have to manually hunt through workspaces to find the violet mark.

### Challenged Decisions
- **Decision:** Sticky flags with no auto-lower on terminal input or process exit.
  - *Counterargument:* Terminal input is the *literal definition* of a human intervening. If an agent says "I am blocked, I need a human," and the human starts typing into the PTY, the human has intervened. Forcing them to *also* click a tiny 'X' button is double-work and bad UX.
- **Decision:** Absolute zero visual treatment for suppression at rest.
  - *Counterargument:* While it prevents clutter, it destroys state legibility. A subtle, non-distracting indicator is necessary to differentiate "done" from "suppressed and done". Otherwise, the operator's mental model must perfectly cache the launch state of every agent.
- **Decision:** Direct system notifications bypassing `TerminalNotificationStore`.
  - *Counterargument:* By skipping the store, flags bypass the single source of truth for historical events. If an operator clears an OS notification, where is the log of what flags were raised while they were away from their desk? If they aren't in the raw unread list, they are ephemeral.

### Hindsight Preview
- Two years from now, we will regret making flags purely manual state. We will be writing a "flag decay" or "auto-lower on typing" feature because operators will constantly complain about "stale violet marks everywhere."
- We will regret not putting a hard rate limit on `flag.raise`. A buggy agent will inevitably DOS the macOS notification center, leading to an emergency hotfix.
- Early warning signs: Operators will start using a hypothetical `c11 lower-flag --all` (a command they will inevitably ask for) as a routine cleanup step, proving the manual lifecycle failed.

### Reality Stress Test
*Scenario:* An operator launches 20 agents overnight. 15 are suppressed. A network blip causes all 20 to fail simultaneously. The 5 normal ones go to 'waiting'. The 15 suppressed ones try to raise flags, but 5 of them crash before they can.
*Result:* The operator wakes up to 10 OS notifications (from the flags), 5 waiting marks, and 5 *silently dead* suppressed agents that look perfectly "idle". The operator trusts the system, assumes the 5 silent ones succeeded, and makes a disastrous downstream commit based on missing data.

### The Uncomfortable Truths
- The plan assumes agents are polite and competent. In reality, agents are chaotic. Giving them a direct, un-rate-limited pipeline to the macOS notification center is a loaded gun.
- The "suppression" feature is actually just a "mute" button, and treating it as a core architectural concept might be over-engineering a problem that could be solved by just letting users clear the 'waiting' state easier.
- The UI complexity of floating banners, multiple clock offsets, and custom SwiftUI motion overrides is massive for a feature that is supposed to be "rare" (9 out of 10 agents won't use it).

### Hard Questions for the Plan Author
1. What exactly happens to a raised flag when the underlying Ghostty PTY process exits? Does the flag stay up on a dead pane?
2. How do you prevent a malfunctioning agent from spamming the macOS notification center by rapidly raising flags with slightly different reason strings?
3. If an operator starts typing into a flagged surface's terminal, why is that *not* considered sufficient proof that the operator is addressing the flag?
4. If a suppressed agent process crashes unexpectedly without raising a flag, how does the operator know it failed rather than succeeded, given it will just sit at 'idle'?
5. Why are direct flag notifications deliberately excluded from the raw `TerminalNotificationStore` history? How does an operator review flags raised while they were away from their desk?
6. Does the floating `NSHostingView` banner properly track the surface if the user rapidly resizes the entire app window or splits the pane, or will it visually detach/lag?
