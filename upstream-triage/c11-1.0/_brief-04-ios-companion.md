# Topic 04: What a c11 iOS companion app would look like

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/04-ios-companion.md`

This one is exploratory. Atin said: "Talk me through what an iOS companion app would look like. I don't think we're interested in it though." Give him a clear picture and an honest recommendation, including "don't build it" if that is the right call.

1. **Study cmux's iOS app:** peer-to-peer over Iroh, push notifications, the Task Composer, and the `cmux-terminal-client` xcframework that has had prereleases this week. Cover what it actually does, how it pairs with the Mac, what it needs (account? relay?), and what it costs them to maintain.
2. **Atin's world:** his iPhone (Hoplight 17) is always with him. Every machine is on one Tailscale network. Atlas is always on, Hyperion roams. c11 flags already escalate to the menu bar extra. See `~/.claude/CLAUDE.md`'s Machines section.
3. **Sketch a c11 companion app:** the three to five core screens (for example, the fleet at a glance, flagged and waiting agents, reply or approve, read a tab's screen, launch a task), with ASCII mockups. Say what it must never do, and how it stays inside c11's doctrine.
4. **The cheaper ladder:** at least three lighter options with cost and value. For example: flag pushes through ntfy or Pushover, a tailnet-only web view served by c11, or a Shortcuts/Widget surface. Say where each one stops being enough.
5. **Recommendation:** whether any of this belongs in 1.0, later, or never.
