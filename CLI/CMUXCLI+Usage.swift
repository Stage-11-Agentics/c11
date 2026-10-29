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

    func usage() -> String {
        return """
        c11 - control c11 via Unix socket

        Usage:
          c11 <path>                 Open a directory in a new workspace (launches c11 if needed)
          c11 [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs, short refs (window:1/workspace:2/area:3/panel:4), or indexes where commands accept window, workspace, area, or panel inputs.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Path:
          Resolution precedence: --socket flag → C11_SOCKET → CMUX_SOCKET_PATH → CMUX_SOCKET → auto-discovery.
          When auto-discovery picks a non-default socket, c11 prints one stderr line attributing the source.
          Suppress that line with C11_QUIET_DISCOVERY=1.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
          welcome
          shortcuts [list|set|reset]                                  keyboard shortcuts (live)
          feedback [--email <email> --body <text> [--image <path> ...]]
          themes [list|get|set|clear|reload|path|dump|validate|diff]  c11 chrome themes
          terminal-theme [list|set|clear]                             Ghostty terminal themes
          claude-teams [claude-args...]
          ping
          version
          guide [page] [--json]       Print this build's bundled skill (alias: --skill)
          capabilities
          rpc <method> [json] [--json]
          brand [--json]
          history [list] [--json] [--limit <1...200>]
          history back [--json]
          history forward [--json]
          agents [--json] [--bundle-id <id>]
          identify [--workspace <id|ref|index>] [--panel <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          resize-window --window <id> <width|-> <height|->
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-group <verb> [--window <id|ref>] [--json]   (folders; see --help)
          reorder-workspaces --order <comma-separated-handles> [--window <id|ref>] [--dry-run] [--json]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>]
          list-workspaces [--json]
          new-workspace [--cwd <path>] [--root <path>] [--command <text>]
          workspace                                        (workspace persistence subcommands)
          workspace apply --file <path|->                  (apply a WorkspaceApplyPlan JSON)
          workspace new [--blueprint <path>]               (create from a blueprint, interactive picker without --blueprint)
          workspace export-blueprint --name <name> [--workspace <ref>] [--description <text>] [--out <path>] [--force]
          ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [--ssh-option <opt>] [-- <remote-command-args>]
          remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
          new-split <left|right|up|down> [--command <text>] [--workspace <id|ref>] [--panel <id|ref>] [--title <text>]
          list-areas [--workspace <id|ref>]
          list-area-panels [--workspace <id|ref>] [--area <id|ref>]
          family [--panel <id|ref>] [--json]
          tree [--all] [--workspace <id|ref|index>]
          focus-area --area <id|ref> [--workspace <id|ref>]
          new-area [--type <terminal|browser|markdown>] [--command <text>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>] [--file <path>] [--title <text>]
          new-panel [--type <terminal|browser|markdown>] [--command <text>] [--area <id|ref>] [--workspace <id|ref>] [--url <url>] [--file <path>] [--cwd <path|inherit>]
          close-panel [--panel <id|ref>] [--workspace <id|ref>]
          move-panel --panel <id|ref|index> [--area <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          reorder-panel --panel <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>)
          panel-action --action <name> [--panel <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--url <url>]
          rename-panel [--workspace <id|ref>] [--panel <id|ref>] <title>
          set-title [--workspace <id|ref>] [--panel <id|ref>] [--source <src>] <title>
          set-description [--workspace <id|ref>] [--panel <id|ref>] [--source <src>] [--auto-expand=false] <text>
          set-panel-icon [--workspace <id|ref>] [--panel <id|ref>] (<icon> | --clear)
          set-panel-color [--workspace <id|ref>] [--panel <id|ref>] (<#RRGGBB|palette-name> | --clear)
          get-titlebar-state [--workspace <id|ref>] [--panel <id|ref>] [--json]
          drag-panel-to-split --panel <id|ref|index> [--workspace <id|ref|index>] <left|right|up|down>
          refresh-panels [--workspace <id|ref|index>]
          panel-health [--workspace <id|ref>]
          health [--since <duration> | --since-boot] [--rail <name>] [--json]
          doctor [--json]
          trigger-flash [--workspace <id|ref>] [--panel <id|ref>] [--color <#hex>] [--persistent]
          cancel-flash [--workspace <id|ref>] [--panel <id|ref>]
          list-panels [--workspace <id|ref>]
          focus-panel --panel <id|ref> [--workspace <id|ref>]
          close-workspace --workspace <id|ref>
          select-workspace --workspace <id|ref>
          rename-workspace [--workspace <id|ref>] <title>
          set-workspace-root [--workspace <id|ref>] (<path> | --clear)
          get-workspace-root [--workspace <id|ref>] [--json]
          rename-window [--workspace <id|ref>] <title>
          current-workspace
          read-selection [--workspace <id|ref>] [--panel <id|ref>]
          input-state --panel <id|ref> [--workspace <id|ref>] [--json]
          read-screen [--workspace <id|ref>] [--panel <id|ref>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref>] [--panel <id|ref>] [--raw] [--no-submit] [--allow-unguarded] <text | ->
          paste [--workspace <id|ref>] [--panel <id|ref>] [--no-submit] [--allow-unguarded] [text | -]
          send-key [--workspace <id|ref>] [--panel <id|ref>] <key>
          send-panel --panel <id|ref> [--workspace <id|ref>] [--raw] [--no-submit] [--allow-unguarded] <text | ->
          send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--panel <id|ref>]
          area-confirm --panel <id|ref> --title <text> [--message <text>] [--destructive] [--timeout <seconds>] [--confirm-label <text>] [--cancel-label <text>]
          list-notifications
          feed list [--json] [--scope attention|all]
          feed open <panel> [--workspace <id|ref>] [--json]
          feed answer <panel> --text <text> [--workspace <id|ref>] [--by agent|operator] [--json]
          feed answer supports single-line text only in c11 1.0; use feed open for multiline answers
          feed watch [--json] [--scope attention|all]
          clear-notifications
          agent-event append --stdin
          claude-hook <session-start|stop|notification|stop-failure|permission-request|subagent-start|subagent-stop|pre-compact> [--workspace <id|ref>] [--panel <id|ref>]
          set-agent --type <terminal_type> [--model <id>] [--task <id>] [--role <id>] [--panel <id|ref>] [--workspace <id|ref>]
          default-agent {get | set <type> | launch [--in-panel <id|ref> | --area <id>] [--agent <type>] [--cwd <path>] [--prompt <text> | --prompt-file <path>]}
          launch-agent --type <kind> [--model <id>] [--effort <tier>] [--system-prompt-mode inherit|append|replace] [--system-prompt <text> | --system-prompt-file <path>] [--task <id>] [--area <id|ref> | --workspace <id|ref> | --new-workspace] [--cwd <path>] [--prompt <text> | --prompt-file <path>] [--title <text>] [--flag <reason>] [--delegated] [--env K=V ...] [--json]
          model-costs {list [--json] | get <model> [--json] | set <model> --in <usd> --out <usd> [--cache-read <usd>] [--cache-write <usd>] [--cache-write-1h <usd>] [--source <url>] [--notes <text>] | rm <model> | import <path|-> [--replace]}
          raise-flag --panel <id|ref> "<reason>"
          lower-flag --panel <id|ref>
          delegate --panel <id|ref>
          undelegate --panel <id|ref>
          set-metadata (--json '{...}' | --key <K> --value <V> [--type string|number|bool|json]) [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>] [--mode merge|replace] [--source <src>]
          get-metadata [--key <K> ...] [--sources] [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>]
          clear-metadata [--key <K> ...] [--source <src>] [--panel <id|ref> | --area <id|ref>] [--workspace <id|ref>]
          set-workspace-metadata <key> <value> | --key <K> --value <V> | --json '{...}'  [--workspace <id|ref>]
          get-workspace-metadata [<key>] [--workspace <id|ref>]
          clear-workspace-metadata [<key>] [--key <K> ...] [--workspace <id|ref>]
          set-workspace-description <text> [--workspace <id|ref>]
          set-workspace-icon <glyph> [--workspace <id|ref>]
          set-app-focus <active|inactive|clear>
          simulate-app-active

          # tmux compatibility commands
          capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]
          pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]
          wait-for [-S|--signal] <name> [--timeout <seconds>]
          swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]
          break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>]
          join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>]
          next-window | previous-window | last-window
          last-pane [--workspace <id|ref>]
          find-window [--content] [--select] <query>
          clear-history [--workspace <id|ref>] [--surface <id|ref>]
          set-hook [--list] [--unset <event>] | <event> <command>
          popup
          bind-key | unbind-key | copy-mode
          set-buffer [--name <name>] <text>
          list-buffers
          paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]
          respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]
          display-message [-p|--print] <text>

          markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)

          messages view                         (open the live local agent-messages page)
          mailbox [send|recv|trace|tail|view]    (durable inter-agent messaging)

          browser [--panel <id|ref|index> | <panel>] <subcommand> ...
          browser open [url] [--allow-insecure-http]   (place beside caller; explicit browser panel navigates in place)
          browser open-split [url] [--allow-insecure-http]
          browser goto|navigate <url> [--snapshot-after] [--allow-insecure-http]
          browser back|forward|reload [--snapshot-after]
          browser url|get-url
          browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
          browser eval <script>
          browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]
          browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]
          browser type <selector> <text> [--snapshot-after]
          browser fill <selector> [text] [--snapshot-after]   (empty text clears input)
          browser press|keydown|keyup <key> [--snapshot-after]
          browser select <selector> <value> [--snapshot-after]
          browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
          browser screenshot [--out <path>] [--json]
          browser get <url|title|text|html|value|attr|count|box|styles> [...]
          browser is <visible|enabled|checked> <selector>
          browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...
          browser frame <selector|main>
          browser dialog <accept|dismiss> [text]
          browser download [wait] [--path <path>] [--timeout-ms <ms>]
          browser cookies <get|set|clear> [...]
          browser storage <local|session> <get|set|clear> [...]
          browser <ref> panel <new|list|switch|close|<index>> [...]
          browser console <list|clear>
          browser errors <list|clear>
          browser highlight <selector>
          browser state <save|load> <path>
          browser addinitscript <script>
          browser addscript <script>
          browser addstyle <css>
          browser identify [--panel <id|ref|index>]
          usage [--since <date|duration|all>] [--until <date>] [--by panel|workspace|model|harness] [--json] (default: 30d)
          report [--instance <id>|--all-instances] [--since <date|duration|all>] [--until <date>] [--utc] [--format md|json]
          events tail [--follow|-f] [--filter type=<type>] [--since <seq|duration>] [--instance <id>]
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in c11 terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          C11_PANEL_ID        Auto-set in c11 terminals. Used as default --panel.
          C11_PANEL_NUM       Auto-set in c11 terminals. The panel's number within its workspace.
          C11_SOCKET          Override the Unix socket path (preferred). Takes precedence over
                              CMUX_SOCKET_PATH and CMUX_SOCKET.
          CMUX_SOCKET_PATH    Legacy alias for C11_SOCKET. Still accepted; loses to C11_SOCKET when both set.
          CMUX_SOCKET         Older alias for the same. Loses to both above.
          C11_QUIET_DISCOVERY Set to 1 to suppress the stderr line c11 prints when auto-discovering a non-default socket.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }

    static func debugFailureSeverityForTesting(code: String, message: String) -> FailureSeverity {
        failureSeverity(code: code, message: message)
    }

    static func debugPartitionFailuresForTesting(
        _ failures: [[String: Any]]
    ) -> (failures: [[String: Any]], info: [[String: Any]]) {
        partitionFailures(failures)
    }
#endif
}
