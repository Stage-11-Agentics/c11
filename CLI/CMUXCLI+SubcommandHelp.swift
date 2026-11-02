// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    /// Return the help/usage text for a subcommand, or nil if the command is
    /// unknown. `commandArgs` is the slice after the top-level command token,
    /// allowing two-level dispatch for commands like `workspace` that have
    /// their own subcommand surface (e.g. `c11 workspace new --help`).
    func subcommandUsage(_ command: String, commandArgs: [String] = []) -> String? {
        switch Self.canonicalCommandName(command) {
        case "agents":
            return """
            Usage: c11 agents [--json] [--bundle-id <id>]

            Print the journal-backed agent roster. The running app is read with
            agents.list and is not focused, launched, or resumed. With the app
            down, pass --bundle-id to read that bundle's journal read-only.
            Omitting --bundle-id while the app is down returns an empty roster
            and does not guess a bundle.

            Flags:
              --json             Print the roster JSON.
              --bundle-id <id>   Require this bundle. A live app whose bundle
                                 differs is rejected. Offline, an invalid id
                                 errors; a missing journal returns empty
                                 candidates and storage unavailable.
            """
        case "history":
            return """
            Usage: c11 history [list] [--json] [--limit <1...200>]
                   c11 history back [--json]
                   c11 history forward [--json]

            List completed focus visits that met the dwell threshold, or navigate
            to an earlier/later live panel. History spans all windows; --window does
            not change selection before this command.

            Flags:
              --limit <n>  Show the newest n entries, oldest first (default: 50, max: 200).
                           Applies only to listing.
              --json       Return the history JSON, including durable UUIDs and live refs.

            Titles are resolved live. Saved history contains only workspace/panel
            UUIDs, visit start time, and dwell; closed panels are pruned.
            """
        case "ping":
            return """
            Usage: c11 ping

            Check connectivity to the c11 socket server.
            """
        case "capabilities":
            return """
            Usage: c11 capabilities

            Print methods, versioned features, CLI/server bundle identities and sha_match as JSON.
            sha_match is null when either build has no commit stamp.
            """
        case "fleet":
            return """
            Usage: c11 fleet [--json]

            Read every agent terminal across every window and workspace in one call.
            Ordinary terminals, browsers and markdown panels are excluded. No focus,
            selection, flag, seen-state or mailbox changes. --window does not narrow it.
            JSON uses schema_version 1, durable UUIDs and explicit nulls for unknowns.
            Mail counts are the mailbox cell's last cached count, null until measured.
            See c11 guide api for the complete schema. Plain output is a short table.
            """
        case "rpc":
            return """
            Usage: c11 rpc <method> [json] [--json]

            Call one local socket method and print its result as JSON.
            Params must be a JSON object. Prefer a friendly command when available.
            Remote commands over c11 ssh remain unavailable.
            """
        case "guide":
            return """
            Usage: c11 guide [page] [--json]
                   c11 --skill [page] [--json]

            Print the skill shipped in this CLI's app bundle without connecting to a socket.
            Optional page names select bundled markdown pages (for example: api).
            """
        case "brand":
            return """
            Usage: c11 brand [--json]

            Print the c11 brand and build identity.
            """
        case "config":
            return """
            Usage: c11 config <subcommand> [options]

            Manage saved launch configurations. File-backed commands work with
            the app down; `launch` starts a configured panel in c11.

            Subcommands:
              list [--json]                         List saved configurations.
              recent [--json]                       Show recent launch history.
              stats [--window <n>] [--by <axis>]    Show launch statistics.
              save <name> [fields]                  Save a configuration.
              edit <name|id> [fields]               Edit a configuration.
              rm <name|id>                          Remove a configuration.
              reorder <name|id> --to <index>        Move a configuration.
              default <name|id>|--pin-current       Set the default configuration.
              launch <name|id> [fields]              Launch a configuration.

            """
        case "usage", "report":
            return ActivityAnalysisCommand.usage
        case "events":
            return eventsUsage()
        case "messages":
            return messagesUsage()
        case "mailbox":
            return mailboxUsage()
        case "help":
            return """
            Usage: c11 help

            Show top-level CLI usage and command list.
            """
        case "welcome":
            return """
            Usage: c11 welcome

            Show a welcome screen with the c11 logo and useful shortcuts.
            Auto-runs once on first launch.
            """
        case "shortcuts":
            return """
            Usage: c11 shortcuts
                   c11 shortcuts list [--customized]
                   c11 shortcuts set <action> <combo|none>
                   c11 shortcuts reset <action> | --all

            Without a verb, open the Settings window to Keyboard Shortcuts.
            Changes apply live: the menu, key handling and an open Settings window
            update at once, exactly as if recorded in Settings.

            Actions use list's names (toggle-sidebar, split-right, ...).
            Combos take modifiers plus one key: ctrl, opt, shift, cmd joined by +,
            then a letter, digit, arrow (left|right|up|down), tab, return, or one
            of [ ] - = , . / ; ' ` \\. The display form (⌃⌥⌘X) also works.
            "none" leaves the action without a shortcut.

            Examples:
              c11 shortcuts list --customized
              c11 shortcuts set toggle-sidebar ctrl+opt+cmd+x
              c11 shortcuts reset toggle-sidebar
            """
        case "feedback":
            return """
            Usage: c11 feedback
                   c11 feedback --email <email> --body <text> [--image <path> ...]

            Without args, open the Send Feedback modal in the running app.

            With args, submit feedback through the app using the same feedback pipeline as the modal.

            Flags:
              --email <email>   Contact email for follow-up
              --body <text>     Feedback body
              --image <path>    Attach an image file, repeat for multiple images

            Coding agents:
              Double check with the end user before sending anything. Review the message and attachments for secrets,
              private code, credentials, tokens, and other sensitive information first.
            """
        case "themes":
            return """
            Usage: c11 themes list
                   c11 themes get [--slot light|dark]
                   c11 themes set <name> [--slot light|dark|both]
                   c11 themes clear
                   c11 themes reload
                   c11 themes path
                   c11 themes dump [--json] [--color-scheme light|dark]
                   c11 themes validate <path>
                   c11 themes diff <a> <b>

            Manage c11 chrome themes: sidebar, title bars, panel bar, dividers,
            browser chrome, markdown chrome, and workspace frame.

            Commands:
              list                      List available c11 chrome themes
              get [--slot light|dark]   Read the active c11 chrome theme
              set <name> [--slot ...]   Set a c11 chrome theme for light, dark, or both slots
              clear                     Remove c11 chrome theme overrides
              reload                    Re-scan the user c11 themes directory
              path                      Print bundled and user c11 themes directories
              dump                      Print the resolved c11 chrome theme
              validate <path>           Validate a c11 chrome theme file
              diff <a> <b>              Compare two c11 chrome themes

            Examples:
              c11 themes list
              c11 themes set phosphor --slot both
              c11 themes dump --json --color-scheme dark
              c11 themes validate path/to/mytheme.toml
              c11 themes clear
            """
        case "terminal-theme":
            return """
            Usage: c11 terminal-theme
                   c11 terminal-theme list
                   c11 terminal-theme set <terminal-theme>
                   c11 terminal-theme set --light <terminal-theme> [--dark <terminal-theme>]
                   c11 terminal-theme set --dark <terminal-theme> [--light <terminal-theme>]
                   c11 terminal-theme clear

            Manage Ghostty terminal themes for terminal cells, ANSI colors, cursor,
            selection, and terminal background/foreground.

            When run in a TTY, `c11 terminal-theme` opens the interactive Ghostty
            terminal theme picker. Use `c11 terminal-theme list` for a plain listing.

            Commands:
              list                      List available Ghostty terminal themes and mark the current light/dark defaults
              set <terminal-theme>      Set the same Ghostty terminal theme for both light and dark appearance
              set --light <terminal-theme>
                                        Set the light appearance Ghostty terminal theme
              set --dark <terminal-theme>
                                        Set the dark appearance Ghostty terminal theme
              clear                     Remove the managed Ghostty terminal theme block

            Examples:
              c11 terminal-theme
              c11 terminal-theme list
              c11 terminal-theme set "Catppuccin Mocha"
              c11 terminal-theme set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              c11 terminal-theme clear
            """
        case "claude-teams":
            return String(localized: "cli.claude-teams.usage", defaultValue: """
            Usage: c11 claude-teams [claude-args...]

            Launch Claude Code with agent teams enabled.

            This command:
              - defaults Claude teammate mode to auto
              - sets a tmux-like environment so Claude auto mode uses c11 splits
              - sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to claude

            The tmux shim translates supported tmux window/pane commands into c11
            workspace and split operations in the current c11 session.

            Examples:
              c11 claude-teams
              c11 claude-teams --continue
              c11 claude-teams --model sonnet
            """)
        case "link":
            return """
            Usage: c11 [--window <id|ref|index>] link --panel <id|ref|index> [--workspace <scope>] [--format url|markdown|osc8] [--json]
                   c11 [--window <id|ref|index>] link --workspace <id|ref|index> [--format url|markdown|osc8] [--json]

            Generate a link to an explicitly named live panel or workspace.
            The command only reads inventory; it never selects or activates a target.

            Flags:
              --panel <id|ref|index>      Target panel; --workspace optionally scopes lookup
              --workspace <id|ref|index>  Target workspace when --panel is absent
              --format <format>          url (default), markdown, or osc8
              --json                     All three formats, UUID, title, and owning workspace

            UUIDs and refs must still exist in the requested scope. Ambiguous indexes fail;
            use a UUID, ref, --workspace scope, or global --window scope.
            Labels are bounded single-line text with terminal controls removed.
            Markdown labels are escaped; JSON encodes OSC 8 control bytes as escapes.
            The generated c11:// URLs work inside c11 and do not register an OS URL handler.
            """
        case "identify":
            return """
            Usage: c11 identify [--workspace <id|ref|index>] [--panel <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $C11_WORKSPACE_ID)
              --panel <id|ref|index>   Caller panel context (default: $C11_PANEL_ID)
              --no-caller                  Omit caller context from the request
            """
        case "list-windows":
            return """
            Usage: c11 list-windows

            List open windows.
            """
        case "current-window":
            return """
            Usage: c11 current-window

            Print the currently selected window ID.
            """
        case "new-window":
            return """
            Usage: c11 new-window

            Create a new window.

            Example:
              c11 new-window
            """
        case "focus-window":
            return """
            Usage: c11 focus-window --window <id|ref|index>

            Focus (bring to front) the specified window.

            Flags:
              --window <id|ref|index>   Window to focus (required)

            Example:
              c11 focus-window --window 0
              c11 focus-window --window window:1
            """
        case "resize-window":
            return """
            Usage: c11 resize-window --window <id|ref|index> <width> <height>

            Set a window's frame while preserving its top-left, without focusing it.
            Use - to keep one edge, or - - to read the current frame.
            Sizes clamp to the window minimum and its screen's visible size.
            Fullscreen windows are refused. The result is JSON.
            """

        case "close-window":
            return """
            Usage: c11 close-window --window <id|ref|index|self>

            Close the specified window.

            Flags:
              --window <id|ref|index|self>   Window to close (required; self = the window of $C11_WORKSPACE_ID)

            Example:
              c11 close-window --window 0
              c11 close-window --window window:1
            """
        case "move-workspace-to-window":
            return """
            Usage: c11 move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref|index>   Workspace to move (required)
              --window <id|ref|index>      Target window (required)

            Example:
              c11 move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-panel", "move-tab":
            return """
            Usage: c11 move-panel [--panel <id|ref|index> | <id|ref|index>] [flags]

            Move a panel to a different area, workspace, or window.

            Flags:
              --panel <id|ref|index>   Panel to move (required unless passed positionally)
              --area <id|ref|index>      Target area
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this panel
              --before-panel <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this panel
              --after-panel <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the panel after moving

            Example:
              c11 move-panel --panel panel:1 --workspace workspace:2
              c11 move-panel panel:1 --area area:2 --index 0
            """
        case "reorder-panel", "reorder-tab":
            return """
            Usage: c11 reorder-panel [--panel <id|ref|index> | <id|ref|index>] [flags]

            Reorder a panel within its area.

            Flags:
              --panel <id|ref|index>   Panel to reorder (required unless passed positionally)
              --workspace <id|ref|index> Workspace context
              --before <id|ref|index>    Place before this panel
              --before-panel <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this panel
              --after-panel <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index

            Example:
              c11 reorder-panel --panel panel:1 --index 0
              c11 reorder-panel --panel panel:3 --after panel:1
            """
        case "workspace-group":
            return """
            Usage: c11 workspace-group <verb> [--window <window-ref|uuid>] [--json]

              list
              create --name <text>
              rename --group <g> --name <text>
              delete|ungroup|collapse|expand|pin|unpin|focus --group <g>
              add|remove --group <g> --workspaces <comma-separated-workspace-handles>
              move --group <g> (--before <g>|--after <g>|--index <n>)
              move --workspace <w> --to-group <g|none> [--before <w>|--after <w>]
              set-color --group <g> (--color <hex>|--clear)
              set-icon --group <g> (--icon <SF-symbol>|--clear)

            Groups use UUIDs or ephemeral workspace_group:N refs, never names/indexes.
            Omitted --window uses the caller's window. Cross-window grouping is unsupported.
            Empty groups persist. Delete and ungroup both detach members without closing them.
            Add requires ungrouped members; use move to transfer between groups.
            Group pin and member pin are independent; moves stay inside pin segments.
            Focus selects a member without activating the app; an empty group returns empty_group.
            Other verbs preserve selection and focus. Collapse never changes tree JSON membership.

            Examples:
              c11 workspace-group create --name "Backend" --json
              c11 workspace-group add --group workspace_group:1 --workspaces workspace:2,workspace:3
              c11 workspace-group move --workspace workspace:2 --to-group none
              c11 workspace-group list --window window:1 --json
            """

        case "reorder-workspaces":
            return """
            Usage: c11 reorder-workspaces --order <comma-separated-workspace-handles>
                       [--window <window-ref|uuid>] [--dry-run] [--json]

            A nonempty partial priority list: requested pinned, remaining pinned,
            requested unpinned, remaining unpinned. Untouched relative order is stable.
            Membership, group order and selection are preserved. Duplicate, missing or
            wrong-window targets fail before any change. Apply publishes one final order.
            Dry-run predicts current order only; it is advisory, not a reservation.
            JSON: window_id, dry_run, changed, final_workspace_ids, and per-request moves.
            Only a changed apply emits workspace.reordered; dry-run and no-op emit nothing.

            Example:
              c11 reorder-workspaces --order workspace:3,workspace:1 --dry-run --json
            """

        case "reorder-workspace":
            return """
            Usage: c11 reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required unless passed positionally)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --before-workspace <id|ref|index>
                                         Alias for --before
              --after <id|ref|index>       Place after this workspace
              --after-workspace <id|ref|index>
                                         Alias for --after
              --window <id|ref|index>      Window context

            Example:
              c11 reorder-workspace --workspace workspace:2 --index 0
              c11 reorder-workspace --workspace workspace:3 --after workspace:1
            """
        case "workspace-action":
            return """
            Usage: c11 workspace-action --action <name> [flags]

            Perform workspace context-menu actions from CLI/socket.

            Actions:
              pin | unpin
              rename | clear-name
              move-up | move-down | move-top
              close-above | close-below
              mark-read | mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index|self>  Target workspace (default: current/$C11_WORKSPACE_ID;
                                           required for close-above | close-below)
              --title <text>               Title for rename (or pass trailing title text)

            Example:
              c11 workspace-action --workspace workspace:2 --action pin
              c11 workspace-action --action rename --title "infra"
              c11 workspace-action --workspace self close-below
            """
        case "panel-action", "tab-action":
            return """
            Usage: c11 panel-action --action <name> [flags]

            Perform panel context-menu actions (the panel bar's right-click menu) from CLI/socket.

            Actions:
              rename | clear-name
              close-left | close-right | close-others
              new-terminal-right | new-browser-right
              reload | duplicate
              pin | unpin
              mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --panel <id|ref|index|self>  Target panel (default: $C11_PANEL_ID, then focused panel;
                                           required for close-left | close-right | close-others)
              --workspace <id|ref|index>   Workspace context (default: current/$C11_WORKSPACE_ID)
              --title <text>               Title for rename (or pass trailing title text)
              --url <url>                  Optional URL for new-browser-right

            Example:
              c11 panel-action --panel panel:3 --action pin
              c11 panel-action --panel self --action close-right
              c11 panel-action --panel panel:2 --action rename --title "build logs"
            """
        case "rename-panel", "rename-tab":
            return """
            Usage: c11 rename-panel [--workspace <id|ref>] [--panel <id|ref>] [--] <title>

            Compatibility alias for panel-action rename.

            Resolution order for target panel:
            1) --panel
            2) $C11_PANEL_ID
            3) currently focused panel (optionally within --workspace)

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$C11_WORKSPACE_ID)
              --panel <id|ref>       Panel target (supports panel:<n>)
              --title <text>         Explicit title (or use trailing positional title)

            Examples:
              c11 rename-panel "build logs"
              c11 rename-panel --panel panel:3 "staging server"
              c11 rename-panel --workspace workspace:2 --panel panel:5 --title "agent run"
            """
        case "set-title":
            return """
            Usage: c11 set-title [--panel <ref>] [--workspace <ref>] [--source <src>] <title-text>
                   c11 set-title [--panel <ref>] [--workspace <ref>] [--source <src>] --from-file <path>
                   c11 set-title [--panel <ref>] --json

            Set the panel's canonical `title` metadata key (M7 + M2).

            Flags:
              --panel <ref>   Target panel (default: $C11_PANEL_ID, then focused)
              --workspace <ref>   Workspace context (default: current/$C11_WORKSPACE_ID)
              --source <src>      Write source: explicit | declare | osc | heuristic (default: explicit)
              --from-file <path>  Read title text from file (use '-' for stdin)
              --json              Emit raw v2 socket result as JSON

            Exit non-zero when precedence gate blocks the write (applied=false).

            Examples:
              c11 set-title "Running smoke tests"
              c11 set-title --panel panel:3 "build logs"
              echo "Agent: gemini" | c11 set-title --source declare --from-file -
            """
        case "set-description":
            return """
            Usage: c11 set-description [--panel <ref>] [--workspace <ref>] [--source <src>] [--auto-expand=false] <description-text>
                   c11 set-description [--panel <ref>] [--workspace <ref>] [--source <src>] --from-file <path>

            Set the panel's canonical `description` metadata key (M7 + M2).

            Description supports inline Markdown: **bold**, *italic*, `inline code`.
            Block-level Markdown and links render as literal text.

            Flags:
              --panel <ref>     Target panel (default: $C11_PANEL_ID, then focused)
              --workspace <ref>     Workspace context (default: current/$C11_WORKSPACE_ID)
              --source <src>        Write source: explicit | declare | osc | heuristic (default: explicit)
              --from-file <path>    Read description text from file (use '-' for stdin)
              --auto-expand=false   Suppress first-set auto-expand behavior for this write
              --json                Emit raw v2 socket result as JSON

            Examples:
              c11 set-description "Running **10 shards** in parallel"
              c11 set-description --auto-expand=false --from-file ./notes.md
            """
        case "set-panel-icon":
            return """
            Usage: c11 set-panel-icon [--panel <ref>] [--workspace <ref>] [--source <src>] <icon>
                   c11 set-panel-icon [--panel <ref>] (--clear | "")

            Set the panel's canonical `icon` metadata key: a short glyph (≤32 chars,
            usually one emoji; "sf:<symbol>" for an SF Symbol). It renders pinned
            on the panel's right edge, just left of the close X, and after the
            title in the panel sheet and rail. Tinted by the panel color when set.
            Same as `c11 set-metadata --panel <ref> --key icon --value <icon>`.

            Flags:
              --panel <ref>       Target panel (default: $C11_PANEL_ID)
              --workspace <ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --source <src>      Write source: explicit | declare | osc | heuristic (default: explicit)
              --clear             Remove the icon (an empty value does the same)
              --json              Emit raw v2 socket result as JSON

            Examples:
              c11 set-panel-icon --panel "$C11_PANEL_ID" "🚀"
              c11 set-panel-icon --panel panel:3 sf:hammer.fill
              c11 set-panel-icon --panel panel:3 --clear
            """
        case "set-panel-color":
            return """
            Usage: c11 set-panel-color [--panel <ref>] [--workspace <ref>] [--source <src>] <color>
                   c11 set-panel-color [--panel <ref>] (--clear | "")

            Set the panel color: "#RRGGBB" or a palette name (red, crimson, orange,
            amber, olive, green, teal, aqua, blue, navy, indigo, purple, magenta,
            rose, brown, charcoal; `c11 panel-color list-palette` lists them). The
            color tints the panel's icon badge (a dot when no icon is set) and its
            top accent rail. It is the same color as the panel's right-click color
            menu and `c11 panel-color`, stored as canonical metadata `color`.
            Same as `c11 set-metadata --panel <ref> --key color --value <color>`.

            Flags:
              --panel <ref>       Target panel (default: $C11_PANEL_ID)
              --workspace <ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --source <src>      Write source: explicit | declare | osc | heuristic (default: explicit)
              --clear             Remove the color (an empty value does the same)
              --json              Emit raw v2 socket result as JSON

            Examples:
              c11 set-panel-color --panel "$C11_PANEL_ID" teal
              c11 set-panel-color --panel panel:3 "#C0392B"
              c11 set-panel-color --panel panel:3 --clear
            """
        case "get-titlebar-state":
            return """
            Usage: c11 get-titlebar-state [--panel <ref>] [--workspace <ref>] [--json]

            Read the title bar's current state for a panel: title, description, sources,
            collapsed flag, visibility flag, and the truncated `sidebar_label` projection.

            Flags:
              --panel <ref>   Target panel (default: $C11_PANEL_ID, then focused)
              --workspace <ref>   Workspace context (default: current/$C11_WORKSPACE_ID)
              --json              Emit raw v2 socket result as JSON

            Example:
              c11 get-titlebar-state --json
            """
        case "new-workspace":
            return """
            Usage: c11 new-workspace [--cwd <path>] [--root <path>] [--command <text>] [--title <text>] [--layout <path|name>]

            Create a new workspace.

            Flags:
              --cwd <path>           Set the working directory for the new workspace
              --root <path>          Set its stable agent-launch root (also the cwd when --cwd is omitted)
              --command <text>       Queue text+Return into the new shell; incompatible with --layout
              --title <text>         Set the workspace title inline (same as a follow-up rename)
              --layout <path|name>   Apply a blueprint plan (file path or blueprint name)

            Example:
              c11 new-workspace
              c11 new-workspace --cwd ~/projects/myapp
              c11 new-workspace --root ~/projects/myapp
              c11 new-workspace --title "Auth refactor"
              c11 new-workspace --cwd . --command "npm test"
              c11 new-workspace --layout my-review-room
              c11 new-workspace --layout /path/to/blueprint.json
            """
        case "list-workspaces":
            return """
            Usage: c11 list-workspaces [--json]

            List workspaces in the current window.

            Example:
              c11 list-workspaces
            """
        case "ssh":
            return """
            Usage: c11 ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            c11 will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              --ssh-option <opt>      Extra SSH -o option (repeatable)

            Example:
              c11 ssh dev@my-host
              c11 ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              c11 ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
            """
        case "ssh-session-end":
            return """
            Usage: c11 ssh-session-end --relay-port <port> [--workspace <ref>] [--panel <ref>]

            Notify c11 that an SSH terminal session has ended.
            Defaults to C11_WORKSPACE_ID and C11_PANEL_ID when omitted.
            """
        case "remote-daemon-status":
            return """
            Usage: c11 remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]

            Show the embedded c11d-remote release manifest, local cache status, checksum verification state,
            and the GitHub attestation verification command for a target platform.

            Example:
              c11 remote-daemon-status
              c11 remote-daemon-status --os linux --arch arm64
            """
        case "health":
            return """
            Usage: c11 health [--since <duration> | --since-boot] [--rail <name>] [--json]

            Read-only crash-visibility sweep across four local rails: Apple IPS reports,
            queued Sentry envelopes, MetricKit diagnostic payloads, and the c11 launch
            sentinel (catches Force Quit and SIGKILL where Sentry cannot).

            Flags:
              --since <duration>     Time window: 30m, 2h, 24h, 3d. Default 24h.
              --since-boot           Limit to events since the last system boot.
              --rail <name>          Filter to one rail: ips, sentry, metrickit, sentinel. Specify at most once. Default: all rails.
              --json                 Emit structured JSON instead of the default table.

            Example:
              c11 health
              c11 health --since 30m
              c11 health --since-boot --rail sentinel
              c11 health --json
            """
        case "doctor":
            return """
            Usage: c11 doctor [--json]

            Live-environment introspection for CLI resolution: which `c11` and
            `cmux` binaries the current shell will invoke, what the active
            bundle's CLI is, and whether they agree. Companion to `c11 health`,
            which inspects post-mortem crash rails.

            Best run inside a c11 terminal so CMUX_BUNDLED_CLI_PATH is set.

            Flags:
              --json     Emit a stable lowercase-snake JSON object instead of
                         the default table. Schema:
                           status               ok | mismatch | missing | no_bundle
                           bundled_cli_path     absolute path | omitted
                           c11_on_path          absolute path | omitted
                           cmux_on_path         absolute path | omitted
                           bundled_cli_version  first line of `--version` | omitted
                           c11_on_path_version  first line of `--version` | omitted
                           path_fix_applied     bool — true when the bundled
                                                CLI's directory is the first
                                                entry on PATH (structural
                                                proxy for the shell
                                                integration having run)
                           path                 PATH split into entries
                           notes                array of human-readable warnings

            Example:
              c11 doctor
              c11 doctor --json
            """
        case "new-split":
            return """
            Usage: c11 new-split <left|right|up|down> [flags]

            Split the current area in the given direction.

            Flags:
              --command <text>                    Queue text+Return into the new terminal shell
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Panel to split from (default: $C11_PANEL_ID)
              --title <text>         Seed the new area's title metadata atomically with creation
              --cwd <path|inherit>   Working directory for the new shell. A path
                                     (absolute or relative to where the CLI ran,
                                     so `--cwd .` works) is validated and must be
                                     an existing directory. `inherit` (the
                                     default when omitted) uses the workspace
                                     root, else the parent panel's cwd.
              --allow-undersized     Bypass the size-aware split policy for this
                                     call (alias: --force). Without it, c11 may
                                     flip the split axis, fall back to a panel, or
                                     refuse a split that would leave an area too
                                     small to use.

            Size-aware splits: c11 will not create an area too small to be usable.
            If the requested direction would leave a child below the minimum for
            its panel kind (coding-agent TUIs need more room than a shell), c11
            flips to the roomier axis, refuses with guidance, or — in `panel` mode —
            adds a panel instead. Tune via Settings (paneSizeMode) or the
            C11_SPLIT_SIZE_POLICY env var (off|warn|balance|panel).

            Example:
              c11 new-split right
              c11 new-split down --workspace workspace:1
              c11 new-split right --title "Parent :: Code Review"
              c11 new-split right --cwd /Users/me/project
              c11 new-split down --cwd .
              c11 new-split down --allow-undersized
            """
        case "list-areas":
            return """
            Usage: c11 list-areas [--workspace <id|ref>]

            List areas in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 list-areas
              c11 list-areas --workspace workspace:2
            """
        case "list-area-panels", "list-area-tabs":
            return """
            Usage: c11 list-area-panels [--workspace <id|ref>] [--area <id|ref>]

            List panels in an area.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --area <id|ref>        Restrict to a specific area (default: focused area)

            Example:
              c11 list-area-panels
              c11 list-area-panels --workspace workspace:2 --area area:1
            """
        case "family":
            return """
            Usage: c11 family [--panel <ref>] [--json]

            Show the target panel's creation root and its descendants. The
            default panel is the caller's C11_PANEL_ID.

            JSON returns versioned nodes with parent_panel_id, live/closed
            state, title, type, agent_type, delegation, and workspace details.
            """
        case "tree":
            return """
            Usage: c11 tree [flags]

            Print the hierarchy of windows, workspaces, areas, and panels, with
            spatial coordinates and an ASCII floor plan of the current workspace.

            Flags:
              --all                         Include all windows and all workspaces
              --window                      Include all workspaces in the current window
              --workspace <id|ref|index>    Show only one workspace
              --layout                      Render the floor plan even when scope > 1 workspace
              --no-layout                   Suppress the floor plan unconditionally
              --canvas-cols <N>             Override the floor-plan canvas width (default: auto, min 40)
              --json                        Structured JSON output (layout in `layout`/`content_area` keys)
              --report                      Human-readable Markdown snapshot: layout + each panel's
                                            manifest (title, agent, status, description). Alias: --markdown.
                                            Defaults to every window/workspace; narrow with --window/--workspace.
              --out <path>                  With --report, write the Markdown to a file instead of stdout

            Default scope: the caller's current workspace. Use --window for the
            pre-M8 behavior (current window, all workspaces); --all for every window.
            (`--report` defaults to --all unless you pass an explicit scope.)

            Note: `layout.split_path` is recomputed on every call from the live
            split tree — it is NOT a stable identifier. An area's split_path will
            change whenever the surrounding splits change. Use the area ref/UUID
            to track an area across layout mutations.

            Output:
              Text mode prints the floor plan (single-workspace scope) followed
              by a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/area/panel path)
              - ◀ here (caller panel where `c11 tree` was invoked)
              - workspace_group [pinned] [collapsed] members=N (folders retain empty headers)
              - workspace [selected] (shown once under its folder, or at the window root)
              - area [focused] size=W%×H% px=W×H split=H:left|...
              - panel [selected]
              Browser panels also include their current URL.

            Example:
              c11 tree
              c11 tree --window
              c11 tree --all
              c11 tree --workspace workspace:2
              c11 --json tree --all
              c11 tree --report
              c11 tree --report --out ~/c11-fleet-$(date +%F).md
            """
        case "focus-area":
            return """
            Usage: c11 focus-area [--area <id|ref> | <id|ref>] [flags]

            Focus the specified area within its workspace without switching workspaces.

            Flags:
              --area <id|ref>          Area to focus (required unless passed positionally)
              --workspace <id|ref>     Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 focus-area --area area:2
              c11 focus-area area:1
              c11 focus-area --area area:1 --workspace workspace:2
            """
        case "new-area":
            return """
            Usage: c11 new-area [flags]

            Create a new area in the workspace by splitting the caller's area
            ($C11_PANEL_ID) when it is in the target workspace, else the focused area.

            Flags:
              --command <text>                    Queue text+Return into the new terminal shell
              --type <terminal|browser|markdown>  Area type (default: terminal)
              --direction <left|right|up|down>    Split direction (default: right)
              --workspace <id|ref>                Target workspace (default: $C11_WORKSPACE_ID)
              --url <url>                         URL for browser areas
              --profile <name|id>                 Browser profile for browser areas (one-shot)
              --file <path>                       File path for markdown areas
              --title <text>                      Seed the new area's title metadata atomically with creation
              --cwd <path|inherit>                Working directory for the new terminal. A path
                                                  (absolute or relative to the CLI's cwd) is
                                                  validated and must be an existing directory.
                                                  `inherit` (the default) uses the workspace root,
                                                  else the parent panel's cwd.
              --allow-undersized                  Bypass the size-aware split policy for this call
                                                  (alias: --force).

            Size-aware splits: c11 will not create an area too small to be usable.
            If the requested direction would leave a child below the minimum for its
            panel kind, c11 flips to the roomier axis, refuses with guidance, or —
            in `panel` mode — adds a panel instead. Tune via Settings (paneSizeMode) or
            the C11_SPLIT_SIZE_POLICY env var (off|warn|balance|panel).

            Example:
              c11 new-area
              c11 new-area --type browser --direction down --url https://example.com
              c11 new-area --type markdown --file ~/docs/README.md
              c11 new-area --title "Parent :: Code Review"
              c11 new-area --cwd /Users/me/project
              c11 new-area --allow-undersized
            """
        case "launch-agent":
            return """
            Usage: c11 launch-agent --type <kind> [flags]

            Launch a typed coding agent into a new panel (or a fresh workspace):
            correct per-agent invocation, model/effort flags, identity stamped at
            birth (env + sidebar metadata + panel title), machine-readable refs back.
            Canonical reference: docs/launch-agent-reference.md.

            Flags:
              --type <kind>            Required. Built-in: claude-code, codex, grok,
                                       kimi, opencode, github-copilot, pi, omp — or a
                                       kebab-case custom kind backed by
                                       ~/.config/c11/agents/<kind>.json
              --model <id>             Model to pin (rendered per the kind's template)
              --effort <tier>          Effort/thinking tier (errors if the kind has none)
              --system-prompt-mode <m> inherit | append | replace. append/replace
                                       inject the kind's system-prompt flag (errors
                                       if the kind has no system-prompt axis;
                                       claude-code only in v1)
              --system-prompt <text>   System-prompt text (append adds to the
                                       default; replace supplants it; empty +
                                       replace = blank slate)
              --system-prompt-file <p> Read the system-prompt text from a file
                                       (mutually exclusive with --system-prompt;
                                       an empty file is allowed = blank slate)
              --task <id>              Task identifier for sidebar telemetry
              --area <id|ref>          Target area (default: focused area)
              --workspace <id|ref>     Target workspace (default: $C11_WORKSPACE_ID)
              --new-workspace          Launch into a fresh workspace instead
              --cwd <path>             Working directory for the agent
              --prompt <text>          Initial prompt (one-shot argv where supported)
              --prompt-file <path>     Read the initial prompt from a file
              --title <text>           Panel title (default: launch placeholder)
              --flag <reason>          Raise a sticky flag before command delivery
              --by <actor>             Flag authority: operator (default) or agent;
                                       requires --flag
              --delegated              Route routine stops to the caller; flags still escalate
              --suppressed             Alias for --delegated
              --env KEY=VALUE          Extra spawn env (repeatable)
              --json                   Print the machine-readable result object

            Launches never steal focus or selection (socket focus policy) —
            the new panel is created in the background.

            Examples:
              c11 launch-agent --type claude-code --model opus --effort high
              c11 launch-agent --type codex --model gpt-5.2 --new-workspace --json
              c11 launch-agent --type opencode --prompt-file /tmp/brief.md --area area:2
              c11 launch-agent --type codex --delegated
              c11 launch-agent --type claude-code --flag 'Watch migration'
              c11 launch-agent --type claude-code --system-prompt-mode append \\
                --system-prompt 'Prefer terse answers.'
              c11 launch-agent --type claude-code --system-prompt-mode replace \\
                --system-prompt ''      # Gregorovich blank slate
            """
        case "raise-flag", "lower-flag", "delegate", "undelegate", "suppress", "unsuppress":
            return """
            Usage:
              c11 raise-flag --panel <id|ref> [--kind <slug>] "<reason>" [--by agent|operator]
              c11 lower-flag --panel <id|ref> [--by agent|operator]
              c11 delegate --panel <id|ref> [--by agent|operator]
              c11 undelegate --panel <id|ref> [--by agent|operator]

            Delegate aliases: suppress and unsuppress. Attention mutations
            require an explicit panel and never focus, select, or raise their target.
            """
        case "flag-kind":
            return """
            Usage:
              c11 flag-kind list [--json]
              c11 flag-kind set --id <slug> --name <name> --color <green|red|pink|teal> [--emoji <emoji>] [--json]
              c11 flag-kind rm --id <slug> [--json]

            Set creates or updates a named flag kind. Removing a built-in kind
            restores its shipped default. Supported colors are adaptive tokens.
            """
        case "new-panel", "new-tab":
            return """
            Usage: c11 new-panel [flags]

            Create a new panel in an area.

            Flags:
              --command <text>                    Queue text+Return into the new terminal shell
              --type <terminal|browser|markdown>  Panel type (default: terminal)
              --area <id|ref>                     Target area (default: the caller's area when it is
                                                  in the target workspace, else the focused area)
              --workspace <id|ref>                Target workspace (default: $C11_WORKSPACE_ID)
              --url <url>                         URL for browser panels
              --profile <name|id>                 Browser profile for browser panels (one-shot)
              --file <path>                       File path for markdown panels
              --cwd <path|inherit>                Working directory for a terminal panel. A path
                                                  (absolute or relative to the CLI's cwd) is
                                                  validated and must be an existing directory.
                                                  `inherit` (the default) uses the workspace root,
                                                  else the area's terminal cwd.

            Example:
              c11 new-panel
              c11 new-panel --type browser --area area:1 --url https://example.com
              c11 new-panel --type markdown --file ~/docs/notes.md
              c11 new-panel --cwd .
            """
        case "close-panel", "close-tab":
            return """
            Usage: c11 close-panel --panel <id|ref|self> [flags]

            Close a panel. The target is required: there is no default.

            Flags:
              --panel <id|ref|self>   Panel to close (required; self = $C11_PANEL_ID)
              --workspace <id|ref|self>   Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 close-panel --panel panel:3
              c11 close-panel --panel self
            """
        case "drag-panel-to-split", "drag-tab-to-split":
            return """
            Usage: c11 drag-panel-to-split --panel <id|ref|index> [--workspace <id|ref|index>] <left|right|up|down>

            Move a panel into a new split, preserving focus and workspace selection.
            Workspace defaults to C11_WORKSPACE_ID; outside c11, pass --workspace.

            Flags:
              --panel <id|ref|index>       Panel to drag (required)
              --workspace <id|ref|index>   Target workspace

            Example:
              c11 drag-panel-to-split --panel panel:1 right
              c11 drag-panel-to-split --panel panel:2 down
            """
        case "refresh-panels", "refresh-tabs":
            return """
            Usage: c11 refresh-panels [--workspace <id|ref|index>]

            Refresh panels in the caller's C11_WORKSPACE_ID or explicit --workspace.
            """
        case "panel-health", "tab-health":
            return """
            Usage: c11 panel-health [--workspace <id|ref>]

            List health details for panels in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 panel-health
              c11 panel-health --workspace workspace:2
            """
        case "debug-terminals":
            return """
            Usage: c11 debug-terminals

            Print live Ghostty terminal runtime metadata across all windows and workspaces.
            Intended for debugging stray or detached terminal views.
            """
        case "trigger-flash":
            return """
            Usage: c11 trigger-flash [--workspace <id|ref>] [--panel <id|ref>] [--color <#hex>] [--persistent]

            Trigger the unread flash indicator for a panel.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)
              --color <#hex>         One-shot color override (e.g. "#F5C518" or "#F5C518FF").
                                     Defaults to the c11 yellow signal color. Tints the
                                     terminal area ring and the sidebar workspace-row pulse.
                                     Browser and Markdown panel overlays and the panel-bar
                                     pulse keep their default accent — color override
                                     for those panels is a follow-up.
              --persistent           Keep pulsing until the operator clicks the panel or
                                     `c11 cancel-flash` is called. Auto-degrades to a single
                                     one-shot when the target is the focused panel in the
                                     focused window.

            Example:
              c11 trigger-flash
              c11 trigger-flash --workspace workspace:2 --panel panel:3
              c11 trigger-flash --panel panel:3 --color "#FF00FF"
              c11 trigger-flash --panel panel:3 --persistent
            """
        case "cancel-flash":
            return """
            Usage: c11 cancel-flash [--workspace <id|ref>] [--panel <id|ref>]

            Cancel any in-flight persistent flash on a panel. No-op for one-shot flashes
            and for panels with no active persistent flash.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)

            Example:
              c11 cancel-flash
              c11 cancel-flash --workspace workspace:2 --panel panel:3
            """
        case "list-panels", "list-tabs":
            return """
            Usage: c11 list-panels [--workspace <id|ref>]

            List panels in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 list-panels
              c11 list-panels --workspace workspace:2
            """
        case "focus-panel", "focus-tab":
            return """
            Usage: c11 focus-panel --panel <id|ref> [--workspace <id|ref>]

            Focus a specific panel.

            Flags:
              --panel <id|ref>     Panel to focus (required)
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)

            Example:
              c11 focus-panel --panel panel:2
              c11 focus-panel --panel panel:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: c11 close-workspace --workspace <id|ref|index|self>

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index|self>   Workspace to close (required; self = $C11_WORKSPACE_ID)

            Example:
              c11 close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: c11 select-workspace --workspace <id|ref|index>

            Workspace switching is reserved for the operator. Socket calls that would
            switch return workspace_switch_blocked; use background panel/area targeting.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)

            Example:
              c11 select-workspace --workspace workspace:2
              c11 select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: c11 rename-workspace [--workspace <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$C11_WORKSPACE_ID)

            Example:
              c11 rename-workspace "backend logs"
              c11 rename-window --workspace workspace:2 "agent run"
            """
        case "set-workspace-root":
            return """
            Usage: c11 set-workspace-root [--workspace <id|ref|index>] (<path> | --clear)

            Set or clear the workspace's stable root directory. Every new
            terminal in the workspace (panel, split, agent button, new-panel,
            new-split, new-area, launch-agent) starts in the root unless it is
            given an explicit --cwd. With no root, new terminals start in the
            source panel's cwd. Clearing also stops the workspace from
            adopting its next shell cwd as a root.

            Examples:
              c11 set-workspace-root ~/projects/myapp
              c11 set-workspace-root --workspace workspace:2 --clear
            """
        case "get-workspace-root":
            return """
            Usage: c11 get-workspace-root [--workspace <id|ref|index>] [--json]

            Print the workspace's root directory, or "(none)". A root that no
            longer exists is marked "(missing)". --json adds root_exists,
            root_adoption_armed (a rootless workspace adopts the first shell cwd
            other than ~ or /), and current_directory (the focused panel's cwd).

            Examples:
              c11 get-workspace-root
              c11 get-workspace-root --workspace workspace:2 --json
            """
        case "current-workspace":
            return """
            Usage: c11 current-workspace

            Print the currently selected workspace ID.
            """
        case "capture-pane":
            return """
            Usage: c11 capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $C11_PANEL_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              c11 capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: c11 resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: c11 pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: c11 wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: c11 swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $C11_WORKSPACE_ID)
            """
        case "break-pane":
            return """
            Usage: c11 break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
            """
        case "join-pane":
            return """
            Usage: c11 join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $C11_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: c11\(command)

            Reserved for operator navigation. Socket workspace changes return workspace_switch_blocked.
            """
        case "last-pane":
            return """
            Usage: c11 last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: c11 find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Request selection; cross-workspace socket changes return workspace_switch_blocked
            """
        case "clear-history":
            return """
            Usage: c11 clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
            """
        case "set-hook":
            return """
            Usage: c11 set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: c11 popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: c11\(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: c11 set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: c11 paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $C11_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: c11 list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: c11 respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $C11_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: c11 display-message [-p|--print] <text>

            Print text (or show it via notification bridge in parity mode).

            Flags:
              -p, --print   Print to stdout only
            """
        case "read-selection":
            return String(localized: "cli.read_selection.help", defaultValue: """
            Usage: c11 read-selection [--workspace <id|ref>] [--panel <id|ref>]

            Read a terminal's current selection without changing it.
            --json returns has_selection, text, base64, kind and truncated.
            No selection succeeds. Browser and markdown panels are unsupported.
            Response is capped at 1 MiB on a UTF-8 boundary. A busy renderer
            returns busy; the caller wait is five seconds. Native capture and
            formatting remain on main; their allocation and time are not bounded.
            """)
        case "input-state":
            return String(localized: "cli.input_state.help", defaultValue: """
            Usage: c11 input-state --panel <id|ref> [--workspace <id|ref>] [--json]

            Inspect one exact terminal panel's bounded active-screen input state.
            The result never includes prompt or draft text. --panel is required;
            this command does not fall back to the focused panel.
            """)
        case "read-screen":
            return """
            Usage: c11 read-screen [flags]

            Read terminal text from a panel as plain text.

            Flags:
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)
              --scrollback           Include scrollback (not just visible viewport)
              --lines <n>            Limit to the last n lines (implies --scrollback)

            Example:
              c11 read-screen
              c11 read-screen --panel panel:2 --scrollback --lines 200
            """
        case "send", "send-panel", "send-tab", "paste":
            return String(localized: "cli.send.help", defaultValue: """
            Usage: c11 \(command) [flags] [--] <text | ->

            Send text to a terminal panel. paste is an alias for send --raw;
            paste with no text reads stdin. send - reads stdin explicitly.
            Default send decodes \\n and \\r as Return, \\t as Tab.
            --raw preserves literal escapes and newline content.
            For raw/paste, --no-submit suppresses c11's additional Return.
            Default send still treats a trailing newline as submit. Newline content
            can execute in a program that does not use bracketed paste.
            Unknown --flags are errors before --; use -- for literal flag text.

            Flags:
              --workspace <id|ref>   Target workspace (default: caller workspace)
              --panel <id|ref>       Target panel (required for send-panel)
              --raw                 Literal escape/newline handling (send.raw required)
              --no-submit           Do not schedule an additional Return
              --allow-unguarded     Deliver even if a draft or dialog is detected
              --json                Report delivered, queued and submitted booleans

            The screen check is not atomic with a later keypress: typing can
            happen after the read and before the paste. send-key is not guarded.
            Delivery reports PTY input or queueing, never agent acknowledgment.
            send submits its own Return; do not follow it with send-key enter.
            To run a second command only after a send succeeded, chain with &&:
              c11 send --panel panel:2 "text" && c11 send-key --panel panel:2 enter
            A refused send exits nonzero and types nothing.
            """)
        case "send-key":
            return """
            Usage: c11 send-key [flags] [--] <key>

            Send a key event to a terminal panel.
            Pass one key per call; a second key is an error. Send the next key in its own call.

            Flags:
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)

            send-key is not guarded: it does not check for a draft or dialog.
            After a c11 send, chain with && so a refused send is not followed by a key:
              c11 send --panel panel:2 "text" && c11 send-key --panel panel:2 enter

            Example:
              c11 send-key enter
              c11 send-key --panel panel:2 ctrl+c
            """
        case "send-key-panel", "send-key-tab":
            return """
            Usage: c11 send-key-panel --panel <id|ref> [flags] [--] <key>

            Send a key event to a specific panel.
            Pass one key per call; a second key is an error. Send the next key in its own call.

            Flags:
              --panel <id|ref>     Target panel (required)
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)

            Example:
              c11 send-key-panel --panel panel:2 enter
              c11 send-key-panel --panel panel:2 ctrl+c
            """
        case "notify":
            return """
            Usage: c11 notify [flags]

            Send a notification to a workspace/panel.

            Flags:
              --title <text>         Notification title (default: "Notification")
              --subtitle <text>      Notification subtitle
              --body <text>          Notification body
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)

            Example:
              c11 notify --title "Build done" --body "All tests passed"
              c11 notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
            """
        case "area-confirm":
            return """
            Usage: c11 area-confirm --panel <id|ref> --title <text> [flags]

            Present a modal confirmation dialog anchored on a specific panel and
            wait for the user's decision. Card is scrim-bounded to the panel,
            so other areas stay interactive.

            Flags:
              --panel <id|ref>      Target panel (required)
              --title <text>          Card title (required)
              --message <text>        Informative text below the title
              --destructive           Render the confirm button with destructive styling
              --timeout <seconds>     Cancel after N seconds (capped at 300; default: 300)
              --confirm-label <text>  Override the confirm-button label (default: "OK")
              --cancel-label <text>   Override the cancel-button label (default: "Cancel")
              --workspace <id|ref>    Workspace context (optional; resolved from --panel)

            Exit codes:
              0  user confirmed
              2  user cancelled
              3  dialog dismissed (panel closed, workspace closed, or timeout)
              1  error

            Example:
              c11 area-confirm --panel panel:1 --title "Deploy to prod?" --destructive
              c11 area-confirm --panel $C11_PANEL_ID --title "Continue?" --timeout 60
            """
        case "feed":
            return FeedCommand.usageText
        case "list-notifications":
            return """
            Usage: c11 list-notifications

            List queued notifications.
            """
        case "clear-notifications":
            return """
            Usage: c11 clear-notifications

            Clear all queued notifications.
            """
        case "set-status":
            return """
            Usage: c11 set-status <key> <value> [flags]

            Set a sidebar status entry for a workspace. Status entries appear as
            pills in the sidebar workspace row. Use a unique key so different tools
            (e.g. "claude_code", "build") can manage their own entries.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --icon <name>          Icon name (e.g. "sparkle", "hammer")
              --color <#hex>         Pill color (e.g. "#ff9500")
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 set-status build "compiling" --icon hammer --color "#ff9500"
              c11 set-status deploy "v1.2.3" --workspace workspace:2
            """
        case "clear-status":
            return """
            Usage: c11 clear-status <key> [flags]

            Remove a sidebar status entry by key.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 clear-status build --workspace workspace:2
            """
        case "list-status":
            return """
            Usage: c11 list-status [flags]

            List all sidebar status entries for a workspace.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 list-status --workspace workspace:2
            """
        case "set-progress":
            return """
            Usage: c11 set-progress <0.0-1.0> [flags]

            Set a progress bar in the sidebar for a workspace.

            Flags:
              --label <text>         Label shown next to the progress bar
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 set-progress 0.5 --label "Building..."
              c11 set-progress 1.0 --label "Done"
            """
        case "clear-progress":
            return """
            Usage: c11 clear-progress [flags]

            Clear the sidebar progress bar for a workspace.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 clear-progress --workspace workspace:2
            """
        case "log":
            return """
            Usage: c11 log [flags] [--] <message>

            Append a log entry to the sidebar for a workspace.

            Flags:
              --level <level>        Log level: info, progress, success, warning, error (default: info)
              --source <name>        Source label (e.g. "build", "test")
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 log "Build started"
              c11 log --level error --source build "Compilation failed"
              c11 log --level success -- "All 42 tests passed"
            """
        case "clear-log":
            return """
            Usage: c11 clear-log [flags]

            Clear all sidebar log entries for a workspace.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 clear-log --workspace workspace:2
            """
        case "list-log":
            return """
            Usage: c11 list-log [flags]

            List sidebar log entries for a workspace.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --limit <n>            Show only the last N entries
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 list-log --workspace workspace:2
              c11 list-log --workspace workspace:2 --limit 5
            """
        case "sidebar-state":
            return """
            Usage: c11 sidebar-state [flags]

            Dump all sidebar metadata for a workspace (cwd, git branch, ports,
            status entries, progress, log entries). With --json, includes read-only
            window layout: double_wide, requested_width, effective_width, columns.
            A standalone --window is not a workspace target for sidebar commands.

            Flags:
              --workspace <id|ref>   Required outside c11; defaults to $C11_WORKSPACE_ID

            Example:
              c11 sidebar-state --workspace workspace:2
              c11 sidebar-state --json --workspace workspace:2
            """
        case "set-agent":
            return """
            Usage: c11 set-agent --type <terminal_type>
                                  [--model <id>] [--task <id>] [--role <id>]
                                  [--panel <id|ref>] [--workspace <id|ref>]
                                  [--json]

            Declare agent identity for a panel. Writes through
            panel.set_metadata with source=declare, mode=merge.

            Only flags present are written (omitting --model does not clear an
            existing declared model). --type is kebab-case, ≤ 32 chars.

            Flags:
              --type <terminal_type>   Canonical or custom kebab-case type (required)
              --model <id>             Agent model (e.g. claude-opus-4-7)
              --task <id>              Opaque task identifier
              --role <id>              Opaque role identifier
              --panel <id|ref>     Target panel (default: $C11_PANEL_ID / focused)
              --workspace <id|ref>     Target workspace (default: $C11_WORKSPACE_ID)
              --json                   Emit raw JSON-RPC result

            Examples:
              c11 set-agent --type claude-code --model claude-opus-4-7
              c11 set-agent --type opencode --task task-42 --panel panel:1
            """
        case "default-agent":
            return """
            Usage: c11 default-agent {get | set <type> | launch [flags]}

            Read or change the operator's configured default agent, or launch
            an agent panel programmatically. The launch path is the
            recommended way to spawn sub-agents: c11 owns per-TUI prompt
            delivery, so the same call works whether the operator's default is
            claude-code, codex, opencode, kimi, or a custom agent.

            Subcommands:
              get                              Print the configured default agent type.
              set <type>                       Set the default agent (claude-code | codex | kimi | opencode | github-copilot | custom).
              launch [flags]                   Launch the default (or --agent <type>) agent.

            launch flags:
              --in-panel <id|ref|index>    Launch into an existing panel's PTY. The
                                               orchestrator pattern: create a panel with
                                               `c11 new-split` or `c11 new-area`, then
                                               launch into it. A `panel:N` ref / index is
                                               resolved across every workspace (not just the
                                               focused one); pass --workspace to scope it.
              --workspace <id|ref|index>       Scope --in-panel ref/index resolution to a
                                               single workspace. Defaults to searching all
                                               workspaces (or C11_WORKSPACE_ID from the env).
              --area <uuid|index>              Legacy A-button mimic: create a NEW agent
                                               panel in the named area (focused area if
                                               omitted). Mutually exclusive with
                                               --in-panel.
              --agent <type>                   Override the configured default for this
                                               call only.
              --cwd <path>                     Resolved relative to where the CLI ran. With
                                               --in-panel: prepend `cd <path> && ` to the
                                               launch line. Without it: start the new agent
                                               panel there instead of the workspace root.
              --prompt <text>                  Initial prompt to deliver to the agent. For
                                               claude-code: appended as a positional arg.
                                               For other agents: typed in after a fixed
                                               post-launch delay.
              --prompt-file <path>             Like --prompt, but read the text from a file.
                                               Recommended for non-trivial prompts (no shell
                                               escaping needed).

            Examples:
              c11 default-agent get
              c11 default-agent set codex
              c11 default-agent launch --in-panel panel:5 --prompt-file /tmp/bootstrap.md
              c11 default-agent launch --area 0 --agent claude-code
            """
        case "set-metadata":
            return """
            Usage: c11 set-metadata [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>]
                                     (--json '{...}' | --key <K> --value <V> [--type string|number|bool|json])
                                     [--mode merge|replace] [--source explicit|declare|osc|heuristic]
                                     [--json]

            Set one or more metadata keys on a panel (panel.set_metadata) or
            area (area.set_metadata). Defaults: mode=merge, source=explicit.
            --panel and --area are mutually exclusive.

            Flags:
              --json '{...}'           Full JSON object of keys/values
              --key <K> --value <V>    Single-key write; use --type to coerce
              --type <string|number|bool|json>   Value coercion (default: string)
              --mode <merge|replace>   Merge (default) or full replace (source=explicit only)
              --source <src>           Write source (default: explicit)
              --panel <id|ref>     Target panel (default: $C11_PANEL_ID / focused)
              --area <id|ref>          Target area (routes to area.set_metadata)
              --workspace <id|ref>     Target workspace (default: $C11_WORKSPACE_ID)

            Examples:
              c11 set-metadata --key title --value "My Panel"
              c11 set-metadata --json '{"title":"x","role":"review"}'
              c11 set-metadata --key progress --value 0.5 --type number
              c11 set-metadata --area area:2 --key title --value "Area :: Child"
            """
        case "get-metadata":
            return """
            Usage: c11 get-metadata [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>]
                                     [--key <K> ...] [--sources] [--json]

            Read metadata (and optional per-key sidecar) for a panel
            (panel.get_metadata) or area (area.get_metadata). Repeat --key to
            filter. --panel and --area are mutually exclusive.

            Flags:
              --key <K>                Restrict to one key (repeatable)
              --sources                Include metadata_sources sidecar
              --panel <id|ref>     Target panel (default: $C11_PANEL_ID / focused)
              --area <id|ref>          Target area (routes to area.get_metadata)
              --workspace <id|ref>     Target workspace (default: $C11_WORKSPACE_ID)
              --json                   Emit raw JSON result

            Examples:
              c11 get-metadata
              c11 get-metadata --key terminal_type --sources
              c11 get-metadata --area area:2
            """
        case "clear-metadata":
            return """
            Usage: c11 clear-metadata [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>]
                                       [--key <K> ...] [--source explicit|declare|osc|heuristic]
                                       [--json]

            Clear keys from a panel (panel.clear_metadata) or area
            (area.clear_metadata). With no --key flags, clears the entire blob
            (requires source=explicit). --panel and --area are mutually exclusive.

            Flags:
              --key <K>                Key to clear (repeatable)
              --source <src>           Precedence source (default: explicit)
              --panel <id|ref>     Target panel (default: $C11_PANEL_ID / focused)
              --area <id|ref>          Target area (routes to area.clear_metadata)
              --workspace <id|ref>     Target workspace (default: $C11_WORKSPACE_ID)
              --json                   Emit raw JSON result

            Examples:
              c11 clear-metadata --key terminal_type
              c11 clear-metadata --panel panel:2
              c11 clear-metadata --area area:2 --key title
            """
        case "set-workspace-metadata":
            return """
            Usage: c11 set-workspace-metadata <key> <value> [flags]
                   c11 set-workspace-metadata --key <K> --value <V> [flags]
                   c11 set-workspace-metadata --json '{"description":"..."}' [flags]

            Write one or more operator-authored metadata keys on a workspace via
            workspace.set_metadata. Values are strings; canonical keys are
            "description" (≤2048 chars) and "icon" (≤32 chars). Custom keys
            must match [A-Za-z0-9_.-]+ and cap at 1024 chars each.

            Flags:
              --workspace <id|ref>     Required outside c11; defaults to $C11_WORKSPACE_ID
              --json '{...}'           Full JSON object of keys/values
              --json                   Emit raw JSON result

            Examples:
              c11 set-workspace-metadata description "Backend API refactor"
              c11 set-workspace-metadata icon 🦊
            """
        case "get-workspace-metadata":
            return """
            Usage: c11 get-workspace-metadata [<key>] [--workspace <id|ref>] [--json]

            Read workspace metadata via workspace.get_metadata. With a key, prints
            just that value. Without a key, prints all keys/values. The workspace is
            --workspace, or $C11_WORKSPACE_ID inside c11; never the selected workspace.

            Examples:
              c11 get-workspace-metadata
              c11 get-workspace-metadata description
            """
        case "clear-workspace-metadata":
            return """
            Usage: c11 clear-workspace-metadata [<key>] [--key <K> ...] [--workspace <id|ref>] [--json]

            Clear workspace metadata keys via workspace.clear_metadata. With no
            key, clears the entire workspace metadata dictionary. The workspace is
            --workspace, or $C11_WORKSPACE_ID inside c11; never the selected workspace.

            Examples:
              c11 clear-workspace-metadata description
              c11 clear-workspace-metadata
            """
        case "set-workspace-description":
            return """
            Usage: c11 set-workspace-description <text> [--workspace <id|ref>]

            Sugar for `c11 set-workspace-metadata description <text>`. The workspace
            is --workspace, or $C11_WORKSPACE_ID inside c11; never the selected workspace.
            """
        case "set-workspace-icon":
            return """
            Usage: c11 set-workspace-icon <glyph> [--workspace <id|ref>]

            Sugar for `c11 set-workspace-metadata icon <glyph>`. Supports emoji
            or the prefix "sf:" + SF Symbol name (e.g. "sf:star.fill"). The workspace
            is --workspace, or $C11_WORKSPACE_ID inside c11; never the selected workspace.
            """
        case "set-app-focus":
            return """
            Usage: c11 set-app-focus <active|inactive|clear>

            Override app focus state for notification routing tests.

            Example:
              c11 set-app-focus inactive
              c11 set-app-focus clear
            """
        case "simulate-app-active":
            return """
            Usage: c11 simulate-app-active

            Trigger the app-active handler used by notification focus tests.
            """
        case "conversation":
            return """
            Usage: c11 conversation <subcommand> [flags]

            Manage per-panel ConversationRefs (the C11-24 conversation
            store). Each panel hosts at most one active ConversationRef
            keyed by an opaque, per-kind id. The store survives c11
            restarts and is consulted at restore time to synthesise the
            resume command.

            Subcommands:
              claim --kind <k> [--cwd <path>] [--id <id>]
                Wrapper-claim: mint a placeholder ref. Idempotent and
                conservative for non-Codex kinds. A Codex plain/mismatched
                launch invalidates its prior exact lifecycle; matching
                --expected-resume-id preserves it.
              push --kind <k> --id <id> --source <hook|scrape|manual>
                   [--state <alive|suspended|tombstoned|unknown|ended>]
                   [--cwd <path>] [--reason <text>]
                   [--payload <json> | --payload @<path>]
                Hook or operator push of the real id. Generic push accepts
                only hook, scrape, or manual provenance.
                --payload accepts inline JSON or @<path> (mirrors HOOKS_FILE
                ergonomics in Resources/bin/claude).
              tombstone --kind <k> --id <id> [--reason <text>]
                Mark the panel's active ref as tombstoned. Operator-
                initiated; not auto-resumable.
              list [--panel <id>] [--json]
                List captured conversations. v1 stores process-wide;
                no workspace partitioning. Filter with --panel.
              get [--panel <id>] [--json]
                Read the active ref + can_resume + diagnostic_reason for
                the panel. Use this when debugging "why did this area
                resume that session?" — diagnostic_reason explains the
                strategy's decision.
              clear [--panel <id>]
                Wipe the panel's conversations. Forces a fresh launch
                on next workspace open.
              find [query] [-a] [--limit <n>] [--session <uuid>] [--open] [--json]
                Search local Claude Code and Codex transcripts by title,
                cwd, and prompts. -a also searches transcript text. It reads
                each file in chunks, at most 1 MiB, skips files larger than
                8 MiB, and prints progress on stderr. A listing stops at
                --limit matches. --open stops at two, so a second match
                still refuses. --open focuses the one live match inside its
                own workspace and does not change which workspace is selected.
                A live row prints the panel's c11:// link. An idle match
                resumes into a new panel in the caller's workspace.
                Listing works when c11 is not running.

            Panel resolution: --panel flag, else $C11_PANEL_ID env
            var. There is NO focused-panel fallback (the silent-misroute
            footgun the architecture exists to avoid).
            """
        case "claude-hook":
            return """
            Usage: c11 claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit|stop-failure|permission-request|subagent-start|subagent-stop|pre-compact> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start      Signal that a Claude session has started
              active             Alias for session-start
              stop               Signal that a Claude session has stopped
              idle               Alias for stop
              notification       Forward a Claude notification
              notify             Alias for notification
              prompt-submit      Clear notification and set Running on user prompt
              stop-failure       Record a StopFailure observation
              permission-request Record a non-ask permission observation and print {}
              subagent-start     Record a child spawn
              subagent-stop      Record a child completion
              pre-compact        Record a compaction observation

            Flags:
              --workspace <id|ref>   Target workspace (default: $C11_WORKSPACE_ID)
              --panel <id|ref>   Target panel (default: $C11_PANEL_ID)

            Example:
              echo '{"session_id":"abc"}' | c11 claude-hook session-start
              echo '{}' | c11 claude-hook stop
            """
        case "browser":
            return """
            Usage: c11 browser [--panel <id|ref|index> | <panel>] <subcommand> [args]

            Browser automation commands. Most subcommands require a panel handle.
            A panel can be passed as `--panel <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit panel.

            Subcommands:
              open|open-split|new [url] [--area <id|ref>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--profile <name|id>] [--allow-insecure-http]
                open/open-split/new place by anchor, never by focus (the three names are aliases)
                without --panel/--area, anchor on $C11_PANEL_ID in $C11_WORKSPACE_ID
                first open splits beside the anchor when space permits; later opens join its browser area
                cross-workspace opens add to an existing area without splitting
                --area adds a panel there without splitting; --panel anchors beside a terminal
                open with an explicit browser panel navigates it in place; use new to create another
                --profile selects one browser profile for this creation only
              profiles list
              profiles add <name>
              profiles rename <profile> <name>
              profiles clear <profile> --yes
              profiles delete <profile> --yes
                clear/delete never prompt; they refuse without --yes and refuse built-in or in-use profiles
              goto|navigate <url> [--snapshot-after] [--allow-insecure-http]
                --allow-insecure-http consents to one plain-http navigation to that host without
                prompting a human (loopback hosts are already allowed by default)
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              keep-live [on|off|status]
                keep a page running (visible, timers and media live) while its workspace is hidden
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--all]
              storage <local|session> <get|set|clear> [...]
              panel <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              viewport <width> <height>
              geolocation|geo <latitude> <longitude>
              offline <true|false>
              trace <start|stop> [path]
              network <route|unroute|requests> ...
                route <pattern> [--abort] [--body <text>]
                unroute <pattern>
              screencast <start|stop>
              input <mouse|keyboard|touch> [args...]
              input_mouse | input_keyboard | input_touch
              identify [--panel <id|ref|index>]

            Example:
              c11 browser open https://example.com
              c11 browser panel:1 navigate https://google.com
              c11 browser --panel panel:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `c11 browser --help`
        case "open-browser":
            return "Legacy alias for 'c11 browser open'. Run 'c11 browser --help' for details."
        case "navigate":
            return "Legacy alias for 'c11 browser navigate'. Run 'c11 browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'c11 browser back'. Run 'c11 browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'c11 browser forward'. Run 'c11 browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'c11 browser reload'. Run 'c11 browser --help' for details."
        case "get-url":
            return "Legacy alias for 'c11 browser get-url'. Run 'c11 browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'c11 browser focus-webview'. Run 'c11 browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'c11 browser is-webview-focused'. Run 'c11 browser --help' for details."
        case "markdown":
            return """
            Usage: c11 markdown open <path>[#fragment] [options]
                   c11 markdown <path>       (shorthand for 'open')

            Open a markdown file in a formatted viewer panel with live file watching.
            The file is rendered with rich formatting (headings, code blocks, tables,
            lists, blockquotes) and automatically updates when the file changes on disk.

            Options:
              --panel <id|ref>             A markdown panel navigates in place. A terminal or
                                           browser panel is the anchor to place the doc beside.
                                           Not combinable with --workspace, --window, or --area.
              --area <id|ref>              Add the doc as a panel in this area (no split)
              --workspace <id|ref|index>   Target workspace (default: $C11_WORKSPACE_ID)
              --window <id|ref|index>      Target window

            Placement without --area:
              The doc goes beside its anchor: --panel, else the calling panel
              ($C11_PANEL_ID) when it is in the target workspace. The first doc splits the
              anchor's area (size-aware); later docs join the markdown area that first doc
              made. With no anchor in the target workspace (a cross-workspace
              --workspace open, or a shell outside c11), the doc becomes a panel in an
              existing markdown area, else the focused area. It never splits the focused
              panel. Pass --panel "$C11_PANEL_ID" or --area to choose explicitly.

            Examples:
              c11 markdown open plan.md
              c11 markdown ~/project/CHANGELOG.md
              c11 markdown open plan.md --panel "$C11_PANEL_ID"
              c11 markdown open ./docs/design.md --workspace workspace:2

            Navigating a markdown reader with --panel does not switch the visible
            workspace or change c11 focus. The panel validates navigation targets
            and keeps bounded back/forward history.

            Reader commands require an explicit --panel <markdown panel>:
              c11 markdown open <path>[#fragment] --panel <id|ref>
              c11 markdown scroll --panel <id|ref> --heading <text>
              c11 markdown visible --panel <id|ref> --json [--watch]
              c11 markdown theme --panel <id|ref> (--list | --set <name>)
              c11 markdown typeface --panel <id|ref> (--list | --set <name>)
              c11 markdown font --panel <id|ref> --scale <0.5..3.0>
              c11 markdown open-external --panel <id|ref>
              c11 markdown history --panel <id|ref> --json
              c11 markdown links --panel <id|ref> --broken --json
              c11 markdown backlinks --panel <id|ref> --json

            visible --watch emits newline-delimited JSON until the panel closes
            or the client disconnects.
            history reports the panel's back/forward entries and saved reading positions.
            links --broken reports relative Markdown targets or heading fragments that fail validation.
            backlinks reports Markdown documents that link to the current document in its corpus.
            Same-document anchors stay in the page and participate in history. ⌘[ and ⌘]
            navigate back and forward; the toolbar arrows do the same.
            """
        case "snapshot":
            return """
            Usage: c11 snapshot [--workspace <ref>] [--out <path>] [--all] [--json]

            Capture the current workspace (or a named one) to
            `~/.c11-snapshots/<ulid>.json`. No args → current workspace
            (resolved from $C11_WORKSPACE_ID).

            Flags:
              --workspace <ref>   Workspace to capture (ref or UUID)
              --out <path>        Override the default output path
              --all               Capture every open workspace in one pass.
                                  Writes one per-workspace file AND a
                                  manifest at
                                  `~/.c11-snapshots/sets/<set-ulid>.json`
                                  that lists them. Pass the set ulid back
                                  to `c11 restore` to rehydrate them all.
              --json              Emit raw snapshot.create result as JSON

            Note: --all and --workspace / --out are mutually exclusive.

            Examples:
              c11 snapshot
              c11 snapshot --workspace workspace:2 --out ~/snapshots/phase1.json
              c11 snapshot --all
            """
        case "restore":
            let inPlaceHelp = String(
                localized: "cli.restore.usage.inPlace",
                defaultValue:
                    "--in-place, --replace   Replace the current workspace's content instead of creating a new workspace"
            )
            let inPlaceNote = String(
                localized: "cli.restore.usage.inPlace.note",
                defaultValue:
                    "Running `c11 restore <id>` twice creates two workspaces unless --in-place is passed."
            )
            return """
            Usage: c11 restore <snapshot-or-set-id-or-path> [--in-place] [--json]

            Restore a workspace layout from a snapshot written by `c11 snapshot`.
            The argument is either a ULID (resolved under `~/.c11-snapshots/`,
            the legacy `~/.cmux-snapshots/`, or — for set manifests written by
            `c11 snapshot --all` — `~/.c11-snapshots/sets/`), or an absolute
            path to a `.json` snapshot or set-manifest file. Set manifests
            rehydrate every workspace they reference; `--in-place` is rejected
            for sets.

            \(inPlaceNote)

            When $C11_SESSION_RESUME is set to a
            truthy value, Claude Code terminals resume their prior session via
            `cc --resume <session-id>`. Unset the env var to restore the layout
            with fresh shells instead.

            Per the socket focus policy (see CLAUDE.md), restore does not
            foreground the restored workspace; select it manually with
            `c11 workspace select <ref>` if needed.

            Flags:
              \(inPlaceHelp)
              --json                  Emit raw snapshot.restore result as JSON

            Examples:
              c11 restore 01KQ0XYZ…
              c11 restore --in-place 01KQ0XYZ…
              C11_SESSION_RESUME=1 c11 restore ~/snapshots/phase1.json
            """
        case "list-snapshots":
            return """
            Usage: c11 list-snapshots [--json] [--sets|--all]

            List snapshots under `~/.c11-snapshots/` merged with the legacy
            `~/.cmux-snapshots/` path. Newest first.

            Columns: SNAPSHOT_ID, CREATED_AT, WORKSPACE_TITLE, PANELS, ORIGIN, SOURCE.
            SOURCE is `current` for `~/.c11-snapshots/`, `legacy` for the fallback.

            Flags:
              --json    Emit raw snapshot.list result as JSON.
              --sets    List snapshot-set manifests under `~/.c11-snapshots/sets/`
                        (written by `c11 snapshot --all`) instead of per-workspace
                        snapshots. Columns: SET_ID, CREATED_AT, COUNT, C11_VERSION.
              --all     Print both tables back-to-back (per-workspace, then sets).

            Examples:
              c11 list-snapshots
              c11 list-snapshots --json
              c11 list-snapshots --sets
              c11 list-snapshots --all
            """
        case "workspace":
            // CMUX-37: two-level dispatch. Without a subcommand, list the
            // three known workspace subcommands. With one, return its
            // per-subcommand help text.
            let sub = commandArgs.first(where: { !$0.hasPrefix("-") })
            switch sub {
            case "apply":
                return """
                Usage: c11 workspace apply --file <path|->

                Apply a `WorkspaceApplyPlan` JSON document. Materializes the
                plan into a fresh workspace via `workspace.apply` v2.

                Flags:
                  --file <path|->   Plan source. `-` reads from stdin.

                Example:
                  c11 workspace apply --file ./plan.json
                  cat ./plan.json | c11 workspace apply --file -
                """
            case "new":
                return """
                Usage: c11 workspace new [--blueprint <path>]
                       c11 workspace new --dir <path-or-query> [--layout <id|name>] [--name <text>] [--agent]

                Create a new workspace from a blueprint. Without `--blueprint`,
                drops into an interactive picker that lists the built-in
                blueprints plus any discovered under
                `~/.config/c11/blueprints/`, `<repo>/.c11/blueprints/`, and
                their legacy `cmux` siblings. Both `.md` (operator-edited
                markdown) and `.json` blueprint files are accepted.

                With `--dir`, create a workspace rooted at a directory the way the
                New Workspace picker does. The value is a path (`~`, `/`, `./`) or a
                fuzzy query over your recents, ranked exactly like the picker's
                search; a real subdirectory of the current directory with that name wins
                over a fuzzy match. If the top two recents tie, the command fails and lists the
                candidates. The open is recorded in recents. The directory must
                exist.

                Flags:
                  --blueprint <path>   Apply the blueprint at the given path
                                       directly, skipping the picker.
                  --dir <path|query>   Root the workspace here (path or fuzzy recents query).
                  --layout <id|name>   With --dir: starter (quad, two-columns, two-by-three,
                                       one-column, or starter:<name>), saved:<url>, or a
                                       blueprint name. Default: the picker's last layout.
                  --name <text>        With --dir: workspace title (default: directory name).
                  --agent              With --dir: launch the default coding agent in the
                                       first area (the picker's checkbox; off by default here).

                Examples:
                  c11 workspace new
                  c11 workspace new --blueprint ~/.config/c11/blueprints/agent-room.md
                  c11 workspace new --dir ace --layout quad
                  c11 workspace new --dir ~/Projects/site --name "Site"
                """
            case "recents":
                return """
                Usage: c11 workspace recents list [--pinned] [--json]
                       c11 workspace recents pin <path-or-query> [--at <n>]
                       c11 workspace recents unpin <path-or-query>
                       c11 workspace recents remove <path-or-query>

                Read and edit the New Workspace picker's recent directories and
                pins. An open picker updates live. `<path-or-query>` is a path or
                a fuzzy query over recents (ties fail and list the candidates).

                `list` prints, per directory: path, lastOpenedAt, openCount, whether
                it is pinned, its pin number, whether a workspace for it is open in
                c11, and whether the directory still exists. `--pinned` lists pins in
                pin order. `pin --at <n>` places the pin at number n (the number on
                its tile); `remove` also drops the pin.

                Examples:
                  c11 workspace recents list --json
                  c11 workspace recents pin ~/Projects/site --at 1
                  c11 workspace recents remove old-client
                """
            case "export-blueprint":
                return """
                Usage: c11 workspace export-blueprint --name <name>
                                                      [--workspace <id|ref|index>]
                                                      [--description <text>]
                                                      [--format md|json]
                                                      [--out <path>]
                                                      [--force]

                Capture the current (or named) workspace as a
                `WorkspaceBlueprintFile` and write it to disk. Default
                destination is `~/.config/c11/blueprints/<name>.md`. Pass
                `--format json` for the legacy JSON envelope.

                Flags:
                  --name <name>            Required. Blueprint name (also the file stem).
                  --workspace <ref>        Source workspace. Defaults to the caller's workspace.
                  --description <text>     Optional description embedded in the blueprint envelope.
                  --format md|json         Output format. Default: md.
                  --out <path>             Move the written file to this path.
                  --force                  Overwrite an existing blueprint with the same name.

                Examples:
                  c11 workspace export-blueprint --name agent-room
                  c11 workspace export-blueprint --name agent-room --format json --workspace workspace:1 --force
                """
            case nil:
                return """
                Usage: c11 workspace <subcommand> [options]

                Workspace persistence and blueprint commands.

                Subcommands:
                  apply              Apply a WorkspaceApplyPlan JSON document.
                  new                Create a workspace from a blueprint (interactive or by path).
                  export-blueprint   Capture a workspace as a reusable blueprint file.
                  recents            List, pin, unpin and remove New Workspace recents.

                Run `c11 workspace <subcommand> --help` for per-subcommand flags.
                """
            default:
                return """
                Usage: c11 workspace <subcommand> [options]

                Unknown workspace subcommand: '\(sub ?? "")'.
                Known subcommands: apply, new, export-blueprint.
                Run `c11 workspace --help` for the full list.
                """
            }
        case "workspace-apply":
            return """
            Usage: c11 workspace-apply --file <path|->

            Compatibility alias for `c11 workspace apply`. Apply a
            WorkspaceApplyPlan JSON document; `-` reads from stdin.
            """
        case "markdown-content":
            return """
            Usage: c11 markdown-content [--panel <id|ref>] [--json]

            Read the content of the caller's markdown panel, or the panel named by
            --panel. The workspace and caller panel default to C11_WORKSPACE_ID and
            C11_PANEL_ID.
            """
        case "ui":
            return """
            Usage: c11 ui themes <subcommand> [options]

            Manage the legacy UI theme command surface. Use `c11 themes --help`
            for the full c11 theme command reference.
            """
        case "workspace-color":
            return """
            Usage: c11 workspace-color <set|clear|get|list-palette> [options]

            Read or change the workspace frame color: a palette name (red, teal,
            navy, …; `c11 workspace-color list-palette` lists them) or #RRGGBB.
            """
        case "panel-color", "tab-color":
            return """
            Usage: c11 panel-color <set|clear|get|list-palette> [options]

            Read or change a panel's color (#RRGGBB or a palette name). The same
            color as `c11 set-panel-color` and panel metadata `color`.
            """
        case "state":
            return stateUsage()
        case "app":
            return appUsage()
        case "agent-hook", "codex-hook":
            return """
            Usage: c11 agent-hook <working|idle>
                   c11 codex-hook <working|idle>

            Report the lifecycle state of the calling agent panel.
            `codex-hook` is a compatibility alias.
            """
        case "skill":
            return skillCommandUsage()
        case "model-costs":
            return ModelCostsCommandCore.usage
        default:
            return nil
        }
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    /// Mailbox text is never help. `send` value flags and a bare `--` mark
    /// the following token as a body. `recv` value flags are the same class:
    /// a recipient or event name is not a help request. Other mailbox
    /// subcommands still stop at `--`, and a real `--help` / `-h` before
    /// that delimiter still prints help.
    static func mailboxHelpScan(
        command: String,
        commandArgs: [String]
    ) -> (valueOptions: Set<String>, stopAtEndOfOptions: Bool) {
        guard command == "mailbox" else { return ([], false) }
        switch commandArgs.first(where: { !$0.hasPrefix("-") }) {
        case "send":
            return (MailboxSendArguments.valueFlags, true)
        case "recv":
            return (MailboxRecvArguments.valueFlags, true)
        default:
            return ([], true)
        }
    }

    func dispatchSubcommandHelp(
        command: String,
        commandArgs: [String],
        valueOptions: Set<String> = [],
        stopAtEndOfOptions: Bool = false
    ) -> Bool {
        guard CLIHelpFlagScanner.containsHelpFlag(
            in: commandArgs,
            valueOptions: valueOptions,
            stopAtEndOfOptions: stopAtEndOfOptions
        ) else { return false }
        guard let text = subcommandUsage(command, commandArgs: commandArgs) else { return false }
        // For two-level commands (e.g. `c11 workspace new --help`) include the
        // resolved subcommand in the header so the operator can tell which
        // help block they got back.
        let subToken = commandArgs.first(where: { !$0.hasPrefix("-") })
        if let subToken {
            print("c11 \(command) \(subToken)")
        } else {
            print("c11 \(command)")
        }
        print("")
        print(text)
        return true
    }
}
