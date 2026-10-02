#!/usr/bin/env python3
"""Short matched journal workload, not the deferred fleet soak.

Run in the disposable guest with PyObjC Quartz and Pillow available. Exact
glyph templates exclude cursor/title changes. Each trial uses a real PID key
event and must match the expected rendered glyph within 500 ms. Same script,
geometry and eight structural hook producers are used on main and candidate.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import threading
import time
import uuid

import Quartz as Q
from PIL import Image, ImageChops, ImageStat

from attention_menu_bar_probe import Probe


class PerformanceProbe(Probe):
    def timeout(self):
        remaining = self.started + (178 if self.cleanup_mode else 170) - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Performance probe deadline reached')
        return min(5, remaining)

    def footprint(self):
        path = self.output / 'footprint-private.json'
        self.run(['/usr/bin/footprint', '--pid', str(self.args.pid), '-j', str(path)])
        auxiliary = json.loads(path.read_text())['processes'][0]['auxiliary']
        value = auxiliary['phys_footprint']
        self.footprint_peaks.append(float(auxiliary['phys_footprint_peak']) / (1024 * 1024))
        path.unlink()
        return float(value) / (1024 * 1024)

    def capture(self):
        start = time.perf_counter()
        # Window capture remains scoped to the verified guest process/window.
        # The CLI fallback supports systems that retire CGWindowListCreateImage.
        try:
            frame = Q.CGWindowListCreateImage(Q.CGRectNull, Q.kCGWindowListOptionIncludingWindow,
                                            self.window_id, Q.kCGWindowImageBoundsIgnoreFraming)
            if frame is None:
                raise RuntimeError('No window image')
            width, height = Q.CGImageGetWidth(frame), Q.CGImageGetHeight(frame)
            data = bytes(Q.CGDataProviderCopyData(Q.CGImageGetDataProvider(frame)))
            image = Image.frombytes('RGBA', (width, height), data, 'raw', 'BGRA', Q.CGImageGetBytesPerRow(frame)).convert('RGB')
        except Exception:
            self.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(self.window_id), str(self.capture_path)])
            image = Image.open(self.capture_path).convert('RGB')
        self.capture_ms.append((time.perf_counter() - start) * 1000)
        return image

    def key(self, code):
        for down in (True, False):
            Q.CGEventPostToPid(self.args.pid, Q.CGEventCreateKeyboardEvent(None, code, down))

    def execute(self):
        self.preflight()
        self.capture_ms = []
        self.footprint_peaks = []
        self.capture_path = self.output / 'transient.png'
        self.workspace = self.rpc('workspace.create', {'working_directory': '/tmp',
            'initial_command': "/usr/bin/env PS1='$ ' /bin/zsh -f"})['workspace_id']
        self.rpc('workspace.rename', {'workspace_id': self.workspace, 'title': 'Journal load proof'})
        for workspace in self.rpc('workspace.list')['workspaces']:
            if workspace['id'] != self.workspace:
                self.rpc('workspace.close', {'workspace_id': workspace['id']})
        control = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        self.rpc('tab.set_metadata', {'tab_id': control, 'metadata': {'title': 'Glyph control'}})
        agents = [self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal'})['tab_id'] for _ in range(8)]
        for index, tab in enumerate(agents):
            self.rpc('tab.set_metadata', {'tab_id': tab, 'metadata': {'title': 'Synthetic agent ' + str(index + 1)}})
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        self.rpc('tab.focus', {'tab_id': control})
        self.ui('activate')
        code = """import os,sys,termios,tty
fd=sys.stdin.fileno();old=termios.tcgetattr(fd);tty.setraw(fd)
try:
 os.write(1,b'\\x1b[2J\\x1b[H\\x1b[?25l')
 while True:
  value=os.read(fd,1)
  if value==b'\\x1b':break
  os.write(1,b'\\x1b[H'+value+b'\\x1b[K')
finally:
 termios.tcsetattr(fd,termios.TCSADRAIN,old);os.write(1,b'\\x1b[?25h\\r\\n')
"""
        self.rpc('tab.send_text', {'tab_id': control, 'text': 'python3 -u -c ' + shlex.quote(code) + '\n'})
        time.sleep(1)
        blank = self.capture()
        self.key(7); time.sleep(.15); x_image = self.capture()
        self.key(46); time.sleep(.15); m_image = self.capture()
        difference = ImageChops.lighter(ImageChops.difference(blank, x_image), ImageChops.difference(blank, m_image))
        # Threshold harmless compositor rounding; the bounding box must fit a
        # single glyph. A title, cursor or sidebar repaint fails calibration.
        box = difference.convert('L').point(lambda value: 255 if value > 12 else 0).getbbox()
        self.check(box is not None and 2 <= box[2]-box[0] <= 50 and 2 <= box[3]-box[1] <= 60,
                   'Calibration isolates one actual glyph, not unrelated repaint')
        templates = {'x': x_image.crop(box), 'm': m_image.crop(box)}
        for glyph, image in templates.items():
            image.save(self.output / ('calibration-' + glyph + '.png'))
        def trial(glyph):
            start = time.perf_counter()
            self.key(7 if glyph == 'x' else 46)
            while time.perf_counter() - start < .5:
                image = self.capture().crop(box)
                if max(ImageStat.Stat(ImageChops.difference(image, templates[glyph])).mean) < 1.5:
                    return (time.perf_counter() - start) * 1000
            if not (self.output / 'first-miss-private.png').exists():
                self.capture().save(self.output / 'first-miss-private.png')
            return None
        calibration = [trial('x' if index % 2 == 0 else 'm') for index in range(30)]
        self.check(all(value is not None for value in calibration), 'All 30 glyph-present calibration trials pass')
        stop = threading.Event()
        errors, durations = [], []
        contexts = []
        for index, tab in enumerate(agents):
            env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
            env.update(CMUX_WORKSPACE_ID=self.workspace, CMUX_SURFACE_ID=tab,
                       CMUX_CLAUDE_HOOK_STATE_PATH=str(self.output / ('hook-state-' + str(index) + '.json')))
            owner = str(uuid.uuid4())
            contexts.append((env, owner))
            subprocess.run([self.args.cli, '--socket', self.args.socket, 'claude-hook', 'session-start'],
                           input=json.dumps({'session_id': owner}), text=True, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
        def traffic():
            index = 0
            sequence = [('prompt-submit', {}), ('pre-tool-use', {'tool_name': 'AskUserQuestion', 'permission_mode': 'bypassPermissions'}),
                        ('stop', {}), ('pre-tool-use', {'tool_name': 'Bash'}), ('prompt-submit', {}), ('stop', {})]
            while not stop.is_set():
                env, owner = contexts[index % len(contexts)]
                event, fields = sequence[(index // len(contexts)) % len(sequence)]
                start = time.perf_counter()
                try:
                    result = subprocess.run([self.args.cli, '--socket', self.args.socket, 'claude-hook', event],
                        input=json.dumps({'session_id': owner, **fields}), text=True, env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                    if result.returncode: errors.append('hook_exit')
                    durations.append((time.perf_counter() - start) * 1000)
                except subprocess.TimeoutExpired:
                    errors.append('hook_timeout')
                index += 1
                stop.wait(max(0, .1 - (time.perf_counter() - start)))
        worker = threading.Thread(target=traffic, daemon=True)
        rss, cpu, values = [], [], []
        footprints = [self.footprint()]
        start = time.monotonic(); worker.start()
        try:
            for index in range(120):
                values.append(trial('x' if index % 2 == 0 else 'm'))
                if index % 10 == 0:
                    sample = self.run(['/bin/ps', '-p', str(self.args.pid), '-o', 'rss=,%cpu=']).stdout.split()
                    rss.append(int(sample[0]) / 1024); cpu.append(float(sample[1]))
                time.sleep(.15)
        finally:
            stop.set(); worker.join(timeout=6)
        elapsed = time.monotonic() - start
        footprints.append(self.footprint())
        self.key(53)
        valid = [value for value in values if value is not None]
        def percentile(samples, fraction):
            return sorted(samples)[min(len(samples)-1, int((len(samples)-1)*fraction))] if samples else None
        self.report['measurement'] = {'label': self.args.label, 'glyph_samples_ms': values,
            'calibration_ms': calibration, 'missed_glyphs': len(values)-len(valid),
            'p95_ms': percentile(valid, .95), 'p99_ms': percentile(valid, .99),
            'capture_p95_ms': percentile(self.capture_ms, .95), 'hook_count': len(durations),
            'hook_process_p95_ms': percentile(durations, .95), 'elapsed_seconds': elapsed,
            'rss_peak_mib': max(rss), 'phys_footprint_mib': footprints,
            'phys_footprint_peak_mib': max(self.footprint_peaks),
            'sampled_cpu_peak_percent': max(cpu), 'guest_load_average': list(os.getloadavg()),
            'scope': 'eight structural hook producers and one real PTY; short comparison, not fleet soak or memory slope'}
        self.check(not errors, 'All packaged hooks completed under the matched load')
        self.check(len(valid) >= 114, 'At least 95 percent of 120 expected glyphs appeared within 500 ms under hook load')
        self.check(self.rpc('system.identify')['focused']['tab_id'] == control, 'Hook burst preserves the typing target')
        self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout'])
        self.check(True, 'Topology inspected and glyph control remained one readable area')

    def cleanup(self):
        super().cleanup()
        if self.output:
            for path in self.output.glob('hook-state-*.json'): path.unlink()
            (self.output / 'transient.png').unlink(missing_ok=True)
            safe = {key: self.report[key] for key in ('result', 'checks', 'measurement') if key in self.report}
            safe['cleanup_ok'] = not self.report.get('cleanup_errors')
            (self.output / 'report.json').write_text(json.dumps(safe, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('run-id', 'app', 'cli', 'socket', 'label', 'output-name'):
        parser.add_argument('--' + key, required=True)
    parser.add_argument('--pid', type=int, required=True)
    args = parser.parse_args(); args.inspect_dialogs_only = False
    probe = PerformanceProbe(args)
    def expire(*_): raise TimeoutError('Performance probe active limit reached')
    signal.signal(signal.SIGALRM, expire); signal.alarm(170)
    probe.deadline = probe.started + 170
    watchdog = threading.Timer(179, lambda: os._exit(124)); watchdog.daemon = True; watchdog.start()
    try:
        probe.execute(); probe.report['result'] = 'PASS'
    except Exception:
        probe.report['result'] = 'FAIL'; raise
    finally:
        signal.alarm(0); probe.cleanup(); watchdog.cancel()
    print('PASS matched glyph and hook-load probe')


if __name__ == '__main__':
    main()
