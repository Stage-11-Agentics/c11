Backfill close-out. PR #30 merged 2026-04-20 (Workspace color prevalence — frame + dividers + sidebar tint), then C11-8 PR #45 (2026-04-22) refined the chrome (sidebar neutrality, continuous portal frame overlay, live Bonsplit active-indicator refresh).

M2a + M2b + M2c all delivered:
- Bonsplit DividerStyle struct + thickness override (M2a, submodule).
- Parent repo wires divider color/thickness through bonsplit; live customColor propagation (M2b).
- Outer workspace frame + sidebar overlay (M2c).

Verified on main via the C11-8 close-out: rapid color changes propagate atomically across outer frame, tab strip, active tab indicator, dividers, and workspace card; sidebar stays neutral; outline is continuous around terminal/browser/markdown including the right-edge scrollbar.