#!/usr/bin/env python3
"""Print the Swift files the Xcode `c11-cli` target compiles, one repo-relative path per line.

The Linux build (build.sh) compiles exactly this list, so the Linux `c11` is the same CLI as the macOS one.
Regenerate sources.txt after the target's membership changes: tools/linux-cli/gen-sources.py > tools/linux-cli/sources.txt
"""
import os, re, sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
s = open(os.path.join(root, "GhosttyTabs.xcodeproj", "project.pbxproj")).read()
target = re.search(r'([A-Z0-9]{24,32}) /\* c11-cli \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};', s, re.S).group(2)
phase = re.search(r'([A-Z0-9]{24,32}) /\* Sources \*/', re.search(r'buildPhases = \((.*?)\);', target, re.S).group(1)).group(1)
files = re.search(phase + r' /\* Sources \*/ = \{.*?files = \((.*?)\);', s, re.S).group(1)
build_files = dict(re.findall(r'([A-Z0-9]{24,32}) /\* [^*]+ in \w+ \*/ = \{isa = PBXBuildFile; fileRef = ([A-Z0-9]{24,32})', s))
names = {}
for fid, name, body in re.findall(r'([A-Z0-9]{24,32}) /\* ([^*]+) \*/ = \{isa = PBXFileReference;([^}]*)\}', s):
    m = re.search(r'path = ("[^"]*"|[^;]*);', body)
    names[fid] = (m.group(1).strip('"') if m else name)
out = []
for bid in re.findall(r'([A-Z0-9]{24,32}) /\* [^*]+ in Sources \*/', files):
    rel = names[build_files[bid]]
    if os.path.isfile(os.path.join(root, rel)):
        out.append(rel); continue
    hits = [os.path.relpath(os.path.join(d, f), root) for top in ("CLI", "Sources") for d, _, fs in os.walk(os.path.join(root, top))
            for f in fs if os.path.join(d, f).endswith("/" + rel)]
    if len(hits) != 1:
        sys.exit(f"gen-sources: {rel} resolves to {hits}")
    out.append(hits[0])
print("\n".join(out))
