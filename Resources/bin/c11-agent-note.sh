#!/usr/bin/env bash
# Sourced by the agent wrappers beside it (claude, codex, grok, pi, omp, opencode); never run.
#
# C11H-35: an agent in c11 can read a newer c11 skill from its own harness folder and try
# commands this build lacks. Each wrapper passes the short note in c11-agent-note.txt (plus
# this build's version) by that harness's own launch flag. It writes no file, never edits a
# harness config, and never overrides a flag the operator passed. Anything missing or
# unreadable means no note and an unchanged launch.

# c11_has_flag FLAG ARGS...: the operator passed FLAG (or FLAG=value) before any `--`.
c11_has_flag() {
    local flag="$1" arg
    shift
    for arg in "$@"; do
        [[ "$arg" == "--" ]] && return 1
        [[ "$arg" == "$flag" || "$arg" == "$flag="* ]] && return 0
    done
    return 1
}

# A TOML file assigns developer_instructions (bare or quoted key, any table: over-skipping is safe).
c11_toml_sets_developer_instructions() {
    [[ -r "$1" ]] && /usr/bin/grep -Eq "^[[:space:]]*[\"']?developer_instructions[\"']?[[:space:]]*=" "$1" 2>/dev/null
}

# Some layer Codex would let a `-c` override already sets developer_instructions: the
# operator's flag, their user config, a --profile file, a project .codex/config.toml (this
# directory and every ancestor), or the system config. A `-c` would replace that value, so
# the note is skipped. Trust is Codex's business: skipping on an untrusted file only omits
# the note. Read only.
c11_codex_sets_developer_instructions() {
    local prev="" arg profile="" dir home_codex
    for arg in "$@"; do
        [[ "$arg" == "--" ]] && break
        case "$prev" in
            -c|--config) [[ "$arg" == developer_instructions* ]] && return 0 ;;
            -p|--profile) profile="$arg" ;;
        esac
        case "$arg" in
            -cdeveloper_instructions*|--config=developer_instructions*) return 0 ;;
            --profile=*) profile="${arg#--profile=}" ;;
            -p?*) profile="${arg#-p}"; profile="${profile#=}" ;;
        esac
        prev="$arg"
    done
    home_codex="${CODEX_HOME:-$HOME/.codex}"
    c11_toml_sets_developer_instructions "$home_codex/config.toml" && return 0
    if [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]]; then
        c11_toml_sets_developer_instructions "$home_codex/$profile.config.toml" && return 0
    fi
    c11_toml_sets_developer_instructions "/etc/codex/config.toml" && return 0
    dir="$PWD"
    while :; do
        c11_toml_sets_developer_instructions "$dir/.codex/config.toml" && return 0
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="$(/usr/bin/dirname "$dir")"
    done
    return 1
}

# pi and omp discover an APPEND_SYSTEM.md themselves only when no --append-system-prompt is
# passed (omp's flag is one string, and a path as its value skips pi's trust check). If one
# exists where the harness would find it, pass nothing and let it load.
c11_pi_has_append_system_file() {
    [[ -e "$PWD/.pi/APPEND_SYSTEM.md" || -e "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/APPEND_SYSTEM.md" ]]
}

c11_omp_has_append_system_file() {
    local base
    for base in "$HOME/.omp/agent" "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini" \
                "$PWD/.omp" "$PWD/.claude" "$PWD/.codex" "$PWD/.gemini"; do
        [[ -e "$base/APPEND_SYSTEM.md" ]] && return 0
    done
    return 1
}

# c11_agent_note DIR: the note with this build's version in front, or nothing.
c11_agent_note() {
    local dir="$1" body version
    body="$(/bin/cat "$dir/c11-agent-note.txt" 2>/dev/null)" || return 1
    [[ -n "$body" ]] || return 1
    # The plain c11 version (CFBundleShortVersionString); C11Version only if a build sets one.
    version="$(/usr/bin/plutil -extract C11Version raw -o - "$dir/../../Info.plist" 2>/dev/null)" || version=""
    [[ -n "$version" && "$version" != *'$('* ]] \
        || version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$dir/../../Info.plist" 2>/dev/null)" \
        || version=""
    # Linux has no plutil (a relay kit on a Linux machine, C11H-191): read the XML plist's C11Version string directly.
    if [[ -z "$version" && -r "$dir/../../Info.plist" ]]; then
        version="$(/usr/bin/sed -n '/<key>C11Version<\/key>/{n;s/.*<string>\([A-Za-z0-9._-]*\)<\/string>.*/\1/p;}' "$dir/../../Info.plist" 2>/dev/null | head -1)"
        [[ -n "$version" ]] || version="$(/usr/bin/sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\([A-Za-z0-9._-]*\)<\/string>.*/\1/p;}' "$dir/../../Info.plist" 2>/dev/null | head -1)"
    fi
    [[ -n "$version" ]] || version="(version unknown)"
    printf 'c11 %s. %s' "$version" "$body"
}

# c11_note_args HARNESS DIR OPERATOR_ARGS...: sets the C11_NOTE_ARGS array to the
# launch flags that carry the note; empty when none applies.
c11_note_args() {
    local harness="$1" dir="$2" note value
    shift 2
    C11_NOTE_ARGS=()
    [[ "${C11_AGENT_NOTE_DISABLED:-${C11H_AGENT_NOTE_DISABLED:-}}" == "1" ]] && return 0 # c11-2.0:legacy fallback
    case "$harness" in
        claude)
            if c11_has_flag --append-system-prompt "$@" || c11_has_flag --append-system-prompt-file "$@"; then
                return 0
            fi
            note="$(c11_agent_note "$dir")" || return 0
            C11_NOTE_ARGS=(--append-system-prompt "$note")
            ;;
        codex)
            if c11_codex_sets_developer_instructions "$@"; then
                return 0
            fi
            note="$(c11_agent_note "$dir")" || return 0
            value="${note//\\/\\\\}"
            value="${value//\"/\\\"}"
            C11_NOTE_ARGS=(-c "developer_instructions=\"$value\"")
            ;;
        grok)
            if c11_has_flag --rules "$@"; then
                return 0
            fi
            note="$(c11_agent_note "$dir")" || return 0
            C11_NOTE_ARGS=(--rules "$note")
            ;;
        pi|omp)
            if "c11_${harness}_has_append_system_file"; then
                return 0
            fi
            # The flag may repeat; ours goes first so the operator's own always comes later.
            note="$(c11_agent_note "$dir")" || return 0
            C11_NOTE_ARGS=(--append-system-prompt "$note")
            ;;
    esac
    return 0
}

# OpenCode takes instruction files, not text: the bundled note file itself (no version
# line; the note says `c11 guide` prints it). Prints the JSON member or nothing.
c11_opencode_instructions_json() {
    local dir="$1" file
    [[ "${C11_AGENT_NOTE_DISABLED:-${C11H_AGENT_NOTE_DISABLED:-}}" == "1" ]] && return 0 # c11-2.0:legacy fallback
    file="$dir/c11-agent-note.txt"
    [[ -r "$file" ]] || return 0
    file="${file//\\/\\\\}"
    file="${file//\"/\\\"}"
    printf ',"instructions":["%s"]' "$file"
}
