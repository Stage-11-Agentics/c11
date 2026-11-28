#!/usr/bin/env python3
"""Fake platform tools for tests/test_release_local_stage.py.

Every tool scripts/release-local.sh reaches outside the shell (gh, codesign,
xcrun, security, npx, swift, the Sparkle and daemon helper scripts, ...) is a
small wrapper that calls main(<tool name>). Each call is appended to
$RELEASE_STUB_STATE/calls.jsonl, then answered from state files in that folder.
Nothing here touches the network, a keychain or GitHub; git is passed through
to the real binary (RELEASE_STUB_REAL_GIT) after it is logged.
"""
import json
import os
import re
import sys
from pathlib import Path

# hashlib, base64, plistlib and subprocess load only where a tool needs them:
# each fake tool is a fresh process, so its startup is most of a run's time.

STATE = Path(os.environ["RELEASE_STUB_STATE"])
IDENTITY = "Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)"
SPARKLE_KEY = "c3R1Yi1zcGFya2xlLXByaXZhdGUta2V5LW5vdC1yZWFsLTA="
SENTRY_TOKEN = "stub-sentry-token-not-real"
TICKET = b"\nSTUB-NOTARIZATION-TICKET\n"
LOGGED_ENV = (
    "SPARKLE_PRIVATE_KEY_FILE",
    "SPARKLE_BIN_DIR",
    "DOWNLOAD_URL_PREFIX",
    "RELEASE_NOTES_URL",
    "SENTRY_ORG",
    "SENTRY_PROJECT",
    "SENTRY_AUTH_TOKEN",
    "C11_CLI_BIN",
    "CMUX_CLI_BIN",
)


def log(tool, argv):
    entry = {
        "tool": tool,
        "argv": argv,
        "cwd": os.getcwd(),
        "env": {key: os.environ[key] for key in LOGGED_ENV if key in os.environ},
    }
    fd = os.open(STATE / "calls.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (json.dumps(entry) + "\n").encode())
    finally:
        os.close(fd)


def load(name, default):
    path = STATE / name
    return json.loads(path.read_text()) if path.exists() else default


def save(name, value):
    (STATE / name).write_text(json.dumps(value, indent=1))


def sha256(path):
    import hashlib

    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fail(message, code=1):
    print(f"stub: {message}", file=sys.stderr)
    return code


def option(argv, *names):
    for index, arg in enumerate(argv):
        if arg in names and index + 1 < len(argv):
            return argv[index + 1]
        for name in names:
            if name.startswith("--") and arg.startswith(name + "="):
                return arg.split("=", 1)[1]
    return None


def stapled(path):
    path = Path(path)
    if path.is_dir():
        return (path / "Contents" / "CodeResources").exists()
    return path.is_file() and path.read_bytes().endswith(TICKET)


# ------------------------------------------------------------------- gh --
def gh_jq(data, expr):
    if expr is None:
        print(json.dumps(data))
        return 0
    import subprocess

    proc = subprocess.run(["jq", "-r", "-c", expr], input=json.dumps(data), text=True, capture_output=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    return proc.returncode


def gh_asset(path):
    path = Path(path)
    return {"name": path.name, "size": path.stat().st_size, "state": "uploaded",
            "digest": "sha256:" + sha256(path)}


def gh_positionals(argv, valued, flags):
    out, index = [], 0
    while index < len(argv):
        arg = argv[index]
        if arg in valued:
            index += 2
            continue
        if arg in flags or (arg.startswith("--") and "=" in arg):
            index += 1
            continue
        out.append(arg)
        index += 1
    return out


def gh(argv):
    state = load("gh.json", {"releases": [], "latest": None, "next_id": 1000, "fail": []})
    if argv[:2] == ["auth", "status"]:
        return 0
    if argv[:1] == ["api"]:
        rest = argv[1:]
        method = (option(rest, "-X", "--method") or "GET").upper()
        expr = option(rest, "--jq", "-q")
        fields = {}
        for index, arg in enumerate(rest):
            if arg in ("-f", "-F", "--field", "--raw-field") and index + 1 < len(rest):
                key, _, value = rest[index + 1].partition("=")
                fields[key] = value
        endpoint = gh_positionals(rest, {"-X", "--method", "--jq", "-q", "-f", "-F", "--field", "--raw-field"},
                                  {"--paginate"})[0]
        match = re.fullmatch(r"repos/[^/]+/[^/]+/releases(?:\?.*|/(latest|\d+))?", endpoint)
        if not match:
            return fail(f"gh api: unhandled endpoint {endpoint}", 64)
        which = match.group(1)
        if which is None:
            if "releases-list" in state["fail"]:
                return fail("gh: Server Error (HTTP 500)")
            return gh_jq(state["releases"], expr)
        if which == "latest":
            found = [r for r in state["releases"] if r["tag_name"] == state["latest"]]
            if not found:
                print("gh: Not Found (HTTP 404)", file=sys.stderr)
                return 1
            return gh_jq(found[0], expr)
        found = [r for r in state["releases"] if str(r["id"]) == which]
        if not found:
            print("gh: Not Found (HTTP 404)", file=sys.stderr)
            return 1
        release = found[0]
        if method == "PATCH":
            if "draft" in fields:
                release["draft"] = fields["draft"] == "true"
            if fields.get("make_latest") == "true" and not release["draft"]:
                state["latest"] = release["tag_name"]
            save("gh.json", state)
        elif method != "GET":
            return fail(f"gh api: unhandled method {method}", 64)
        return gh_jq(release, expr)
    if argv[:2] == ["run", "list"]:
        return gh_jq(state.get("runs", []), option(argv, "--jq", "-q"))
    if argv[:2] == ["workflow", "run"]:
        return 0
    if argv[:1] == ["release"] and len(argv) > 2:
        verb, tag = argv[1], argv[2]
        files = gh_positionals(argv[3:], {"--repo", "-R", "--title", "-t", "--notes-file", "-F", "--notes", "-n",
                                          "--target"}, {"--verify-tag", "--draft", "-d", "--prerelease", "--latest"})
        if verb == "create":
            if any(r["tag_name"] == tag for r in state["releases"]):
                return fail(f"release {tag} already exists")
            state["releases"].append({"id": state["next_id"], "tag_name": tag, "draft": "--draft" in argv,
                                      "prerelease": False, "assets": [gh_asset(f) for f in files]})
            state["next_id"] += 1
        elif verb in ("edit", "upload"):
            found = [r for r in state["releases"] if r["tag_name"] == tag]
            if not found:
                return fail(f"release {tag} not found")
            if verb == "upload":
                names = {a["name"] for a in found[0]["assets"]}
                if any(Path(f).name in names for f in files):
                    return fail("asset exists (no --clobber)")
                found[0]["assets"].extend(gh_asset(f) for f in files)
        else:
            return fail(f"gh release {verb}: unhandled", 64)
        save("gh.json", state)
        return 0
    return fail(f"gh: unhandled {argv}", 64)


# ------------------------------------------------------- signing tools --
def codesign(argv):
    signed = load("codesign.json", {})
    if "--remove-signature" in argv:
        return 0 if Path(argv[-1]).is_file() else fail("no such file")
    if "--sign" in argv:
        target = os.path.realpath(argv[-1])
        if not os.path.exists(target):
            return fail("no such file")
        signed[target] = option(argv, "--identifier") or Path(target).name
        save("codesign.json", signed)
        return 0
    if "-dv" in argv:
        target = os.path.realpath(argv[-1])
        print(f"Executable={target}\nIdentifier={signed.get(target, Path(target).name)}\nFormat=stub",
              file=sys.stderr)
        return 0
    if "--verify" in argv:
        return 0 if os.path.exists(argv[-1]) else fail("no such file")
    return fail(f"codesign: unhandled {argv}", 64)


def xcrun(argv):
    if argv[:2] == ["notarytool", "history"] or argv[:2] == ["notarytool", "log"]:
        return 0
    if argv[:2] == ["notarytool", "submit"]:
        path = Path(argv[2])
        print(json.dumps({"id": f"stub-submission-{path.name}",
                          "status": "Accepted" if path.is_file() else "Invalid"}))
        return 0
    if argv[:2] == ["stapler", "staple"]:
        path = Path(argv[2])
        if path.is_dir():
            (path / "Contents" / "CodeResources").write_bytes(TICKET)
        elif path.is_file():
            with path.open("ab") as handle:
                handle.write(TICKET)
        else:
            return fail("no such file", 65)
        return 0
    if argv[:2] == ["stapler", "validate"]:
        if stapled(argv[2]):
            print("The validate action worked!")
            return 0
        return fail(f"{argv[2]} does not have a ticket stapled to it", 65)
    return fail(f"xcrun: unhandled {argv}", 64)


def spctl(argv):
    target = argv[-1]
    if stapled(target):
        print(f"{target}: accepted\nsource=Notarized Developer ID", file=sys.stderr)
        return 0
    print(f"{target}: rejected\nsource=Unnotarized Developer ID", file=sys.stderr)
    return 3


def security(argv):
    if argv[:1] == ["find-identity"]:
        print(f'  1) 0123456789ABCDEF0123456789ABCDEF01234567 "{IDENTITY}"\n     1 valid identities found')
        return 0
    if argv[:1] == ["find-generic-password"]:
        service = option(argv, "-s")
        if service == "c11-sentry-auth-token":
            print(SENTRY_TOKEN)
            return 0
        if service == "https://sparkle-project.org":
            print(SPARKLE_KEY)
            return 0
        return fail("The specified item could not be found in the keychain.", 44)
    return fail(f"security: unhandled {argv}", 64)


# ------------------------------------------------------ build helpers --
def app_info(app):
    import plistlib

    with (Path(app) / "Contents" / "Info.plist").open("rb") as handle:
        return plistlib.load(handle)


def npx(argv):
    if not any(arg.startswith("create-dmg@") for arg in argv):
        return fail(f"npx: unhandled {argv}", 64)
    app, dest = Path(argv[-2]), Path(argv[-1])
    info = app_info(app)
    digest = sha256(app / "Contents" / "Info.plist")
    body = (f"STUB-DMG version={info['CFBundleShortVersionString']} build={info['CFBundleVersion']} "
            f"stapled-app={stapled(app)} info={digest}\n")
    (dest / f"c11 {info['CFBundleShortVersionString']}.dmg").write_text(body)
    return 0


def swift(argv):
    script = Path(argv[0]).name
    if script == "derive_sparkle_public_key.swift":
        print("STUB-THROWAWAY-PUBLIC-KEY=")
        return 0
    if script != "verify_sparkle_appcast.swift":
        return fail(f"swift: unhandled {argv}", 64)
    appcast, archive, _public_key, expected_url = argv[1:5]
    text = Path(appcast).read_text()

    def attr(name):
        found = re.search(rf'{re.escape(name)}="([^"]*)"', text)
        return found.group(1) if found else ""

    if not attr("sparkle:edSignature"):
        return fail("enclosure has no sparkle:edSignature")
    if int(attr("length")) != Path(archive).stat().st_size:
        return fail("enclosure length != archive size")
    if attr("url") != expected_url:
        return fail(f"enclosure url {attr('url')} != expected {expected_url}")
    print(json.dumps({"length": int(attr("length")), "shortVersionString": attr("sparkle:shortVersionString"),
                      "signature": "valid", "url": attr("url"), "version": attr("sparkle:version")},
                     sort_keys=True, separators=(",", ":")))
    return 0


def openssl(argv):
    if argv[:2] == ["rand", "-base64"]:
        print("c3R1Yi10aHJvd2F3YXkta2V5LW5vdC1yZWFsLTAwMDA=")
        return 0
    return fail(f"openssl: unhandled {argv}", 64)


def daemon_assets(argv):
    version, tag, repo = option(argv, "--version"), option(argv, "--release-tag"), option(argv, "--repo")
    out = Path(option(argv, "--output-dir"))
    out.mkdir(parents=True, exist_ok=True)
    entries = []
    for platform in ("darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"):
        path = out / f"c11d-remote-{platform}"
        path.write_text(f"stub c11d {platform} {version}\n")
        entries.append({"platform": platform, "asset": path.name, "sha256": sha256(path)})
    (out / "c11d-remote-checksums.txt").write_text("".join(f"{e['sha256']}  {e['asset']}\n" for e in entries))
    (out / "c11d-remote-manifest.json").write_text(json.dumps(
        {"version": version, "releaseTag": tag, "repo": repo, "entries": entries}, indent=2) + "\n")
    return 0


def generate_appcast(argv):
    dmg, tag, out = Path(argv[0]), argv[1], Path(argv[2])
    key_file = os.environ.get("SPARKLE_PRIVATE_KEY_FILE", "")
    if not key_file or not Path(key_file).is_file() or not Path(key_file).read_text().strip():
        return fail("SPARKLE_PRIVATE_KEY_FILE is required")
    import base64
    import hashlib

    body = dmg.read_bytes()
    found = re.search(rb"version=(\S+) build=(\S+)", body)
    signature = base64.b64encode(hashlib.sha256(Path(key_file).read_bytes() + body).digest()).decode()
    url = os.environ.get("DOWNLOAD_URL_PREFIX", "") + dmg.name
    out.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        f"<channel><title>c11</title><item><title>{tag}</title>\n"
        f'<enclosure url="{url}" length="{len(body)}" type="application/octet-stream" '
        f'sparkle:version="{found.group(2).decode()}" sparkle:shortVersionString="{found.group(1).decode()}" '
        f'sparkle:edSignature="{signature}"/>\n'
        "</item></channel></rss>\n")
    return 0


def generate_keys(argv):
    target = option(argv, "-x")
    if not target:
        return fail(f"generate_keys: unhandled {argv}", 64)
    Path(target).write_text(SPARKLE_KEY + "\n")
    return 0


def fetch_sparkle_tools(_argv):
    print(STATE / "sparkle-bin")
    return 0


def git(argv):
    real = os.environ["RELEASE_STUB_REAL_GIT"]
    os.execv(real, ["git", *argv])


HANDLERS = {
    "gh": gh,
    "codesign": codesign,
    "xcrun": xcrun,
    "spctl": spctl,
    "security": security,
    "npx": npx,
    "swift": swift,
    "openssl": openssl,
    "lipo": lambda argv: (print("arm64"), 0)[1] if Path(argv[-1]).exists() else fail("no such file"),
    "git": git,
    "generate_keys": generate_keys,
    "build_remote_daemon_release_assets.sh": daemon_assets,
    "fetch-sparkle-tools.sh": fetch_sparkle_tools,
    "sparkle_generate_appcast.sh": generate_appcast,
    "remote-build.sh": lambda argv: fail("remote-build.sh must not be reached in these tests", 97),
    "ssh": lambda argv: fail("ssh must not be reached in these tests", 97),
    "rsync": lambda argv: fail("rsync must not be reached in these tests", 97),
}
# Answer success and do nothing beyond the log line.
for _name in ("curl", "sentry-cli", "go", "pkill", "killall", "c11-remote-artifacts.sh",
              "release_keychain.sh", "test_cli_version_memory_guard.py"):
    HANDLERS.setdefault(_name, lambda argv: 0)


def main(tool):
    argv = sys.argv[1:]
    log(tool, argv)
    sys.exit(HANDLERS[tool](argv))
