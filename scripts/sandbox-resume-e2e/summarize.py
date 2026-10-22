#!/usr/bin/env python3
"""Summarize collect output saved from run.sh: resumed count, startup audit
timings, and every panel that did not resume. Usage: summarize.py <file>..."""
import json, sys
for f in sys.argv[1:]:
    text = open(f).read()
    head, _, body = text.partition("\n{\n")
    d = json.loads("{\n" + body) if body else json.loads(text[text.index("{"):])
    print(f.split('/')[-1], head.strip().replace("\n", " | "))
    print('  resumed', d['resumed_on_screen'], '/', d['panels'], 'mode', d['mode'])
    print('  audit', json.dumps(d['startup_audit']))
    for r in d['rows']:
        if not r['resumed_on_screen']:
            print('   not resumed:', r['name'], r['decision'], r['skip_code'], r['reason'], r['ts'])
