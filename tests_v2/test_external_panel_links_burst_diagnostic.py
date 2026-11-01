#!/usr/bin/env python3
"""Focused C11-552 burst measurement, only through sandbox-tests-v2.sh.

The longer diagnostic socket timeout measures recovery; it does not replace
the acceptance harness's eight-second responsiveness requirement.
"""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time
import traceback
import uuid

import test_external_panel_links_native as outside

OUT = Path('/Volumes/My Shared Files/out/external-burst-diagnostic')
outside.OUT = outside.native.OUT = OUT


class Diagnostic(outside.Proof):
    def execute(self):
        self.precondition()
        self.seed()
        self.ui('activate')
        self.ensure_frontmost()
        before = self.selection()
        self.console_open(self.target_url)
        self.wait(self.prompt, 'one initial confirmation')
        self.report['timings'] = []
        probes = {'system.ping': [], 'system.identify': []}
        stop = threading.Event()

        def probe(method):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(20)
                connection.connect(self.socket_path)
                reader = connection.makefile('rb')
                sequence = 0
                while not stop.is_set():
                    sequence += 1
                    started = time.monotonic()
                    row = dict(start=round(started-self.started, 4))
                    try:
                        params = {'window_id': self.window} if method == 'system.identify' else {}
                        connection.sendall((json.dumps(dict(id=sequence, method=method, params=params))+'\n').encode())
                        reply = json.loads(reader.readline())
                        assert reply['id'] == sequence, reply
                        row.update(ok=reply.get('ok'), result=reply.get('result'), error=reply.get('error'))
                    except Exception as error:
                        row['error'] = repr(error)
                    row['seconds'] = round(time.monotonic()-started, 4)
                    probes[method].append(row)
                    if row.get('error'):
                        break
                    stop.wait(max(0, .2-(time.monotonic()-started)))

        def timed(label, action):
            started = time.monotonic()
            row = dict(label=label, start=round(started-self.started, 4))
            try:
                return action()
            finally:
                row['seconds'] = round(time.monotonic()-started, 4)
                self.report['timings'].append(row)

        workers = [threading.Thread(target=probe, args=(method,), daemon=True) for method in probes]
        for worker in workers:
            worker.start()
        sample = None
        sample_output = (OUT/'sample-command.log').open('w')
        try:
            time.sleep(1)
            marker = 'C11_552_BURST_' + uuid.uuid4().hex
            timed('native_type_before', lambda: self.native('t:'+marker))
            self.capture('01-before-flood')
            sample = subprocess.Popen(['/usr/bin/sample', str(self.pid), '5', '1', '-file', str(OUT/'sample.txt')],
                                      stdout=sample_output, stderr=subprocess.STDOUT)
            timed('open_50_return', lambda: self.console_open(*([self.workspace_url]*50)))
            timed('native_type_after', lambda: self.native('t:_AFTER'))
            self.sock.settimeout(20)
            selected = timed('original_connection_identify', self.selection)
            self.report['selection_unchanged'] = selected == before
            labels = timed('prompt_ax', self.ax)
            self.report['confirmation_count'] = len([x for x in labels if x['id'] == 'c11.external-link.confirmation'])
            text = timed('terminal_read', self.terminal_text)
            self.report['typed_marker_received'] = marker+'_AFTER' in text
            self.report['terminal_text'] = text
            self.capture('02-after-flood')
            time.sleep(1)
            timed('native_cancel', self.cancel)
            self.report['status'] = 'measured'
        finally:
            stop.set()
            for worker in workers:
                worker.join(timeout=21)
            self.report['probes'] = probes
            self.report['probe_threads_stopped'] = all(not w.is_alive() for w in workers)
            if sample is not None:
                try:
                    self.report['sample_exit'] = sample.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    sample.kill()
                    sample.wait(timeout=2)
                    self.report['sample_exit'] = 'terminated_after_timeout'
            sample_output.close()
            # These are this verified disposable guest's logs, never host logs.
            paths = [self.log, self.log.with_name(self.log.stem+'-hang.log'),
                     Path('/tmp')/('c11-sandbox-'+self.run_id+'.stdout'),
                     Path.home()/'Library/Logs/c11/hang.log']
            self.report['exported_logs'] = []
            for index, path in enumerate(paths):
                if path.is_file():
                    name = str(index)+'-'+path.name
                    shutil.copyfile(path, OUT/name)
                    self.report['exported_logs'].append(name)


if __name__ == '__main__':
    proof = Diagnostic()
    try:
        proof.execute()
        print('MEASURED C11-552 burst; inspect timings and sample, not acceptance PASS', flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=repr(error), traceback=traceback.format_exc())
        try:
            proof.capture('failure')
        except Exception:
            pass
        raise
    finally:
        proof.cleanup()
