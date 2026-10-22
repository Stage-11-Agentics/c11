#!/usr/bin/env python3
"""Install/update/stop only the independent Atlas main backstop; never the PR poller."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

LABEL = "com.stage11.c11-main-backstop"
ROOT = Path.home() / "c11-main-backstop"
FILES = ("c11-main-backstop.py", "c11-main-backstop-service.py", "c11-pr-swift-poller.py", "host_test_quarantine.py")
URL = "https://github.com/Stage-11-Agentics/c11.git"


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, timeout=180, **kwargs).stdout.strip()


def launchctl(*args):
    return run(["/bin/launchctl", *args])


def installed():
    try:
        launchctl("print", f"gui/{os.getuid()}/{LABEL}")
        return True
    except subprocess.CalledProcessError:
        return False


def stop(recovery_runner=None):
    if installed():
        launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
    runner = recovery_runner or ROOT / "bin/c11-main-backstop.py"
    if runner.exists():
        run(["/usr/bin/python3", str(runner), "recover", "--root", str(ROOT)])
    if installed():
        raise RuntimeError("backstop LaunchAgent remains loaded")


def stage(source, destination):
    # Only bytes already merged on pinned main can become the installed controller.
    remote = run(["/usr/bin/git", "ls-remote", URL, "refs/heads/main"]).split()[0]
    run(["/usr/bin/git", "-C", str(source), "fetch", "--no-tags", URL, remote])
    hashes = {}
    for name in FILES:
        content = subprocess.run(["/usr/bin/git", "-C", str(source), "show", f"{remote}:scripts/{name}"],
                                 check=True, capture_output=True, timeout=30).stdout
        path = destination / name
        path.write_bytes(content)
        hashes[name] = hashlib.sha256(content).hexdigest()
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[name]:
            raise RuntimeError("staging checksum mismatch")
    (destination / "manifest.json").write_text(json.dumps({"sha": remote, "sha256": hashes}) + "\n")
    return remote


def plist():
    return {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", str(ROOT / "bin/c11-main-backstop.py"),
                             "supervise", "--root", str(ROOT), "--publish"],
        "WorkingDirectory": str(ROOT), "RunAtLoad": True, "KeepAlive": True,
        "ExitTimeOut": 90,
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": str(ROOT / "state/supervisor.log"),
        "StandardErrorPath": str(ROOT / "state/supervisor.log"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("install", "update", "health", "stop", "teardown", "rollback"))
    parser.add_argument("--source", type=Path, help="local clone used to fetch merged controller bytes")
    args = parser.parse_args()
    path = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    if args.mode == "health":
        print(launchctl("print", f"gui/{os.getuid()}/{LABEL}"))
        for name in ("bin/manifest.json", "state/last.json", "state/running.json"):
            if (ROOT / name).exists():
                print(name, (ROOT / name).read_text())
        return
    if args.mode in ("stop", "teardown"):
        stop()
        if args.mode == "teardown":
            path.unlink(missing_ok=True)
            # Own root only. gh credentials, poller files/LaunchAgent/slots are untouched.
            if ROOT.exists():
                shutil.rmtree(ROOT)
        return
    (ROOT / "state").mkdir(parents=True, exist_ok=True)
    if args.mode == "rollback":
        if not (ROOT / "previous").is_dir():
            raise RuntimeError("no previous controller")
        stop()
        (ROOT / "bin").rename(ROOT / "replaced")
        (ROOT / "previous").rename(ROOT / "bin")
        shutil.rmtree(ROOT / "replaced")
    else:
        if args.source is None:
            parser.error("install/update requires --source")
        if args.mode == "install" and (ROOT / "bin").exists():
            parser.error("already installed; use update")
        # Complete and verify the replacement before stopping any admission.
        with tempfile.TemporaryDirectory(prefix="staging-", dir=ROOT) as directory:
            staged = Path(directory)
            sha = stage(args.source.resolve(), staged)
            stop(staged / "c11-main-backstop.py")
            if (ROOT / "previous").exists():
                shutil.rmtree(ROOT / "previous")
            if (ROOT / "bin").exists():
                (ROOT / "bin").rename(ROOT / "previous")
            staged.rename(ROOT / "bin")
            print("installed", sha)
    (ROOT / "state/enabled.json").write_text('{"enabled": true}\n')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(plist()))
    launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
    print(launchctl("print", f"gui/{os.getuid()}/{LABEL}"))


if __name__ == "__main__":
    main()
