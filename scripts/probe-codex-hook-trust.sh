#!/usr/bin/env bash
# Probe Codex hook trust isolation without touching the operator's profile.
#
# CODEX_HOME must point at a disposable profile containing only the auth.json
# copy used for this probe. The script refuses the live ~/.codex profile,
# runs Codex with a fresh CODEX_HOME, and denies writes to both the source
# profile and the live profile. Exit codes:
#   0  isolation failed: an untrusted tenant or project hook ran
#   2  inconclusive (including provider failure or an unverified layer)
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
control_root="$probe_root/control-project"
marker_root="$probe_root/markers"
helper="$probe_root/marker-hook"
profile="$probe_root/deny-writes.sb"
mkdir -p "$probe_home" "$project_root/.codex" "$control_root/.codex" "$marker_root"

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
    tenant|project|control|session)
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
control_command="$helper control"
session_command="$helper session"

# Codex hook files have a top-level `hooks` envelope. Keep the fixture in the
# provider's actual file shape, including an empty matcher, so a missing marker
# is evidence about trust/discovery rather than a malformed test file.
write_hooks_file() {
    local command="$1"
    local destination="$2"
    jq -n --arg command "$command" \
        '{hooks:{SessionStart:[{matcher:"",hooks:[{type:"command",command:$command,timeout:10}]}]}}' \
        > "$destination"
    chmod 600 "$destination"
}

write_hooks_file "$tenant_command" "$probe_home/hooks.json"
write_hooks_file "$project_command" "$project_root/.codex/hooks.json"
write_hooks_file "$control_command" "$control_root/.codex/hooks.json"

# Codex discovers project hooks through the Git checkout. Both checkouts are
# explicitly trusted as projects so Codex will load their project hook files;
# neither hook file has persisted hook trust. The control checkout proves that
# a valid project layer is discoverable and executable, while the probe
# checkout supplies the no-bypass/bypass comparison.
init_project() {
    local root="$1"
    git -C "$root" init -q
    git -C "$root" config user.email c11-probe@example.invalid
    git -C "$root" config user.name c11-probe
    printf 'c11 hook trust probe\n' > "$root/.probe-fixture"
    git -C "$root" add .probe-fixture
    git -C "$root" commit -qm c11-probe-fixture
}
init_project "$project_root"
init_project "$control_root"

project_root="$(cd "$project_root" && pwd -P)"
control_root="$(cd "$control_root" && pwd -P)"

cat > "$probe_home/config.toml" <<EOF
[features]
hooks = true

[projects."$control_root"]
trust_level = "trusted"

[projects."$project_root"]
trust_level = "trusted"
EOF
chmod 600 "$probe_home/config.toml"

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

project_hooks_before="$probe_root/project-hooks-before"
control_hooks_before="$probe_root/control-hooks-before"
cp "$project_root/.codex/hooks.json" "$project_hooks_before"
cp "$control_root/.codex/hooks.json" "$control_hooks_before"

cat > "$profile" <<EOF
(version 1)
(deny file-write* (subpath "$live_codex_home"))
(deny file-write* (subpath "$source_codex_home"))
(allow default)
EOF

run_bounded() {
    local mode="$1"
    local root="$2"
    local log="$3"
    local -a args=(--enable hooks)
    if [[ "$mode" == "bypass" ]]; then
        args+=(--dangerously-bypass-hook-trust)
    fi
    args+=(
        -c "hooks.SessionStart=$session_entry"
        exec
        --json
        -m "$probe_model"
        "$probe_prompt"
    )
    rm -f "$marker_root/tenant" "$marker_root/project" "$marker_root/session"
    (
        export CODEX_HOME="$probe_home"
        export C11_PROBE_MARKERS="$marker_root"
        cd "$root"
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

marker_present() {
    [[ -f "$marker_root/$1" ]]
}

provider_succeeded() {
    local log="$1"
    local status="$2"
    [[ "$status" == 0 ]] || return 1
    [[ -s "$log" ]] || return 1
    grep -q '"type":"turn.completed"' "$log" || return 1
    grep -q '"type":"item.completed"' "$log" || return 1
    grep -q '"type":"agent_message"' "$log"
}

control_log="$probe_root/control.log"
no_bypass_log="$probe_root/no-bypass.log"
bypass_log="$probe_root/bypass.log"
control_status=0
no_bypass_status=0
bypass_status=0
run_bounded bypass "$control_root" "$control_log" || control_status=$?
control_provider=0
control_project=0
control_session=0
if provider_succeeded "$control_log" "$control_status"; then control_provider=1; fi
if marker_present control; then control_project=1; fi
if marker_present session; then control_session=1; fi

run_bounded no-bypass "$project_root" "$no_bypass_log" || no_bypass_status=$?
no_bypass_provider=0
no_bypass_tenant=0
no_bypass_project=0
no_bypass_session=0
if provider_succeeded "$no_bypass_log" "$no_bypass_status"; then no_bypass_provider=1; fi
if marker_present tenant; then no_bypass_tenant=1; fi
if marker_present project; then no_bypass_project=1; fi
if marker_present session; then no_bypass_session=1; fi

run_bounded bypass "$project_root" "$bypass_log" || bypass_status=$?
bypass_provider=0
bypass_tenant=0
bypass_project=0
bypass_session=0
if provider_succeeded "$bypass_log" "$bypass_status"; then bypass_provider=1; fi
if marker_present tenant; then bypass_tenant=1; fi
if marker_present project; then bypass_project=1; fi
if marker_present session; then bypass_session=1; fi

live_after="$probe_root/live-after"
source_after="$probe_root/source-after"
snapshot_tree "$live_codex_home" > "$live_after"
snapshot_tree "$source_codex_home" > "$source_after"
live_profile_unchanged=1
source_profile_unchanged=1
if ! cmp -s "$live_before" "$live_after"; then live_profile_unchanged=0; fi
if ! cmp -s "$source_before" "$source_after"; then source_profile_unchanged=0; fi
project_hooks_unchanged=0
control_hooks_unchanged=0
if cmp -s "$project_hooks_before" "$project_root/.codex/hooks.json"; then project_hooks_unchanged=1; fi
if cmp -s "$control_hooks_before" "$control_root/.codex/hooks.json"; then control_hooks_unchanged=1; fi

version="$("$codex_bin" --version 2>/dev/null | head -n 1 | tr '\n' ' ' || true)"
if [[ -z "$version" ]]; then
    version="unknown"
fi
printf 'VERSION %s\n' "$version"
project_discoverable=0
control_discoverable=0
if [[ "$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null || true)" == "$project_root" ]]; then project_discoverable=1; fi
if [[ "$(git -C "$control_root" rev-parse --show-toplevel 2>/dev/null || true)" == "$control_root" ]]; then control_discoverable=1; fi
printf 'DISCOVERY project_git=%s control_git=%s control_project=%s control_hooks_unchanged=%s project_hooks_unchanged=%s\n' \
    "$project_discoverable" "$control_discoverable" "$control_project" \
    "$control_hooks_unchanged" "$project_hooks_unchanged"
printf 'PROFILE live_unchanged=%s source_unchanged=%s\n' \
    "$live_profile_unchanged" "$source_profile_unchanged"
printf 'CONTROL status=%s timeout=%s provider=%s project=%s session=%s\n' \
    "$control_status" "$([[ "$control_status" == 124 ]] && printf 1 || printf 0)" \
    "$control_provider" "$control_project" "$control_session"
printf 'NO_BYPASS status=%s timeout=%s provider=%s tenant=%s project=%s session=%s\n' \
    "$no_bypass_status" "$([[ "$no_bypass_status" == 124 ]] && printf 1 || printf 0)" \
    "$no_bypass_provider" "$no_bypass_tenant" "$no_bypass_project" "$no_bypass_session"
printf 'BYPASS status=%s timeout=%s provider=%s tenant=%s project=%s session=%s\n' \
    "$bypass_status" "$([[ "$bypass_status" == 124 ]] && printf 1 || printf 0)" \
    "$bypass_provider" "$bypass_tenant" "$bypass_project" "$bypass_session"

if (( live_profile_unchanged == 0 || source_profile_unchanged == 0 )); then
    inconclusive "PROFILE_METADATA_CHANGED"
fi

if (( control_discoverable == 0 || project_discoverable == 0 || control_provider == 0 || control_project == 0 )); then
    inconclusive "POSITIVE_DISCOVERY_CONTROL_FAILED"
fi

if (( control_hooks_unchanged == 0 || project_hooks_unchanged == 0 )); then
    inconclusive "HOOK_FIXTURE_CHANGED"
fi

if (( no_bypass_provider == 0 || bypass_provider == 0 || no_bypass_status != 0 || bypass_status != 0 )); then
    inconclusive "PROVIDER_FAILURE_OR_NONCOMPARABLE_RUN"
fi

# The target project marker must fire in at least one successful run; otherwise
# the project layer was never shown discoverable and the isolation claim is not
# evidence. The bypass run is the positive execution leg for every untrusted
# layer; a no-bypass execution is itself an isolation failure.
if (( bypass_tenant == 0 || bypass_project == 0 || bypass_session == 0 )); then
    inconclusive "PROJECT_OR_CONTROL_LAYER_UNVERIFIED"
fi

if (( no_bypass_tenant == 1 || no_bypass_project == 1 || no_bypass_session == 1 )); then
    printf 'RESULT status=ISOLATION_FAILED reason=UNTRUSTED_LAYER_EXECUTED_WITHOUT_BYPASS\n'
    exit 0
fi

if (( bypass_tenant == 1 || bypass_project == 1 )); then
    printf 'RESULT status=ISOLATION_FAILED reason=UNTRUSTED_LAYER_EXECUTED\n'
    exit 0
fi

if (( bypass_session == 1 )); then
    printf 'RESULT status=ISOLATION_HOLDS reason=SESSION_ONLY\n'
    exit 2
fi

inconclusive "MISSING_SESSION_MARKER_OR_PROVIDER_FAILURE"
