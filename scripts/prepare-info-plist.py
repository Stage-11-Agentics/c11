#!/usr/bin/env python3
"""Prepare an app plist; only a production Release identity claims its panel-link URLs.

Used as an Xcode input-generation step and after Release-derived rebranding.
Other schemes and every unrelated plist value are preserved.
"""
import argparse
from pathlib import Path
import plistlib


# Each product's own panel-link scheme. The release build claims only its own; the
# retired line's scheme is never claimed, so its app keeps opening its old links.
PANEL_LINK_SCHEMES = {'com.stage11.c11': 'c11', 'com.stage11.c11h': 'c11h'}  # c11-2.0:keep


def prepare(source, destination, bundle_id=None, configuration='Release'):
    data = plistlib.loads(Path(source).read_bytes())
    identity = bundle_id if bundle_id is not None else data.get('CFBundleIdentifier')
    claimed = PANEL_LINK_SCHEMES.get(identity) if configuration == 'Release' else None
    unclaimed = set(PANEL_LINK_SCHEMES.values()) - {claimed}
    if unclaimed:
        entries = []
        for entry in data.get('CFBundleURLTypes', []):
            entry = dict(entry)
            schemes = [s for s in entry.get('CFBundleURLSchemes', []) if s.lower() not in unclaimed]
            if schemes:
                entry['CFBundleURLSchemes'] = schemes
                entries.append(entry)
        if entries:
            data['CFBundleURLTypes'] = entries
        else:
            data.pop('CFBundleURLTypes', None)
    encoded = plistlib.dumps(data, sort_keys=False)
    output = Path(destination)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_bytes() != encoded:
        output.write_bytes(encoded)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--bundle-id')
    parser.add_argument('--configuration', default='Release')
    args = parser.parse_args()
    prepare(args.source, args.destination, args.bundle_id, args.configuration)
