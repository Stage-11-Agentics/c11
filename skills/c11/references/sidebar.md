# Sidebar: Tiles, the Chaos Wizard, the workspace mission and folders

Print this page with `c11 guide sidebar`. How the sidebar lays out workspaces, what the Chaos button does, how a workspace's C11.md mission is found, and workspace folders. A link to `<page>.md` names another page: `c11 guide <page>`.

## Tiles

The sidebar shows **Tiles** (two or more columns) whenever its width fits two 162 pt columns at the chrome scale (324 pt at the standard scale), and cards below that. Width alone decides, live while the operator drags the sidebar edge. The operator's titlebar sidebar button steps hidden → 1 → 2 → 3 columns by setting that width (skipping counts the window can't fit), and its right-click menu picks a count directly; there is no stored column mode. A narrow window caps the shown width without changing the requested width, so widening it restores the columns. Tiles pack left to right, and every tile is the full workspace card, the same card one column shows; the cards in a row share its tallest card's height. When the full cards would scroll, every card becomes a two-line compact card (name, `WS N`, then the agent count, one mark per agent with flagged and waiting first, and an info button; a flagged workspace's second line is a band in the flag's color), and the cards return once they fit with a line to spare. The info button opens a summary card beside it: the workspace's mission, and each agent with its full panel number, state, flag reason and subtitle (shown even when the sidebar hides notification messages, since the click asks for detail); a click on an agent jumps to that panel. The summary stays open until the button again, its ×, Escape or a click elsewhere. Settings ▸ Sidebar Density (Automatic, Compact, Cards) pins either form. Agents can read `sidebar-state --json --workspace <ref>` (`layout.double_wide`, derived from the shown width, plus requested and effective width, columns, and `layout.density`, `cards` or `compact`); only the operator resizes the sidebar.

## The Chaos Wizard

In Tiles the sidebar footer holds one button per column: Waiting Agent, then Flagged Agents, then **Chaos**. With two columns, Flagged takes the second slot while any flag is up and Chaos has it otherwise; one column shows no Chaos button. Chaos is the Chaos Wizard: one click draws two commissions (premise, medium, constraint) and casts the default agent on each in a new `Chaos HH:MM` workspace, two areas side by side, filed in the sidebar's Chaos folder, each agent told to build only in its own studio under the Chaos root (`~/Chaos` unless the operator chose another). Each agent's first message names its piece. Agents drive the same thing with `c11 chaos draw|cast [--mode two|four|ensemble|one] [--seed <n>] [--dry-run] [--json]` (two by default; four is a 2x2 grid); a CLI cast never switches the operator's workspace. `<root>/DECK.md` replaces the built-in deck section by section, `<root>/casts.jsonl` records every cast, and `<root>/gallery.html` is the gallery. Claude Code asks to trust each new studio unless a parent folder is already trusted; trusting the Chaos root once covers every studio under it. If you are one of the artists, your prompt's studio rule is the whole contract: write nowhere else.

## Captains

A workspace can declare `captain` in its workspace metadata, with a default
from a marked captain line in its root's C11.md. The panel holding that exact
`mailbox.address` may be in another workspace or window, and may captain several
workspaces. c11 derives the relationship; a role label does not create it.

The visible captain panel has a solid full-perimeter inner outline, alongside
the existing focus/waiting frame. It follows the selected panel in an area,
not every panel sharing that area, and does not change its size. The sidebar
card has a fixed captain slot: the holder's title when present, a hollow mark
and address when declared but unheld. An undeclared captain has no empty-hat
warning. Multiple holders are marked ambiguous. Tooltips and the compact
summary expose the complete title/address; long names truncate in the card.
Compact cards keep two lines as holders arrive, leave or rename.

A workspace group can carry a Captain for all its members, and it shows once, on
the group header, never per member: a fixed mark slot on the name row, beside the
pin, in full and compact headers alike. The cap is filled while one open panel
holds the address, hollow when nobody does, and a warning glyph when several do;
the holder's title and the address are in its tooltip. The slot is always
reserved, so nothing moves when a Captain arrives or leaves. A member card leaves its own
captain slot empty when its resolved Captain is the address its group shows; a
member with a different Captain of its own still shows it on its card. Tooltips
and hover cards say "Group captain: ..." for an inherited Captain.

Presence means an open panel holds the address, not that its agent is idle or
its connection can ring. Use `mailbox send --to-captain` to address it; no holder
is an explicit send failure, not a promise to queue mail for a future holder.
See [metadata](metadata.md#workspace-metadata-and-captains).

## The workspace mission

**The workspace mission is there when the task needs it.** When
`C11_MISSION_FILE` is nonempty, it names the C11.md at the workspace root: the
project's mission and working notes, which supplement the project's
instructions. Read it when your task concerns the project's direction, next
steps or who is working on it. A session launched with no task is a plain
session; don't open the file just because the variable is set. c11 sets the
variable for CLI, saved-config and UI agent launches and never adds anything to
the launch prompt; it never edits C11.md or tenant configuration. The operator
and authorized agents maintain the file with ordinary tools.

Discovery is exactly `C11.md` at the workspace's stable root, independent of
terminal `cd` or a launch's `--cwd` override. Workspaces sharing a root share
one displayed mission: the first `## Mission` or `**Mission.**` paragraph,
falling back to the first prose paragraph. Per-workspace headings are notes,
not selectors; distinct missions need distinct roots in this version. A C11
block inside AGENTS.md/CLAUDE.md remains ordinary agent-readable context and
does not supply the native card or `C11_MISSION_FILE`.

Cards show one truncated sentence, in one column or in Tiles; hover shows the
mission paragraph and path. File edits normally appear within a few seconds. Missing, empty,
invalid UTF-8/binary, oversized (over 64 KiB), symlink and nonregular files
produce no mission card. Rootless and remote workspaces do not discover local
missions. Those launches clear `C11_MISSION_FILE` to an empty value; an already
running agent retains its launch context. c11 does not search parent folders
or other agents' files.

## Workspace folders

Folders are window-local records, not terminals. Start with
`c11 workspace-group list --json`; create an empty folder with
`c11 workspace-group create --name "Backend" --json`, then add ungrouped workspaces
with `c11 workspace-group add --group workspace_group:1 --workspaces workspace:2,workspace:3`.
Use UUIDs for durable references; `workspace_group:N` is an ephemeral handle, never
an ordinal to persist. Names can repeat and are not selectors.

All verbs accept `--window <ref|uuid>` and `--json`; omitted window means the caller's
window. `move --workspace <w> --to-group <g|none>` transfers a member. `delete` and
`ungroup` detach members without closing panels or processes; empty folders persist.
Group pin and workspace pin are independent. `focus` keeps an already selected member; changing to another member is blocked for socket callers. An empty folder returns `empty_group`.

`c11 reorder-workspaces --order workspace:3,workspace:1 --dry-run --json` predicts a
partial priority order within the pinned and unpinned segments. Remove `--dry-run`
to apply against current state. Membership is unchanged, and the moved workspaces
take their new places in the sidebar without carrying any group along.
`tree --all` shows folders and each member once, even when collapsed, in sidebar
order; its JSON keeps flat `windows[].workspaces`, adds `workspace_groups`,
`root_order` (the sidebar's root items in draw order) and workspace `group_id`.
Use `c11 --id-format both … --json` when you need UUIDs and refs together.
Full verbs, errors and ordering: [API reference](api.md#workspace-groups-and-batch-order).

In the sidebar, the chevron hides/shows member rows without changing the active
terminal. Click the group name to focus a member. The header stays highlighted
when its active member is hidden. Its fixed slots show members, flagged panels,
non-delegated waiting panels, and unread notifications separately, including hidden
members. Any flag makes the group signal violet, even on a delegated or plain
terminal, and the group signal stays generic when members carry different named
kinds; unread alone does not add a waiting panel. Counts above 99 show `99+`,
with exact counts in accessibility labels and tooltips.

Use the header menu for Rename, Color, Icon, Pin/Unpin, Ungroup or Delete Group;
name/icon popovers accept Escape to cancel. New Group is in the sidebar menu.
Workspace menus offer Move to Group and Ungrouped. Drag onto a header to join,
onto member edges to position, or onto the Ungrouped lane to leave. Groups and
ungrouped workspaces share one order: drop a workspace on the top third of a
header (or the bottom third of a collapsed or empty one) to place it beside the
group, and drop a group on an ungrouped workspace's edge to place it there. Dragging a panel from a panel strip onto a workspace card moves the panel into that workspace's focused area; the card turns gold while targeted, and the selected workspace does not change. Folder drags
reorder folders among groups and ungrouped workspaces within their pin segment. Cancelled/invalid drops do not commit.
These controls organize existing work; deleting a group never closes its members.
