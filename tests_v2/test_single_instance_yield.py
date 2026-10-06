#!/usr/bin/env python3
"""C11-298 duplicate-launch oracle. Run ONLY inside a disposable Atlas guest.

The outer runner owns the incumbent's launch, copied app preparation, synthetic
terminal fixture, display confinement, <=10 minute hard UI timer, screenshots,
normal Quit/dismissal and signed-update feed. This script launches ONLY two
newcomers using `open -n`: the incumbent's bundle, then a distinct copy with the
same bundle ID and executable bytes. No production discovery, broad pkill,
tenant writes, signing operations, or normal app quit is performed.

Outer-runner fixture requirements:
* Start the fixed artifact in the isolated guest; provide its exact PID, bundle,
  socket, workspace, terminal UUID and second terminal UUID. Bundle executable
  and identifier are read from each supplied Info.plist; names need not be DEV.
* In the target terminal set the UNEXPORTED shell variable
  C11_SINGLE_INSTANCE_SENTINEL to a random alphanumeric marker. Start a bounded
  child which periodically replaces an explicit heartbeat file with an increasing
  integer. Supply the actual shell/child PIDs and marker. Retain unsaved terminal
  output containing that marker. The outer runner owns this child's teardown.
* Let initial session saves settle, then supply --session-file and every other
  persistence file to protect via repeated --persistence-path (e.g. dirty/clean
  sentinel and conversation store). Absent paths are allowed and must stay absent.
* Copy the app to --copied-app before starting this script. Both artifacts must
  contain the fix: this cannot repair an already-running older destructive app.

Example (all paths/IDs belong to the disposable guest):
  python3 test_single_instance_yield.py --app /guest/c11.app \
    --copied-app /guest/copy/c11.app --incumbent-pid 123 --socket /tmp/guest.sock \
    --workspace-id <uuid> --tab-id <uuid> --second-tab-id <uuid> \
    --shell-pid 234 --child-pid 345 --heartbeat-file /tmp/guest-heartbeat \
    --marker <random-marker> --session-file /guest/state/session.json \
    --evidence-dir /guest/evidence/new-run

Each launch has a <=10s deadline. Evidence must identify a NEW PID in the exact
`instance.yield newcomer_pid=N incumbent_pid=I` diagnostic, prove it exited, and
show the incumbent PID, socket inode, graph UUIDs/refs, shell variable and child
heartbeat survived. File inode/mtime/hash comparisons prove no observed write to
SUPPLIED paths during each launch window; a changed path fails as "unsettled",
never as falsely attributed newcomer damage. Process-attributed filesystem
tracing, helper/coexistence tests, Quit UI, app.restart, and signed Sparkle update
proof are separate outer-runner/policy gates and are NOT claimed by this script.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import stat
import subprocess
import time
import uuid


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def run(command: list[str], timeout: float = 3) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, f"command failed: {command[0]}: {result.stderr.strip()}")
    return result.stdout.strip()


class Processes:
    """Exact executable paths; never substring-match app/CLI names."""
    def __init__(self) -> None:
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]

    def executable(self, pid: int) -> str | None:
        buffer = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            return None
        return str(Path(os.fsdecode(buffer.value)).resolve())

    def matching(self, executable: Path) -> set[int]:
        size = self.lib.proc_listpids(1, 0, None, 0)
        pids = (ctypes.c_int * (size // ctypes.sizeof(ctypes.c_int) + 512))()
        used = self.lib.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
        require(used >= 0, 'process enumeration failed')
        return {pid for pid in pids[:used // ctypes.sizeof(ctypes.c_int)]
                if pid > 0 and self.executable(pid) == str(executable)}


def bundle(path: Path) -> dict:
    path = path.resolve(strict=True)
    with (path / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    name = info.get('CFBundleExecutable')
    require(isinstance(name, str) and Path(name).name == name, 'invalid main executable name')
    executable = (path / 'Contents/MacOS' / name).resolve(strict=True)
    require(executable.is_relative_to(path), 'main executable escapes supplied app bundle')
    return {'path': str(path), 'bundle_id': info['CFBundleIdentifier'], 'executable': str(executable),
            'build': info.get('CFBundleVersion'), 'sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}


def process_identity(pid: int) -> str:
    return run(['/bin/ps', '-p', str(pid), '-o', 'pid=,ppid=,lstart=,comm='])


def descendant(child: int, ancestor: int) -> bool:
    for _ in range(16):
        if child == ancestor:
            return True
        if child <= 1:
            return False
        child = int(run(['/bin/ps', '-p', str(child), '-o', 'ppid=']))
    return False


def request(path: str, method: str, params: dict | None = None, timeout: float = 3) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        connection.sendall((json.dumps({'id': 298, 'method': method, 'params': params or {}}) + '\n').encode())
        with connection.makefile('rb') as stream:
            response = json.loads(stream.readline(8 * 1024 * 1024))
    require(response.get('id') == 298 and response.get('ok') is True,
            f'{method} failed: {response}')
    return response.get('result', {})


def graph(path: str) -> dict:
    tree = request(path, 'system.tree', {'scope': 'all'})
    # Ignore titles/focus/geometry: explicit duplicate launch may activate A.
    identities = {}
    for window in tree.get('windows', []):
        workspaces = {}
        for workspace in window.get('workspaces', []):
            areas = {area['id']: {'ref': area['ref'],
                                  'panels': {tab['id']: tab['ref'] for tab in area.get('panels', [])}}
                     for area in workspace.get('areas', [])}
            workspaces[workspace['id']] = {'ref': workspace['ref'], 'areas': areas}
        identities[window['id']] = {'ref': window['ref'], 'workspaces': workspaces}
    require(bool(identities), 'incumbent graph is empty')
    return {'identities': identities, 'tree': tree}


def persistence(paths: list[Path]) -> dict:
    result = {}
    for path in paths:
        if not path.exists():
            result[str(path)] = None
            continue
        require(path.is_file() and not path.is_symlink(), f'persistence path must be a file: {path}')
        before = path.stat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        after = path.stat()
        require((before.st_ino, before.st_mtime_ns, before.st_size) ==
                (after.st_ino, after.st_mtime_ns, after.st_size), f'unsettled file during capture: {path}')
        result[str(path)] = {'device': after.st_dev, 'inode': after.st_ino, 'mtime_ns': after.st_mtime_ns,
                             'size': after.st_size, 'sha256': digest}
    return result


def socket_identity(path: str) -> list[int]:
    info = os.stat(path)
    require(stat.S_ISSOCK(info.st_mode), 'provided path is not a socket')
    return [info.st_dev, info.st_ino]


def heartbeat(path: Path) -> int:
    # The outer fixture should replace atomically. Brief in-place writer gaps
    # are allowed; empty/unparseable content never counts as a heartbeat.
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        try:
            return int(path.read_text().strip())
        except (ValueError, FileNotFoundError):
            time.sleep(0.01)
    raise AssertionError('heartbeat file missing or not an integer')


def shell_probe(args: argparse.Namespace, phase: str) -> dict:
    nonce = uuid.uuid4().hex
    # Expected output contains the variable value, not its literal in the
    # command line, so echoed input cannot pass the survival assertion.
    command = (f"if kill -0 {args.child_pid} 2>/dev/null; then "
               f"printf 'C11_YIELD_{nonce} %s %s\\n' "
               '"$$" "$C11_SINGLE_INSTANCE_SENTINEL"; fi\n')
    params = {'workspace_id': args.workspace_id, 'panel_id': args.tab_id}
    request(args.socket, 'panel.send_text', {**params, 'text': command})
    pattern = re.compile(rf'C11_YIELD_{nonce} {args.shell_pid} {re.escape(args.marker)}(?:\s|$)')
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        result = request(args.socket, 'panel.read_text', params,
                         timeout=max(0.01, min(3, deadline - time.monotonic())))
        text = result.get('text')
        if text is None:
            text = base64.b64decode(result.get('base64', '')).decode(errors='replace')
        if pattern.search(text):
            return {'phase': phase, 'shell_pid': args.shell_pid, 'child_pid': args.child_pid, 'capture': text,
                    'proof_line': f'C11_YIELD_{nonce} {args.shell_pid} {args.marker}'}
        time.sleep(0.05)
    raise AssertionError(f'{phase}: original shell PID/unsaved variable/live child did not survive')


def save(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + '\n')


def launch_duplicate(args: argparse.Namespace, descriptor: dict, phase: str, processes: Processes,
                     base_graph: dict, identities: dict, base_socket: list[int]) -> dict:
    executable = Path(descriptor['executable'])
    existing = processes.matching(executable)
    expected = {args.incumbent_pid} if phase == 'same-bundle' else set()
    require(existing == expected, f'{phase}: unexpected existing same-executable PIDs {existing}')
    stderr_path = args.evidence_dir / f'{phase}.stderr.log'
    stdout_path = args.evidence_dir / f'{phase}.stdout.log'
    # Explicit guest overrides make any regression's blast radius the same
    # disposable fixture. Normal builds must yield before these are consumed.
    environment = {'C11_SOCKET_MODE': 'automation', 'C11_ALLOW_SOCKET_OVERRIDE': '1',
                   'C11_SOCKET_PATH': args.socket, 'C11_SOCKET': args.socket, 'C11_QA_LAUNCH': 'fresh'}
    for entry in args.launch_env:
        key, separator, value = entry.partition('=')
        require(bool(separator) and bool(key), '--launch-env expects KEY=VALUE')
        require(key not in environment, f'cannot override required guest setting {key}')
        environment[key] = value
    command = ['/usr/bin/open', '-n', '-W', '--stdout', str(stdout_path), '--stderr', str(stderr_path)]
    for key, value in environment.items():
        command.extend(['--env', f'{key}={value}'])
    command.extend(['-a', descriptor['path']])
    before_files = persistence([args.session_file, *args.persistence_path])
    before_beat = heartbeat(args.heartbeat_file)
    launched_at = time.time()
    observed = set()
    newcomer = None
    launcher = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            require(processes.executable(args.incumbent_pid) == identities['incumbent_executable'],
                    'incumbent disappeared during duplicate launch')
            require(socket_identity(args.socket) == base_socket, 'socket inode changed during duplicate launch')
            observed.update(processes.matching(executable) - existing)
            log = stderr_path.read_text(errors='replace') if stderr_path.exists() else ''
            records = re.findall(r'instance\.yield newcomer_pid=(\d+) incumbent_pid=(\d+)', log)
            if records:
                require(len(records) == 1, f'{phase}: ambiguous yield diagnostics {records}')
                newcomer, incumbent = map(int, records[0])
                require(incumbent == args.incumbent_pid and newcomer != incumbent and newcomer not in existing,
                        f'{phase}: wrong arbitration PID pair {records[0]}')
                observed.add(newcomer)
                if processes.executable(newcomer) is None and launcher.poll() is not None:
                    break
            time.sleep(0.02)
        require(newcomer is not None, f'{phase}: no attributed yield diagnostic; observed PIDs {sorted(observed)}')
        require(processes.executable(newcomer) is None, f'{phase}: newcomer {newcomer} did not exit')
        require(launcher.poll() == 0, f'{phase}: open -n -W did not finish successfully')
        require(processes.matching(executable) == existing, f'{phase}: another newcomer survived')
        after_files = persistence([args.session_file, *args.persistence_path])
        result = {'phase': phase, 'result': 'OBSERVED', 'bundle': descriptor, 'launched_at': launched_at,
                  'newcomer_pid': newcomer, 'incumbent_pid': args.incumbent_pid, 'observed_pids': sorted(observed),
                  'socket_identity': socket_identity(args.socket), 'before_files': before_files, 'after_files': after_files}
        # Save raw evidence even if an incumbent autosave makes attribution
        # inconclusive. Such a run must not be presented as newcomer damage.
        save(args.evidence_dir / f'{phase}-launch.json', result)
        require(after_files == before_files,
                f'{phase}: unsettled persistence changed during launch; writer attribution is unknown (see launch JSON)')
        for label, pid in [('incumbent', args.incumbent_pid), ('shell', args.shell_pid), ('child', args.child_pid)]:
            require(process_identity(pid) == identities[label], f'{phase}: {label} process identity changed')
        after_graph = graph(args.socket)
        require(after_graph['identities'] == base_graph['identities'], f'{phase}: graph UUIDs/refs changed')
        require(request(args.socket, 'system.ping').get('pong') is True, 'incumbent socket stopped answering')
        deadline = time.monotonic() + args.timeout
        after_beat = heartbeat(args.heartbeat_file)
        while after_beat <= before_beat and time.monotonic() < deadline:
            time.sleep(0.05)
            after_beat = heartbeat(args.heartbeat_file)
        require(after_beat > before_beat, f'{phase}: terminal child heartbeat stopped')
        shell = shell_probe(args, phase)
        require(identities['baseline_proof_line'] in shell['capture'], f'{phase}: unsaved baseline output disappeared')
        result.update(result='PASS', heartbeat_before=before_beat, heartbeat_after=after_beat,
                      shell=shell, graph=after_graph)
        save(args.evidence_dir / f'{phase}.json', result)
        return result
    finally:
        # Only our open helper and observed newcomers at this exact executable.
        # Never signal the incumbent, its terminal child, or another app path.
        for pid in observed:
            if pid != args.incumbent_pid and pid not in existing and processes.executable(pid) == str(executable):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if launcher.poll() is None:
            launcher.terminate()
        try:
            launcher.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            launcher.kill()
            launcher.communicate(timeout=2)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ['app', 'copied-app', 'heartbeat-file', 'session-file', 'evidence-dir']:
        parser.add_argument('--' + name, required=True, type=lambda value: Path(value).absolute())
    parser.add_argument('--persistence-path', action='append', default=[], type=lambda value: Path(value).absolute())
    for name in ['incumbent-pid', 'shell-pid', 'child-pid']:
        parser.add_argument('--' + name, required=True, type=int)
    for name in ['socket', 'workspace-id', 'tab-id', 'second-tab-id', 'marker']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--launch-env', action='append', default=[], help='additional explicit guest launch KEY=VALUE')
    parser.add_argument('--timeout', type=float, default=10, help='per-phase deadline, in (0, 10] seconds')
    args = parser.parse_args()
    require(0 < args.timeout <= 10, 'timeout must be in (0, 10] seconds')
    require(Path(args.socket).is_absolute(), 'socket must be an explicit absolute guest path')
    require(re.fullmatch(r'[A-Za-z0-9_]{12,128}', args.marker) is not None, 'marker must be synthetic alphanumeric text')
    require(len({args.incumbent_pid, args.shell_pid, args.child_pid}) == 3 and
            min(args.incumbent_pid, args.shell_pid, args.child_pid) > 1, 'supply distinct actual fixture PIDs')
    for value in [args.workspace_id, args.tab_id, args.second_tab_id]:
        uuid.UUID(value)
    require(args.tab_id.lower() != args.second_tab_id.lower(), 'two distinct fixture terminals are required')
    require(not args.evidence_dir.exists(), 'use a fresh evidence directory')
    args.evidence_dir.mkdir(parents=True)
    try:
        app, copy = bundle(args.app), bundle(args.copied_app)
        require(app['path'] != copy['path'] and not os.path.samefile(app['executable'], copy['executable']),
                'copied app must be a separate bundle, not a symlink/hardlink to incumbent executable')
        require(app['bundle_id'] == copy['bundle_id'] and app['sha256'] == copy['sha256'],
                'both supplied bundles must have the same ID and fixed main executable bytes')
        require(app['bundle_id'] != 'com.stage11.c11', 'use an isolated tagged/proof bundle ID, never production')
        processes = Processes()
        require(processes.executable(args.incumbent_pid) == app['executable'], 'PID does not belong to supplied incumbent')
        require(descendant(args.child_pid, args.shell_pid), 'heartbeat child is not descended from the fixture shell')
        require(descendant(args.shell_pid, args.incumbent_pid), 'fixture shell is not descended from incumbent')
        identities = {label: process_identity(pid) for label, pid in
                      [('incumbent', args.incumbent_pid), ('shell', args.shell_pid), ('child', args.child_pid)]}
        identities['incumbent_executable'] = app['executable']
        baseline = graph(args.socket)
        fixture_tabs = request(args.socket, 'panel.list', {'workspace_id': args.workspace_id}).get('panels', [])
        terminal_ids = {tab['id'].lower() for tab in fixture_tabs if tab.get('type') == 'terminal'}
        require({args.tab_id.lower(), args.second_tab_id.lower()} <= terminal_ids, 'fixture terminals missing')
        require(args.session_file.is_file(), 'outer runner must establish the saved session before this oracle')
        before = shell_probe(args, 'baseline')
        identities['baseline_proof_line'] = before['proof_line']
        base_socket = socket_identity(args.socket)
        save(args.evidence_dir / 'baseline.json', {'app': app, 'copy': copy, 'identities': identities,
                                                  'socket_identity': base_socket, 'graph': baseline, 'shell': before})
        results = [launch_duplicate(args, descriptor, phase, processes, baseline, identities, base_socket)
                   for descriptor, phase in [(app, 'same-bundle'), (copy, 'copied-bundle')]]
        save(args.evidence_dir / 'result.json', {'result': 'PASS', 'attempts': results,
              'limits': 'Supplied persistence paths unchanged; no process-attributed filesystem trace. '
                        'Quit, relaunch, coexistence, helper and signed-update gates are separate.'})
        print(json.dumps({'result': 'PASS', 'incumbent_pid': args.incumbent_pid,
                          'newcomer_pids': [result['newcomer_pid'] for result in results],
                          'evidence': str(args.evidence_dir / 'result.json')}))
    except Exception as error:
        save(args.evidence_dir / 'failure.json', {'result': 'FAIL', 'error': str(error)})
        raise


if __name__ == '__main__':
    main()
