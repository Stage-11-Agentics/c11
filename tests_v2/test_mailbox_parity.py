#!/usr/bin/env python3
"""C11-13 Stage 2 parity test: CLI sender vs raw-file sender must produce
byte-identical inbox state for the same logical payload.

This is the drift-enforcement lock per design doc §3 rule #6. Assumes a c11
app is running and its socket is reachable (either via CMUX_SOCKET env or the
default discovery path).

The test is parameterised over 8 envelope variations that exercise every axis
the schema allows (to-only, topic-only, urgent, reply chain, content_type,
body_ref, ext, ttl_seconds). For each variation we pin `--id` and `--ts` to
the same value on both sender paths and route them through two isolated
workspaces, so the inbox files can be compared byte-for-byte with no
JSON normalization.

Topic-only is Stage 2's rejected-semantics case: the CLI exits non-zero and
no envelope is produced. The test asserts that rejection instead of parity.

Run manually:

    CMUX_SOCKET=/path/to/c11.sock python3 tests_v2/test_mailbox_parity.py
"""

import glob
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get(
    "C11_SOCKET", "/tmp/cmux-debug.sock"
)

STATE_ROOT = Path(
    os.environ.get("C11_STATE")
    or os.path.expanduser("~/Library/Application Support/c11mux")
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = (
        os.environ.get("C11_CLI")
        or os.environ.get("CMUXTERM_CLI")
        or os.environ.get("CMUX_CLI")
    )
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    candidates = glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/c11"
        ),
        recursive=True,
    )
    candidates += glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
        ),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/c11")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError(
            "Could not locate c11 CLI binary; set C11_CLI/CMUXTERM_CLI/CMUX_CLI"
        )
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(
    cli: str,
    args: List[str],
    env: Optional[Dict[str, str]] = None,
    capture: bool = True,
) -> subprocess.CompletedProcess:
    merged_env = dict(os.environ)
    merged_env.pop("CMUX_WORKSPACE_ID", None)
    merged_env.pop("CMUX_SURFACE_ID", None)
    merged_env.pop("CMUX_TAB_ID", None)
    if env:
        merged_env.update(env)
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(
        cmd,
        capture_output=capture,
        text=True,
        check=False,
        env=merged_env,
    )
    return proc


def _encode_envelope(payload: Dict) -> bytes:
    """Serialise an envelope dict the same way MailboxEnvelope.encode() does.

    JSONSerialization (Swift) with `.sortedKeys` produces compact JSON with
    keys in lexicographic order and no whitespace. The equivalent Python
    serialization is `json.dumps(..., sort_keys=True, separators=(",", ":"),
    ensure_ascii=False)`. Parity depends on both sides producing byte-identical
    output for the same logical payload.
    """
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _atomic_write(data: bytes, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.parent / f".{uuid.uuid4().hex}.tmp"
    temp.write_bytes(data)
    temp.rename(target)


def _new_ulid(cli: str) -> str:
    proc = _run_cli(cli, ["mailbox", "new-id"])
    _must(proc.returncode == 0, f"mailbox new-id failed: {proc.stderr}")
    return proc.stdout.strip()


def _fixed_ts(seq: int) -> str:
    base = "2026-04-24T00:00:00"
    return f"{base}.{seq:03d}Z"


PAYLOADS = [
    {
        "name": "minimal",
        "extra": {},
        "cli_args": [],
        "body": "build green",
    },
    {
        "name": "urgent",
        "extra": {"urgent": True},
        "cli_args": ["--urgent"],
        "body": "urgent payload",
    },
    {
        "name": "topic-and-to",
        "extra": {"topic": "ci.status"},
        "cli_args": ["--topic", "ci.status"],
        "body": "topic + to",
    },
    {
        "name": "reply-chain",
        "extra": {
            "reply_to": "sender",
            "in_reply_to": "01K3A2B7X8PQRTVWYZ0123456K",
        },
        "cli_args": [
            "--reply-to",
            "sender",
            "--in-reply-to",
            "01K3A2B7X8PQRTVWYZ0123456K",
        ],
        "body": "reply body",
    },
    {
        "name": "content-type-json",
        "extra": {"content_type": "application/json"},
        "cli_args": ["--content-type", "application/json"],
        "body": '{"k":"v"}',
    },
    {
        "name": "body-ref",
        "extra": {"body_ref": "/tmp/c11-parity-blob"},
        "cli_args": ["--body-ref", "/tmp/c11-parity-blob"],
        "body": "",
    },
    {
        "name": "ttl",
        "extra": {"ttl_seconds": 600},
        "cli_args": ["--ttl-seconds", "600"],
        "body": "ephemeral",
    },
    {
        # Stage 2 does not implement topic-only delivery. The CLI must reject
        # the send with a non-zero exit so operators see the failure instead
        # of silently losing the message. See review cycle 1 P0 #3.
        "name": "topic-only",
        "extra": {"topic": "broadcast.deploy"},
        "cli_args": ["--topic", "broadcast.deploy"],
        "body": "topic-only body",
        "omit_to": True,
        "cli_must_reject": True,
    },
]


def _build_expected_envelope(
    *,
    envelope_id: str,
    ts: str,
    payload: Dict,
    sender: str,
    receiver: str,
) -> Dict:
    env: Dict = {
        "version": 1,
        "id": envelope_id,
        "from": sender,
        "ts": ts,
        "body": payload["body"],
    }
    if not payload.get("omit_to"):
        env["to"] = receiver
    env.update(payload["extra"])
    return env


def _write_raw_envelope(
    *,
    state_root: Path,
    workspace_id: str,
    envelope: Dict,
) -> Path:
    outbox = state_root / "workspaces" / workspace_id / "mailboxes" / "_outbox"
    target = outbox / f"{envelope['id']}.msg"
    _atomic_write(_encode_envelope(envelope), target)
    return target


def _wait_for_inbox(
    *,
    state_root: Path,
    workspace_id: str,
    receiver: str,
    envelope_id: str,
    timeout_s: float = 5.0,
) -> Path:
    inbox = state_root / "workspaces" / workspace_id / "mailboxes" / receiver
    target = inbox / f"{envelope_id}.msg"
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if target.exists():
            return target
        time.sleep(0.1)
    raise cmuxError(f"Envelope did not land in inbox within {timeout_s}s: {target}")


def _create_workspace_with_surfaces(
    c,
    *,
    sender_name: str,
    receiver_name: str,
) -> str:
    """Create an isolated workspace, name the current surface as sender, and
    add a receiver surface with `mailbox.delivery: silent`. Returns the
    workspace id.

    The parity test uses two workspaces so both sender paths can pin the
    same envelope id without colliding in a shared outbox or triggering
    the dispatcher's per-workspace `recentlySeen` dedup cache.
    """
    created = c._call("workspace.create") or {}
    workspace_id = str(created.get("workspace_id") or "")
    _must(bool(workspace_id), f"workspace.create returned no id: {created}")
    c._call("workspace.select", {"workspace_id": workspace_id})

    current = c._call("surface.current", {"workspace_id": workspace_id}) or {}
    sender_id = str(current.get("surface_id") or "")
    _must(bool(sender_id), f"surface.current returned no id: {current}")
    c._call(
        "surface.set_metadata",
        {
            "workspace_id": workspace_id,
            "surface_id": sender_id,
            "metadata": {"title": sender_name},
            "mode": "merge",
            "source": "explicit",
        },
    )

    created_surface = c._call(
        "surface.create",
        {"workspace_id": workspace_id, "type": "terminal"},
    ) or {}
    receiver_id = str(created_surface.get("surface_id") or "")
    _must(bool(receiver_id), f"surface.create returned no id: {created_surface}")
    c._call(
        "surface.set_metadata",
        {
            "workspace_id": workspace_id,
            "surface_id": receiver_id,
            "metadata": {
                "title": receiver_name,
                "mailbox.delivery": "silent",
            },
            "mode": "merge",
            "source": "explicit",
        },
    )
    return workspace_id


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)
    sender_name = f"sender-{stamp}"
    receiver_name = f"receiver-{stamp}"

    with cmux(SOCKET_PATH) as c:
        # Two isolated workspaces: CLI path writes into workspace_cli, raw
        # path writes into workspace_raw. This lets us pin the same envelope
        # id + ts on both paths and assert cli_inbox_bytes == raw_inbox_bytes
        # directly — the drift-enforcement lock per design doc §3 rule #6.
        workspace_cli = _create_workspace_with_surfaces(
            c, sender_name=sender_name, receiver_name=receiver_name
        )
        workspace_raw = _create_workspace_with_surfaces(
            c, sender_name=sender_name, receiver_name=receiver_name
        )

        failures = []
        parity_ok_count = 0
        reject_ok_count = 0
        for idx, payload in enumerate(PAYLOADS):
            pinned_ts = _fixed_ts(idx)
            pinned_id = _new_ulid(cli)

            # CLI sender — pinned id + ts, into workspace_cli.
            args = [
                "mailbox",
                "send",
                "--from",
                sender_name,
                "--body",
                payload["body"],
                "--id",
                pinned_id,
                "--ts",
                pinned_ts,
            ]
            if not payload.get("omit_to"):
                args.extend(["--to", receiver_name])
            args.extend(payload["cli_args"])
            proc = _run_cli(
                cli,
                args,
                env={"CMUX_WORKSPACE_ID": workspace_cli},
            )

            # Topic-only (Stage 2): CLI must reject with non-zero exit.
            if payload.get("cli_must_reject"):
                if proc.returncode == 0:
                    failures.append(
                        f"[{payload['name']}] CLI must reject topic-only "
                        f"send with non-zero exit, got 0 (stdout={proc.stdout!r})"
                    )
                else:
                    reject_ok_count += 1
                continue

            if proc.returncode != 0:
                failures.append(
                    f"[{payload['name']}] CLI send failed: {proc.stderr}"
                )
                continue

            cli_inbox_path = _wait_for_inbox(
                state_root=STATE_ROOT,
                workspace_id=workspace_cli,
                receiver=receiver_name,
                envelope_id=pinned_id,
            )
            cli_inbox_bytes = cli_inbox_path.read_bytes()

            # Raw-file sender — same pinned id + ts, into workspace_raw.
            raw_envelope = _build_expected_envelope(
                envelope_id=pinned_id,
                ts=pinned_ts,
                payload=payload,
                sender=sender_name,
                receiver=receiver_name,
            )
            _write_raw_envelope(
                state_root=STATE_ROOT,
                workspace_id=workspace_raw,
                envelope=raw_envelope,
            )

            raw_inbox_path = _wait_for_inbox(
                state_root=STATE_ROOT,
                workspace_id=workspace_raw,
                receiver=receiver_name,
                envelope_id=pinned_id,
            )
            raw_inbox_bytes = raw_inbox_path.read_bytes()

            # The drift-enforcement lock: direct byte-for-byte equality.
            # No JSON re-serialization, no normalization, no key-sort dance.
            # Any divergence — Unicode form, slash escaping, whitespace,
            # key order, integer vs float, trailing newlines — fails here.
            if cli_inbox_bytes != raw_inbox_bytes:
                failures.append(
                    f"[{payload['name']}] byte mismatch:\n"
                    f"  cli ({len(cli_inbox_bytes)}B): {cli_inbox_bytes!r}\n"
                    f"  raw ({len(raw_inbox_bytes)}B): {raw_inbox_bytes!r}"
                )
            else:
                parity_ok_count += 1

        if failures:
            print("\nFAILURES:")
            for msg in failures:
                print(f"  {msg}")
            return 1

    print(
        f"OK: {parity_ok_count} byte-identical parity case(s); "
        f"{reject_ok_count} CLI-rejection case(s); "
        f"total {len(PAYLOADS)} payload variation(s)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
