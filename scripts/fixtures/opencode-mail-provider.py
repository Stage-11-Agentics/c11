"""Credential-free OpenAI-compatible provider for the OpenCode guest proof."""
import http.server
import json
import os
import pathlib
import sys
import threading
import time

root = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        users = [m for m in body.get('messages', []) if m.get('role') == 'user']
        text = str(users[-1].get('content', '')) if users else ''
        if 'BUSY-476' in text:
            time.sleep(8)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for delta, reason in [({'role': 'assistant', 'content': 'FIXTURE_ACK ' + text[-160:]}, None), ({}, 'stop')]:
                chunk = {'id': 'chatcmpl-fixture', 'object': 'chat.completion.chunk',
                         'created': int(time.time()), 'model': 'fixture',
                         'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}]}
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError):
            pass


# Port zero asks the kernel for a free port; this cannot take an occupied port.
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'provider-port').write_text(str(server.server_port))
threading.Timer(600, lambda: os._exit(0)).start()
server.serve_forever()
