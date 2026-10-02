#!/usr/bin/env python3
"""Validate signing requests, prepare built plists, and bind staged asset bytes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

PROOF_BUNDLE = "com.stage11.c11.sparkle307"
PRODUCTION_FEED = "https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml"
ASSETS = (
    "c11-macos.dmg", "appcast.xml", "c11d-remote-darwin-arm64",
    "c11d-remote-darwin-amd64", "c11d-remote-linux-arm64",
    "c11d-remote-linux-amd64", "c11d-remote-checksums.txt", "c11d-remote-manifest.json",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).rstrip()


def request(root):
    e = os.environ
    sha = e.get("SIGN_EXPECTED_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "expected_sha must be a full lowercase SHA")
    require(git(root, "rev-parse", "HEAD") == sha, "named source ref does not match expected_sha")
    require(e.get("SIGN_SOURCE_REF"), "source_ref is required")
    require(re.fullmatch(r"[0-9a-f]{40}", e.get("SIGN_WORKFLOW_SHA", "")), "workflow SHA is required")
    purpose = e.get("SIGN_PURPOSE")
    require(purpose in ("proof", "candidate"), "purpose must be proof or candidate")
    tag = e.get("SIGN_TARGET_TAG", "")
    base = e.get("SIGN_PROOF_FEED_BASE", "")
    build = e.get("SIGN_PROOF_BUILD", "")
    if purpose == "proof":
        require(not tag, "proof must not name a production release tag")
        require(re.fullmatch(r"[1-9][0-9]*", build), "proof_build must be a positive integer")
        url = urlsplit(base)
        require(url.scheme in ("http", "https") and url.hostname and not url.username
                and not url.password and not url.query and not url.fragment
                and not base.endswith("/") and not any(c.isspace() for c in base),
                "proof_feed_base must be an HTTP(S) directory without credentials or trailing slash")
        require(url.hostname not in ("github.com", "api.github.com", "objects.githubusercontent.com")
                and not url.hostname.endswith(".githubusercontent.com"),
                "proof feed must be isolated from GitHub production and artifact archives")
    else:
        require(not base and not build, "candidate must not contain proof overrides")
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "candidate target_tag must be vX.Y.Z")
    submodules = git(root, "submodule", "status", "--recursive").splitlines()
    require(all(line.startswith(" ") for line in submodules), "submodules must match recorded source pins")
    return {"purpose": purpose, "sourceRef": e["SIGN_SOURCE_REF"], "sourceSHA": sha,
            "workflowSHA": e["SIGN_WORKFLOW_SHA"], "runURL": e.get("SIGN_RUN_URL", ""),
            "runID": e.get("GITHUB_RUN_ID", ""), "runAttempt": e.get("GITHUB_RUN_ATTEMPT", ""),
            "submodules": submodules, "targetTag": tag, "proofBuild": build, "proofFeedBase": base}


def configure(root):
    identity = request(root)
    path = root / "build/Build/Products/Release/c11.app/Contents/Info.plist"
    with path.open("rb") as f:
        plist = plistlib.load(f)
    version = plist["CFBundleShortVersionString"]
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "built version must be X.Y.Z")
    require(os.environ.get("SPARKLE_PUBLIC_KEY"), "derived Sparkle public key is required")
    if identity["purpose"] == "candidate":
        require(identity["targetTag"] == "v" + version, "candidate version must match target_tag")
        require(plist["CFBundleIdentifier"] == "com.stage11.c11", "candidate must use production bundle")
        feed = PRODUCTION_FEED
        download = f'https://github.com/Stage-11-Agentics/c11/releases/download/{identity["targetTag"]}'
        notes = f'https://github.com/Stage-11-Agentics/c11/releases/tag/{identity["targetTag"]}'
    else:
        plist["CFBundleIdentifier"] = PROOF_BUNDLE
        plist["CFBundleVersion"] = identity["proofBuild"]
        # Local HTTP updater fixtures need URLSession access, beyond the normal
        # WebKit-only ATS exception. This override exists only in the proof app.
        plist["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
        feed = identity["proofFeedBase"] + "/appcast.xml"
        download = identity["proofFeedBase"]
        notes = download + "/notes.html"
        identity["targetTag"] = "proof-" + identity["proofBuild"]
    plist["SUFeedURL"] = feed
    plist["SUPublicEDKey"] = os.environ["SPARKLE_PUBLIC_KEY"]
    daemon = json.loads((root / "build/remote-daemon-assets/c11d-remote-manifest.json").read_text())
    require(daemon["appVersion"] == version, "daemon version must match app")
    require(daemon["releaseTag"] == identity["targetTag"], "daemon release tag must match artifact")
    if identity["purpose"] == "proof":
        # Proof daemons, like the appcast, use the fixture feed instead of nonexistent releases.
        daemon["releaseURL"] = download
        daemon["checksumsURL"] = download + "/c11d-remote-checksums.txt"
        for entry in daemon["entries"]:
            entry["downloadURL"] = download + "/" + entry["assetName"]
        (root / "build/remote-daemon-assets/c11d-remote-manifest.json").write_text(
            json.dumps(daemon, indent=2, sort_keys=True) + "\n")
    packed = json.dumps(daemon, separators=(",", ":"))
    plist["C11RemoteDaemonManifestJSON"] = packed
    plist["CMUXRemoteDaemonManifestJSON"] = packed
    with path.open("wb") as f:
        plistlib.dump(plist, f)
    identity.update(version=version, build=str(plist["CFBundleVersion"]),
                    bundleID=plist["CFBundleIdentifier"], feedURL=feed,
                    downloadURLPrefix=download + "/", releaseNotesURL=notes)
    (root / "build/signing-request.json").write_text(json.dumps(identity, indent=2) + "\n")


def digest(path):
    with path.open("rb") as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def asset_hashes(directory):
    require({p.name for p in directory.iterdir()} <= set(ASSETS) | {"SHA256SUMS", "signing-manifest.json"},
            "unexpected file in artifact upload directory")
    for name in ASSETS:
        p = directory / name
        require(p.is_file() and not p.is_symlink() and p.stat().st_size > 0, "missing or invalid asset: " + name)
    return {name: digest(directory / name) for name in ASSETS}


def package(root):
    directory = root / "build/signed-artifact"
    hashes = asset_hashes(directory)
    identity = json.loads((root / "build/signing-request.json").read_text())
    require(request(root)["sourceSHA"] == identity["sourceSHA"], "source identity changed")
    xml = ET.parse(directory / "appcast.xml")
    enclosures = xml.findall("./channel/item/enclosure")
    require(len(enclosures) == 1, "appcast must describe exactly this one DMG")
    enc = enclosures[0]
    require(enc.get("url") == identity["downloadURLPrefix"] + "c11-macos.dmg", "appcast download URL mismatch")
    require(enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"), "missing Sparkle signature")
    require(enc.get("length") == str((directory / "c11-macos.dmg").stat().st_size), "appcast length mismatch")
    require(xml.findtext("./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version") == identity["build"],
            "appcast build number mismatch")
    daemon = json.loads((directory / "c11d-remote-manifest.json").read_text())
    require(len(daemon["entries"]) == 4, "daemon manifest requires four binaries")
    for entry in daemon["entries"]:
        require(entry["sha256"] == hashes.get(entry["assetName"]), "daemon asset hash mismatch")
    expected_checksums = {name: hashes[name] for name in ASSETS if name.startswith("c11d-remote-")
                          and name not in ("c11d-remote-checksums.txt", "c11d-remote-manifest.json")}
    actual_checksums = {line.split()[1]: line.split()[0] for line in
                        (directory / "c11d-remote-checksums.txt").read_text().splitlines()}
    require(actual_checksums == expected_checksums, "daemon checksums mismatch")
    identity.update(schemaVersion=1, assets=hashes, validation={"appNotarization": "Accepted",
        "dmgNotarization": "Accepted", "appStapler": "passed", "dmgStapler": "passed",
        "codesign": "passed", "gatekeeperApp": "passed"},
        toolchain={name: subprocess.check_output(cmd, text=True).strip() for name, cmd in
                   (("xcode", ["xcodebuild", "-version"]), ("zig", ["zig", "version"]),
                    ("go", ["go", "version"]))})
    manifest = directory / "signing-manifest.json"
    manifest.write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")
    hashes[manifest.name] = digest(manifest)
    (directory / "SHA256SUMS").write_text("".join(f"{sha}  {name}\n" for name, sha in sorted(hashes.items())))
    artifact = f'c11-signed-{identity["purpose"]}-{identity["sourceSHA"][:12]}-{identity["runID"]}-{identity["runAttempt"]}'
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as f:
            f.write("SIGN_ARTIFACT_NAME=" + artifact + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(f'## {artifact}\n\nSource `{identity["sourceSHA"]}`; workflow `{identity["workflowSHA"]}`.\n\n'
                    'App and DMG notarized and stapled; app codesign and Gatekeeper passed.\n\n'
                    + "```text\n" + (directory / "SHA256SUMS").read_text() + "```\n")


def verify(directory):
    manifest = json.loads((directory / "signing-manifest.json").read_text())
    require(asset_hashes(directory) == manifest["assets"], "artifact asset hash mismatch")
    expected = dict(manifest["assets"], **{"signing-manifest.json": digest(directory / "signing-manifest.json")})
    actual = {line.split()[1]: line.split()[0] for line in (directory / "SHA256SUMS").read_text().splitlines()}
    require(actual == expected, "SHA256SUMS mismatch")
    print("Verified all eight assets and signing manifest")


if __name__ == "__main__":
    try:
        command, path = sys.argv[1:]
        root = Path(path).resolve()
        {"preflight": request, "configure": configure, "package": package, "verify": verify}[command](root)
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"sign-artifact: {error}")
