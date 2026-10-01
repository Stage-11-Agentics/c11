#!/usr/bin/env bash
# Smoke test for CI: launch the app, send a command, verify it stays alive for 15 seconds.
set -euo pipefail

SOCKET_PATH="/tmp/c11-debug.sock"
STABILITY_WAIT=15

echo "=== Smoke Test ==="

# --- Find the built app ---
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/c11 DEV.app" -print -quit 2>/dev/null || true)
if [ -z "$APP" ]; then
  echo "ERROR: Built app not found in DerivedData"
  exit 1
fi
echo "App: $APP"
BINARY="$APP/Contents/MacOS/c11"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: App binary not found or not executable: $BINARY"
  exit 1
fi

# --- Clean up stale socket and any existing instances ---
rm -f "$SOCKET_PATH" /tmp/c11mux-debug.sock
pkill -x "c11" 2>/dev/null || true
pkill -x "cmux" 2>/dev/null || true
sleep 1

# --- Launch the app directly (not via `open`, which can silently fail on CI) ---
echo "Launching app..."
C11_SOCKET_MODE=allowAll CMUX_SOCKET_MODE=allowAll C11_UI_TEST_MODE=1 CMUX_UI_TEST_MODE=1 "$BINARY" > /tmp/c11-smoke-stdout.log 2>&1 &
APP_PID=$!
echo "App PID: $APP_PID"

# --- Verify process is alive after 2s ---
sleep 2
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App exited immediately after launch"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
  echo "--- debug log ---"
  tail -50 /tmp/c11-debug.log 2>/dev/null || true
  echo "--- crash reports ---"
  ls -lt ~/Library/Logs/DiagnosticReports/*c11* ~/Library/Logs/DiagnosticReports/*cmux* 2>/dev/null | head -5 || echo "(none)"
  exit 1
fi

# --- Wait for socket (up to 30s) ---
echo "Waiting for socket at $SOCKET_PATH..."
SOCKET_READY=false
for i in $(seq 1 60); do
  if [ -S "$SOCKET_PATH" ]; then
    echo "Socket ready after $((i / 2))s"
    SOCKET_READY=true
    break
  fi
  # Check if process died while waiting
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "ERROR: App crashed while waiting for socket"
    echo "--- stdout/stderr ---"
    cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
    echo "--- debug log ---"
    tail -50 /tmp/c11-debug.log 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done
if [ "$SOCKET_READY" != "true" ]; then
  echo "ERROR: Socket not ready after 30s"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/c11-debug.log 2>/dev/null || true
  ls -la /tmp/c11-debug* 2>/dev/null || true
  pgrep -la "c11" || pgrep -la "cmux" || echo "No c11/cmux processes found"
  exit 1
fi

# --- Ping the socket ---
echo "Pinging socket..."
PING_RESPONSE=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Ping response: $PING_RESPONSE"
if [ "$PING_RESPONSE" != "PONG" ]; then
  echo "ERROR: Expected PONG, got: $PING_RESPONSE"
  exit 1
fi

# --- Wait until a focused terminal is attached ---
# send waits at most 2s for the ghostty surface. On the virtual-display runner
# that attach can take ~3s, which blows the 5s recv timeout. v1 send targets
# the selected workspace's focused terminal, so poll debug.terminals until one
# entry is runtime_surface_ready, surface_focused, and workspace_selected.
echo "Waiting for a focused, attached terminal (up to 20s)..."
if ! python3 - "$SOCKET_PATH" "$APP_PID" <<'PY'
import json, os, socket, sys, time

socket_path = sys.argv[1]
app_pid = int(sys.argv[2])
deadline_s = 20.0
poll_gap_s = 0.5
recv_timeout_s = 5.0
start = time.monotonic()
poll = 0

def app_alive():
    try:
        os.kill(app_pid, 0)
    except OSError:
        return False
    return True

def recv_line(conn):
    buf = b""
    while b"\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 8000000:
            break
    return buf.split(b"\n", 1)[0].decode("utf-8", "replace")

while True:
    elapsed = time.monotonic() - start
    if elapsed >= deadline_s:
        print(
            "ERROR: Timed out after 20s waiting for a focused, attached terminal surface",
            flush=True,
        )
        sys.exit(1)
    if not app_alive():
        print("ERROR: App crashed while waiting for a terminal surface", flush=True)
        sys.exit(1)
    poll += 1
    remaining = deadline_s - elapsed
    summary = "no response"
    ready = False
    conn = None
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(min(recv_timeout_s, max(0.1, remaining)))
        conn.connect(socket_path)
        request = json.dumps({
            "id": poll,
            "method": "debug.terminals",
            "params": {},
        }) + "\n"
        conn.sendall(request.encode())
        line = recv_line(conn)
        msg = json.loads(line) if line else {}
        if not msg.get("ok"):
            err = msg.get("error") or {}
            summary = "error %s: %s" % (err.get("code"), err.get("message"))
        else:
            terminals = (msg.get("result") or {}).get("terminals") or []
            selected_focused_attached = 0
            for terminal in terminals:
                # v1 send uses the selected workspace's focused terminal.
                if (
                    terminal.get("runtime_surface_ready") is True
                    and terminal.get("surface_focused") is True
                    and terminal.get("workspace_selected") is True
                ):
                    selected_focused_attached += 1
            summary = "terminals=%d selected_focused_attached=%d" % (
                len(terminals),
                selected_focused_attached,
            )
            ready = selected_focused_attached > 0
    except socket.timeout:
        summary = "timed out"
    except Exception as exc:
        summary = "%s: %s" % (type(exc).__name__, exc)
    finally:
        if conn is not None:
            conn.close()
    now = time.monotonic() - start
    print("Readiness poll %d (%.1fs): %s" % (poll, now, summary), flush=True)
    if ready:
        print("Focused terminal surface is attached after %.1fs" % now, flush=True)
        sys.exit(0)
    time.sleep(min(poll_gap_s, max(0.0, deadline_s - (time.monotonic() - start))))
PY
then
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
  echo "--- debug log ---"
  tail -50 /tmp/c11-debug.log 2>/dev/null || true
  exit 1
fi

# --- Send a command to the terminal ---
echo "Sending 'time' command to terminal..."
send_time() {
  python3 - "$SOCKET_PATH" <<'PY'
import socket, sys

path = sys.argv[1]
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.settimeout(5.0)
try:
    conn.connect(path)
    # v1 command is "send time\n" (the handler turns \n into Enter), plus the
    # socket's framing newline.
    conn.sendall(b"send time\\n\n")
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    line = data.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
    print(line if line else "ERROR: empty send reply")
except socket.timeout:
    print("TIMEOUT")
finally:
    conn.close()
PY
}
SEND_RESPONSE=$(send_time)
echo "Send response: $SEND_RESPONSE"
if [ "$SEND_RESPONSE" != "OK" ]; then
  echo "Send timed out or returned an error; retried"
  SEND_RESPONSE=$(send_time)
  echo "Send response after retry: $SEND_RESPONSE"
  if [ "$SEND_RESPONSE" != "OK" ]; then
    echo "ERROR: send failed after retry: $SEND_RESPONSE"
    echo "--- stdout/stderr ---"
    cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -50 || true
    echo "--- debug log ---"
    tail -50 /tmp/c11-debug.log 2>/dev/null || true
    exit 1
  fi
fi

# --- Wait and verify stability ---
echo "Waiting ${STABILITY_WAIT}s to verify stability..."
sleep "$STABILITY_WAIT"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App crashed during ${STABILITY_WAIT}s stability check"
  echo "--- stdout/stderr ---"
  cat /tmp/c11-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/c11-debug.log 2>/dev/null || true
  exit 1
fi

# --- Final ping ---
FINAL_PING=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Final ping: $FINAL_PING"
if [ "$FINAL_PING" != "PONG" ]; then
  echo "ERROR: App not responsive after ${STABILITY_WAIT}s"
  exit 1
fi

echo "=== Smoke test passed ==="

# --- Cleanup ---
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
