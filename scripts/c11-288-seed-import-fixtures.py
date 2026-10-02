#!/usr/bin/env python3
"""Create synthetic browser databases under /tmp; never read a browser profile.

Copy the generated Library tree only into an owned disposable sandbox's home.
--serve exposes a loopback cookie oracle without logging cookie values.
"""

import argparse
import http.cookies
import http.server
import json
from pathlib import Path
import sqlite3
import time


def create_database(path, schema, statement, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as database:
        database.executescript(schema)
        database.executemany(statement, rows)


def seed(root, port):
    root = root.resolve()
    if not root.is_relative_to(Path('/tmp').resolve()):
        raise ValueError('Fixture output must be under /tmp')
    root.mkdir(parents=True, exist_ok=False)
    url = f'http://127.0.0.1:{port}/c11-288'
    chromium_now = int((time.time() + 11_644_473_600) * 1_000_000)
    expiry = chromium_now + 86_400 * 1_000_000
    profiles = {}
    for browser, relative in [
        ('Google Chrome', 'Library/Application Support/Google/Chrome'),
        ('Arc', 'Library/Application Support/Arc'),
    ]:
        browser_root = root / relative
        profile = browser_root / 'Default'
        create_database(
            profile / 'History',
            'CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);',
            'INSERT INTO urls VALUES (?, ?, ?, ?)',
            [(url, 'c11-288-synthetic', 1, chromium_now)],
        )
        rows = [('127.0.0.1', 'c11_288', 'synthetic', '/', expiry, 0, b'')]
        if browser == 'Google Chrome':
            rows.append(('127.0.0.1', 'c11_288_encrypted', '', '/', expiry, 0, b'v10' + bytes(16)))
        create_database(
            profile / 'Cookies',
            'CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, path TEXT, '
            'expires_utc INTEGER, is_secure INTEGER, encrypted_value BLOB);',
            'INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)',
            rows,
        )
        (browser_root / 'Local State').write_text(json.dumps({
            'profile': {'info_cache': {'Default': {'name': f'c11-288-{browser.lower().replace(" ", "-")}'}}}
        }))
        profiles[browser] = {'relativeProfile': str(profile.relative_to(root)), 'historyRows': 1,
                             'plaintextCookieRows': 1, 'encryptedCookieRows': len(rows) - 1}
    safari = root / 'Library/Safari/History.db'
    create_database(
        safari,
        'CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, title TEXT);'
        'CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL);',
        'INSERT INTO history_items VALUES (?, ?, ?)',
        [(1, url, 'c11-288-synthetic')],
    )
    with sqlite3.connect(safari) as database:
        database.execute('INSERT INTO history_visits VALUES (?, ?, ?)', (1, 1, time.time() - 978_307_200))
    profiles['Safari'] = {'relativeProfile': 'Library/Safari', 'historyRows': 1,
                          'cookieCoverage': 'unsupported'}
    summary = {'fixtureRoot': str(root), 'url': url, 'profiles': profiles,
               'coverage': 'synthetic schemas; no actual Chromium installation or encrypted-cookie success'}
    (root / 'manifest.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


class CookieOracle(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/c11-288':
            self.send_error(404)
            return
        cookies = http.cookies.SimpleCookie()
        cookies.load(self.headers.get('Cookie', ''))
        signed_in = 'c11_288' in cookies and cookies['c11_288'].value == 'synthetic'
        body = ('<!doctype html><title>C11-288 cookie isolation</title>'
                '<h1>C11-288 synthetic cookie oracle</h1><p>'
                + ('SIGNED IN' if signed_in else 'SIGNED OUT') + '</p>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(json.dumps({'path': self.path, 'signedIn': signed_in}), flush=True)

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('/tmp/c11-288-fixtures'))
    parser.add_argument('--port', type=int, default=19288)
    parser.add_argument('--serve', action='store_true')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('--port must be between 1024 and 65535')
    if args.serve:
        http.server.HTTPServer(('127.0.0.1', args.port), CookieOracle).serve_forever()
    else:
        seed(args.output, args.port)


if __name__ == '__main__':
    main()
