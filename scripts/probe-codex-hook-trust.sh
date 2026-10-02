#!/usr/bin/env bash
# Probe Codex hook trust isolation without touching the operator's profile.
#
# CODEX_HOME must point at a disposable profile containing only the auth.json
# copy used for this probe. The script refuses the live ~/.codex profile,
# runs Codex with a fresh CODEX_HOME, and denies writes to both the source
# profile and the live profile. Exit codes:
#   0  isolation failed: the bypass ran a tenant or project hook
#   2  inconclusive, or isolation held (the result is not an implementation
#      license; the plan must be revised before enabling hooks)
#   3  invalid invocation

set -euo pipefail

usage() {
    printf '%s\n' \
        "Usage: CODEX_HOME=/path/to/disposable/profile [CODEX_BIN=/path/to/codex] $0" \
        "  CODEX_HOME must not be the operator's live ~/.codex directory." >&2
}

inconclusive() {
    printf 'RESULT status=INCONCLUSIVE reason=%s\n' "$1"
    exit 2
}

if [[ -z "${CODEX_HOME:-}" ]]; then
    usage
    exit 3
fi

if [[ ! -d "$CODEX_HOME" ]]; then
    inconclusive "CODEX_HOME_NOT_DIRECTORY"
fi

if [[ "$CODEX_HOME" != /* || "${CODEX_HOME:0:1}" == "-" ]]; then
    inconclusive "CODEX_HOME_NOT_ABSOLUTE"
fi

live_codex_home="${HOME:-}/.codex"
source_codex_home="$(cd "$CODEX_HOME" && pwd -P)"
live_codex_home="$(cd "$live_codex_home" 2>/dev/null && pwd -P || printf '%s' "$live_codex_home")"
if [[ "$source_codex_home" == "$live_codex_home" ]]; then
    usage
    inconclusive "LIVE_CODEX_HOME_REFUSED"
fi

if [[ ! -f "$source_codex_home/auth.json" ]]; then
    inconclusive "AUTH_JSON_MISSING"
fi

codex_bin="${CODEX_BIN:-}"
if [[ -z "$codex_bin" ]]; then
    codex_bin="$(command -v codex || true)"
fi
if [[ -z "$codex_bin" || ! -x "$codex_bin" ]]; then
    inconclusive "CODEX_BINARY_MISSING"
fi
codex_bin="$(cd "$(dirname "$codex_bin")" && pwd -P)/$(basename "$codex_bin")"
if [[ "$codex_bin" == */Resources/bin/codex ]]; then
    inconclusive "CODEX_BINARY_IS_C11_WRAPPER"
fi

if ! command -v sandbox-exec >/dev/null 2>&1; then
    inconclusive "SANDBOX_EXEC_UNAVAILABLE"
fi
if ! command -v jq >/dev/null 2>&1; then
    inconclusive "JQ_MISSING"
fi

probe_root="$(mktemp -d "${TMPDIR:-/tmp}/c11-codex-hook-trust.XXXXXX")"
probe_home="$probe_root/codex-home"
project_root="$probe_root/project"
marker_root="$probe_root/markers"
helper="$probe_root/marker-hook"
profile="$probe_root/deny-writes.sb"
mkdir -p "$probe_home" "$project_root/.codex" "$marker_root"

cleanup() {
    rm -f "$probe_home/auth.json" "$profile" "$helper" 2>/dev/null || true
    rm -rf "$probe_root" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# A path with shell/TOML quoting metacharacters would make the provider's
# inline -c syntax ambiguous. Refuse rather than test a different command.
case "$probe_root$source_codex_home$live_codex_home" in
    *"'"*|*"\""*|*"\\"*)
        inconclusive "UNSAFE_PROFILE_PATH"
        ;;
esac

install -m 600 "$source_codex_home/auth.json" "$probe_home/auth.json"

cat > "$helper" <<'EOF'
#!/bin/sh
set -eu
marker_root="${C11_PROBE_MARKERS:?}"
case "${1:-}" in
    tenant|project|session)
        umask 077
        printf 'marker=%s\n' "$1" > "$marker_root/$1"
        ;;
    *)
        exit 64
        ;;
esac
EOF
chmod 700 "$helper"

tenant_command="$helper tenant"
project_command="$helper project"
session_command="$helper session"

# Codex's hook-file shape is intentionally the same minimal structural shape
# used by its per-process -c hook argument. The marker helper writes no prompt,
# tool, account, or model data.
jq -n --arg command "$tenant_command" \
    '{SessionStart:[{hooks:[{type:"command",command:$command,timeout:10}]}]}' \
    > "$probe_home/hooks.json"
jq -n --arg command "$project_command" \
    '{SessionStart:[{hooks:[{type:"command",command:$command,timeout:10}]}]}' \
    > "$project_root/.codex/hooks.json"
chmod 600 "$probe_home/hooks.json" "$project_root/.codex/hooks.json"

session_entry="[{hooks=[{type=\"command\",command=\"${session_command}\",timeout=10}]}]"
probe_prompt="${CODEX_PROBE_PROMPT:-Reply with the single word OK.}"
probe_model="${CODEX_PROBE_MODEL:-gpt-5.6-luna}"

snapshot_tree() {
    local root="$1"
    if [[ -d "$root" ]]; then
        find "$root" -type f -exec stat -f '%N %z %m' {} + 2>/dev/null | sort
    fi
}

live_before="$probe_root/live-before"
source_before="$probe_root/source-before"
snapshot_tree "$live_codex_home" > "$live_before"
snapshot_tree "$source_codex_home" > "$source_before"

cat > "$profile" <<EOF
(version 1)
(deny file-write* (subpath "$live_codex_home"))
(deny file-write* (subpath "$source_codex_home"))
(allow default)
EOF

run_bounded() {
    local mode="$1"
    local log="$2"
    local -a args=(--enable hooks)
    if [[ "$mode" == "bypass" ]]; then
        args+=(--dangerously-bypass-hook-trust)
    fi
    args+=(
        -c "hooks.SessionStart=$session_entry"
        exec
        --skip-git-repo-check
        --json
        -m "$probe_model"
        "$probe_prompt"
    )
    rm -f "$marker_root/tenant" "$marker_root/project" "$marker_root/session"
    (
        export CODEX_HOME="$probe_home"
        export C11_PROBE_MARKERS="$marker_root"
        cd "$project_root"
        sandbox-exec -f "$profile" "$codex_bin" "${args[@]}"
    ) > "$log" 2>&1 &
    local pid=$!
    local deadline=$((SECONDS + 20))
    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            printf '%s\n' "timeout" > "$log.status"
            return 124
        fi
        sleep 0.25
    done
    local status=0
    wait "$pid" || status=$?
    printf '%s\n' "$status" > "$log.status"
    return "$status"
}

no_bypass_log="$probe_root/no-bypass.log"
bypass_log="$probe_root/bypass.log"
no_bypass_status=0
bypass_status=0
run_bounded no-bypass "$no_bypass_log" || no_bypass_status=$?
no_bypass_tenant=0
no_bypass_project=0
no_bypass_session=0
[[ -f "$marker_root/tenant" ]] && no_bypass_tenant=1
[[ -f "$marker_root/project" ]] && no_bypass_project=1
[[ -f "$marker_root/session" ]] && no_bypass_session=1

run_bounded bypass "$bypass_log" || bypass_status=$?
bypass_tenant=0
bypass_project=0
bypass_session=0
[[ -f "$marker_root/tenant" ]] && bypass_tenant=1
[[ -f "$marker_root/project" ]] && bypass_project=1
[[ -f "$marker_root/session" ]] && bypass_session=1

live_after="$probe_root/live-after"
source_after="$probe_root/source-after"
snapshot_tree "$live_codex_home" > "$live_after"
snapshot_tree "$source_codex_home" > "$source_after"

version="$("$codex_bin" --version 2>/dev/null | head -n 1 | tr '\n' ' ' || true)"
if [[ -z "$version" ]]; then
    version="unknown"
fi
printf 'VERSION %s\n' "$version"
printf 'NO_BYPASS status=%s timeout=%s tenant=%s project=%s session=%s\n' \
    "$no_bypass_status" "$([[ "$no_bypass_status" == 124 ]] && printf 1 || printf 0)" \
    "$no_bypass_tenant" "$no_bypass_project" "$no_bypass_session"
printf 'BYPASS status=%s timeout=%s tenant=%s project=%s session=%s\n' \
    "$bypass_status" "$([[ "$bypass_status" == 124 ]] && printf 1 || printf 0)" \
    "$bypass_tenant" "$bypass_project" "$bypass_session"

if ! cmp -s "$live_before" "$live_after" || ! cmp -s "$source_before" "$source_after"; then
    inconclusive "PROFILE_METADATA_CHANGED"
fi

if (( bypass_tenant == 1 || bypass_project == 1 )); then
    printf 'RESULT status=ISOLATION_FAILED reason=UNTRUSTED_LAYER_EXECUTED\n'
    exit 0
fi

if (( bypass_session == 1 )) && (( bypass_tenant == 0 && bypass_project == 0 )); then
    printf 'RESULT status=ISOLATION_HOLDS reason=SESSION_ONLY\n'
    exit 2
fi

inconclusive "MISSING_SESSION_MARKER_OR_PROVIDER_FAILURE"
