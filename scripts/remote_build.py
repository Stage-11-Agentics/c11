#!/usr/bin/env python3
"""SSH transport for a self-contained worktree snapshot and existing c11 build scripts."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

SUBMODULES = ("ghostty", "vendor/bonsplit")
# Host mirror name -> checkout path; the host keeps one bare mirror per repository.
REPOS = {"parent": "", "ghostty": "ghostty", "vendor-bonsplit": "vendor/bonsplit"}
EXCLUDED = (".git", ".lattice", ".etch", "DerivedData", "build", "build-*",
            "GhosttyKit.xcframework", "ghostty/zig-out", "ghostty/.zig-cache",
            "c11d/zig-out", "c11d/.zig-cache", "web/node_modules")


class ToolchainError(ValueError):
    """Missing, unusable or unsupported native build tools (exit 3)."""


def run(args, cwd=None, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=cwd, check=True, **kwargs)


def git(root, *args):
    return run(["git", "-C", root, *args], stdout=subprocess.PIPE).stdout.decode().strip()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def excluded(name):
    import fnmatch
    return any(fnmatch.fnmatch(name.split("/")[0], p) or name == p or
               name.startswith(p + "/") for p in EXCLUDED)


def safe_path(root, name):
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or not p.parts or ".git" in p.parts:
        raise ValueError(f"unsafe overlay path: {name!r}")
    dest = root / name
    if not dest.parent.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"overlay parent escapes source: {name!r}")
    return dest


def entry(root, name):
    path = safe_path(root, name)
    if path.is_symlink():
        return {"path": name, "kind": "symlink", "target": os.readlink(path)}
    if not path.exists():
        return {"path": name, "kind": "deleted"}
    if not path.is_file():
        raise ValueError(f"unsupported overlay type: {name!r}")
    return {"path": name, "kind": "file", "sha256": digest(path),
            "mode": path.stat().st_mode & 0o777}


def snapshot(root, payload, args, held=None):
    held = held or {}
    head = git(root, "rev-parse", "HEAD")
    modules = {}
    for name in SUBMODULES:
        pinned = git(root, "ls-tree", "HEAD", name).split()[2]
        actual = git(root / name, "rev-parse", "HEAD")
        if pinned != actual or git(root / name, "status", "--porcelain", "--untracked-files=normal"):
            raise ValueError(f"{name} must be provisioned, clean and at pinned SHA {pinned}")
        modules[name] = pinned
    # Union staged and unstaged changes; diff against HEAD includes tracked deletes/renames.
    raw = run(["git", "-C", root, "diff", "--name-only", "--no-renames", "-z", "HEAD"],
              stdout=subprocess.PIPE).stdout
    raw += run(["git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z"],
               stdout=subprocess.PIPE).stdout
    names = sorted(set(os.fsdecode(n) for n in raw.split(b"\0") if n))
    overlays = []
    overlay_dir = payload / "overlay"
    overlay_dir.mkdir()
    for name in names:
        if excluded(name):
            continue
        if name in SUBMODULES or any(name.startswith(s + "/") for s in SUBMODULES):
            raise ValueError("dirty submodule/gitlink is not a permitted overlay")
        item = entry(root, name)
        overlays.append(item)
        src = safe_path(root, name)
        dst = safe_path(overlay_dir, name)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if item["kind"] == "file":
            shutil.copy2(src, dst)
        elif item["kind"] == "symlink":
            dst.symlink_to(item["target"])
        if entry(root, name) != item:
            raise ValueError(f"source changed during snapshot: {name!r}")
    bundles = {}
    for repo, path in REPOS.items():
        kind = bundle(root / path, payload / (repo + ".bundle"), held.get(repo, []))
        if kind:
            bundles[repo] = kind
    manifest = {"invocation": uuid.uuid4().hex, "head": head, "bundles": bundles,
                "branch": git(root, "branch", "--show-current"), "submodules": modules,
                "overlay": overlays, "dirty": bool(overlays), "tag": args.tag,
                "slug": slug(args.tag), "mode": args.mode, "extra": args.extra,
                "release_options": [f"--{k}" for k in ("clean", "wmo", "universal") if getattr(args, k)],
                "developer_dir": os.environ.get("C11_REMOTE_DEVELOPER_DIR", "/Applications/Xcode-26.3.app/Contents/Developer"),
                "zig_dir": os.environ.get("C11_REMOTE_ZIG_DIR", "")}
    (payload / "identity.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def slug(tag):
    return re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")


def bundle(repo, path, held):
    """Bundle HEAD minus everything reachable from heads the host already holds.

    Returns "full", "incremental", or None when the host already has HEAD."""
    shas = [s for s in held if re.fullmatch(r"[0-9a-f]{40}", s)]
    known = []
    if shas:
        # Only commits this clone has can bound the bundle; the rest are unknown here.
        check = run(["git", "-C", repo, "cat-file", "--batch-check=%(objecttype)"],
                    input="".join(s + "\n" for s in shas).encode(), stdout=subprocess.PIPE)
        known = [s for s, kind in zip(shas, check.stdout.decode().splitlines()) if kind == "commit"]
    revs = "".join(["HEAD\n", *("^" + s + "\n" for s in known)]).encode()
    missing = run(["git", "-C", repo, "rev-list", "--count", "--stdin"], input=revs, stdout=subprocess.PIPE)
    if int(missing.stdout) == 0:
        return None
    # Prerequisites are commits the host mirror holds; its fetch refuses the bundle otherwise.
    run(["git", "-c", "pack.threads=2", "-C", repo, "bundle", "create", "--quiet", path, "--stdin"], input=revs)
    return "incremental" if known else "full"


def held_heads(ssh):
    """Ask the host which commits each repo mirror holds, creating mirrors on first use.

    A new mirror adopts the heads of the host's existing per-tag checkouts, so
    moving onto mirrors does not re-upload history the host already has."""
    code = """import json,subprocess,sys
from pathlib import Path
builds=Path.home()/'c11-builds'; held={}
def git(*a,**k): return subprocess.run(['git',*map(str,a)],capture_output=True,text=True,**k)
for repo,sub in json.loads(sys.argv[1]).items():
    mirror=builds/'mirrors'/(repo+'.git')
    if not mirror.is_dir():
        git('init','--quiet','--bare',mirror)
        for checkout in sorted(builds.glob('*/source')):
            head=git('-C',checkout/sub,'rev-parse','--verify','HEAD').stdout.strip()
            if (checkout/sub/'.git').exists() and head:
                git('-C',mirror,'fetch','--quiet','--no-recurse-submodules',checkout/sub,'+HEAD:refs/c11/'+head)
    out=git('-C',mirror,'for-each-ref','--format=%(objectname)','refs/c11/').stdout
    held[repo]=out.split()
print(json.dumps(held))
"""
    response = run([*ssh, shlex.join(["python3", "-c", code, json.dumps(REPOS)])], stdout=subprocess.PIPE)
    return json.loads(response.stdout)


def mirror_head(payload, manifest, repo, sha):
    """Publish one exact commit in the host's shared mirror; return the mirror and ref."""
    mirror = Path.home() / "c11-builds" / "mirrors" / (repo + ".git")
    ref = "refs/c11/" + sha
    if not mirror.is_dir():
        run(["git", "init", "--quiet", "--bare", mirror])
    if repo in manifest["bundles"]:
        # Fetch verifies the bundle's prerequisite commits are already in the mirror.
        command = ["git", "-C", mirror, "fetch", "--quiet", "--no-recurse-submodules",
                   payload / (repo + ".bundle"), "+HEAD:" + ref]
    else:
        command = ["git", "-C", mirror, "update-ref", ref, sha + "^{commit}"]
    # A concurrent request for the same head may win the ref lock; its ref serves equally.
    attempt = subprocess.run([str(a) for a in command], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    held = subprocess.run(["git", "-C", str(mirror), "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
                          stdout=subprocess.PIPE).stdout.decode().strip()
    if held != sha:
        raise ValueError(f"host mirror {repo} lacks {sha}: {attempt.stderr.decode().strip()}")
    return mirror, ref


def apply_overlay(root, payload, manifest):
    for item in manifest["overlay"]:
        dst = safe_path(root, item["path"])
        src = safe_path(payload / "overlay", item["path"])
        if dst.is_symlink() or dst.is_file():
            dst.unlink()
        elif dst.exists():
            raise ValueError("overlay cannot replace a directory")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if item["kind"] == "file":
            shutil.copy2(src, dst)
            dst.chmod(item["mode"])
        elif item["kind"] == "symlink":
            dst.symlink_to(item["target"])
        elif item["kind"] != "deleted":
            raise ValueError("unsupported overlay kind")
        if entry(root, item["path"]) != item:
            raise ValueError(f"overlay identity mismatch: {item['path']!r}")


def remote(payload, locked=False):
    manifest = json.loads((payload / "identity.json").read_text())
    base = Path.home() / "c11-builds" / manifest["slug"]
    artifacts = base / "artifacts" / manifest["invocation"]
    artifacts.mkdir(parents=True, exist_ok=True)
    if not locked:
        # Load and same-tag admission enclose source preparation, native builds, and snapshot.
        runner = Path(__file__).resolve()
        return subprocess.call([sys.executable, payload / "atlas_build_slots.py", manifest["slug"],
                                payload / "with-build-lock.sh", sys.executable,
                                runner, "--remote-locked", payload])
    result = dict(manifest, compile="failed", tests="na" if manifest["mode"] != "test" else "failed")
    try:
        # Stable per-tag paths preserve incremental compiler/Zig caches between invocations.
        source = base / "source"
        prior_overlay = base / "last-overlay.json"
        if prior_overlay.exists():
            for item in json.loads(prior_overlay.read_text()):
                path = safe_path(source, item["path"])
                if path.is_file() or path.is_symlink():
                    path.unlink()
        for repo, path in REPOS.items():
            sha = manifest["submodules"].get(path, manifest["head"])
            mirror, ref = mirror_head(payload, manifest, repo, sha)
            checkout = source / path
            if not (checkout / ".git").exists():
                if checkout.exists():
                    shutil.rmtree(checkout)
                run(["git", "init", "--quiet", checkout])
            # Recursive fetch would ask old origins for unrelated historical gitlinks.
            run(["git", "-C", checkout, "fetch", "--no-recurse-submodules", "--quiet", mirror, ref])
            run(["git", "-C", checkout, "reset", "--hard", sha], stdout=subprocess.DEVNULL)
            if not path:
                # Clear old overlays without deleting build caches or required submodule repositories.
                run(["git", "-C", source, "clean", "-fd", "-e", "ghostty", "-e", "vendor/bonsplit"],
                    stdout=subprocess.DEVNULL)
        apply_overlay(source, payload, manifest)
        prior_overlay.write_text(json.dumps(manifest["overlay"]) + "\n")
        if git(source, "rev-parse", "HEAD") != manifest["head"] or any(
                git(source / n, "rev-parse", "HEAD") != h for n, h in manifest["submodules"].items()):
            raise ValueError("remote source identity mismatch")
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = manifest["developer_dir"]
        env["PATH"] = (manifest["zig_dir"] or str(Path.home() / "zig-0.15.2")) + ":/opt/homebrew/bin:/usr/local/bin:" + env["PATH"]
        try:
            result["xcode"] = run(["xcodebuild", "-version"], env=env, stdout=subprocess.PIPE).stdout.decode().strip()
            result["zig"] = run(["zig", "version"], env=env, stdout=subprocess.PIPE).stdout.decode().strip()
        except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
            raise ToolchainError(f"toolchain unavailable: {error}") from error
        if result["xcode"].splitlines()[:1] != ["Xcode 26.3"] or result["zig"] != "0.15.2":
            raise ToolchainError("requires process-scoped Xcode 26.3 and Zig 0.15.2")
        env["C11_BUILD_LOCK_LABEL"] = "remote:" + manifest["slug"]
        mode = manifest["mode"]
        tag = manifest["tag"]
        if mode == "test":
            env["C11_TEST_DERIVED_DATA"] = str(base / "derived-test")
            # Selected tests must execute, not default to the build action.
            command = [source / "scripts/test-unit-local.sh", "test", *manifest["extra"]]
            app = None
        else:
            if mode == "debug":
                derived = Path.home() / "Library/Developer/Xcode/DerivedData" / ("c11-" + manifest["slug"])
                command = [source / "scripts/reload.sh", "--tag", tag, "--no-launch", "--derived-data", derived]
                app = derived / "Build/Products/Debug" / ("c11 DEV " + tag + ".app")
            else:
                derived = base / "derived-release"
                command = [source / "scripts/reloads.sh", "--tag", tag, "--no-launch", "--derived-data", derived,
                           *manifest["release_options"]]
                app = derived / "Build/Products/Release" / ("c11 STAGING " + tag + ".app")
        with (artifacts / "build.log").open("w") as log:
            build = subprocess.run([str(a) for a in command], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
        build_log = (artifacts / "build.log").read_text()
        if mode == "test" and ("Test Suite " in build_log or "Testing started" in build_log):
            result["compile"] = "ok"
        # Failed assertions still produce diagnostic bundles. Snapshot them before
        # returning the native status or allowing the next request to clean source.
        try:
            for i, argument in enumerate(manifest["extra"]):
                if argument == "-resultBundlePath" and i + 1 < len(manifest["extra"]):
                    bundle = source / manifest["extra"][i + 1]
                    if bundle.is_dir() and bundle.resolve().is_relative_to(source.resolve()):
                        shutil.copytree(bundle, artifacts / "tests.xcresult", symlinks=True)
        except OSError as error:
            if not build.returncode:
                raise
            result["result_bundle_error"] = str(error)
        if build.returncode:
            raise subprocess.CalledProcessError(build.returncode, command)
        if mode == "test":
            if "** TEST SUCCEEDED **" not in build_log or not re.search(r"Executed [1-9][0-9]* tests?", build_log):
                raise ValueError("test action did not report TEST SUCCEEDED")
            result["tests"] = "ok"
        if app:
            if not app.is_dir():
                raise ValueError("successful build did not produce the requested app")
            shutil.copytree(app, artifacts / app.name, symlinks=True)
            result["app"] = app.name
            result["executable_sha256"] = digest(artifacts / app.name / "Contents/MacOS/c11")
        result["compile"] = "ok"
        result["ok"] = True
        code = 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        result["ok"] = False
        result["error"] = str(error)
        code = 3 if isinstance(error, ToolchainError) else (
            error.returncode if isinstance(error, subprocess.CalledProcessError) else 4)
        print(f"[remote-build] failure: {error}", file=sys.stderr)
    (artifacts / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("C11_REMOTE_RESULT " + json.dumps({"invocation": manifest["invocation"], "artifacts": str(artifacts),
                                          "ok": result["ok"], "compile": result["compile"], "tests": result["tests"]}), flush=True)
    return code


def client(args):
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="c11-remote-source-") as tmp:
        payload = Path(tmp)
        host = args.host
        ssh = ["ssh", "-o", "BatchMode=yes", host]
        started = time.monotonic()
        manifest = snapshot(root, payload, args, held_heads(ssh))
        for name in ("remote_build.py", "atlas_build_slots.py", "with-build-lock.sh"):
            shutil.copy2(root / "scripts" / name, payload / name)
        relative = f"c11-builds/{manifest['slug']}/incoming/{manifest['invocation']}"
        run([*ssh, shlex.join(["mkdir", "-p", relative])])
        run(["rsync", "-a", "-e", "ssh -o BatchMode=yes", str(payload) + "/", host + ":" + relative + "/"])
        sent = sum(f.stat().st_size for f in payload.rglob("*") if f.is_file() and not f.is_symlink())
        print(f"[remote-build] staged {sent / 1e6:.1f} MB in {time.monotonic() - started:.1f}s; bundles: " +
              (", ".join(f"{r}={k}" for r, k in manifest["bundles"].items()) or "none, host holds every head"),
              flush=True)
        command = shlex.join(["python3", relative + "/remote_build.py", "--remote", relative])
        print(f"[remote-build] host={host} tag={args.tag} invocation={manifest['invocation']} head={manifest['head']}", flush=True)
        print(f"[remote-build] remote log: ~/c11-builds/{manifest['slug']}/artifacts/{manifest['invocation']}/build.log", flush=True)
        process = subprocess.run([*ssh, command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(process.stdout, end="", flush=True)
        local = root / "build-remote" / manifest["invocation"]
        local.mkdir(parents=True)
        (local / "transport.log").write_text(process.stdout)
        remote_artifacts = f"c11-builds/{manifest['slug']}/artifacts/{manifest['invocation']}/"
        retrieved = subprocess.run(["rsync", "-az", "-e", "ssh -o BatchMode=yes", host + ":" + remote_artifacts, str(local) + "/"])
        print(f"[remote-build] logs and identity: {local}")
        if process.returncode:
            return process.returncode
        if retrieved.returncode:
            return retrieved.returncode
        result = json.loads((local / "result.json").read_text())
        if not result.get("ok") or any(result.get(k) != manifest[k] for k in ("invocation", "head", "submodules", "overlay", "mode", "tag")):
            raise ValueError("remote result/source identity mismatch")
        if result["compile"] != "ok" or (args.mode == "test" and result["tests"] != "ok"):
            raise ValueError("remote build/test result failed")
        if args.mode == "test":
            print("C11_REMOTE_OK compile=ok tests=ok")
            return 0
        app = local / result["app"]
        if digest(app / "Contents/MacOS/c11") != result["executable_sha256"]:
            raise ValueError("retrieved artifact executable hash mismatch")
        if args.mode == "debug":
            plist = app / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            launch_env = info.setdefault("LSEnvironment", {})
            launch_env["CMUXD_UNIX_PATH"] = str(Path.home() / "Library/Application Support/c11" / ("c11d-dev-" + manifest["slug"] + ".sock"))
            launch_env["C11_REPO_ROOT"] = str(root)
            plist.write_bytes(plistlib.dumps(info))
            run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", app])
            run(["codesign", "--verify", "--deep", "--strict", app])
            destination = Path.home() / "Library/Developer/Xcode/DerivedData" / ("c11-" + manifest["slug"]) / "Build/Products/Debug" / app.name
        else:
            destination = Path.home() / "Library/Developer/Xcode/DerivedData" / ("remote-release-" + manifest["slug"]) / app.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Complete transfer/signing precedes replacement, so a remote failure preserves the old app.
        incoming = destination.with_name(destination.name + ".incoming-" + manifest["invocation"])
        shutil.copytree(app, incoming, symlinks=True)
        backup = destination.with_name(destination.name + ".previous-" + manifest["invocation"])
        if destination.exists():
            destination.rename(backup)
        try:
            incoming.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        result["local_executable_sha256"] = digest(destination / "Contents/MacOS/c11")
        (local / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if args.mode == "debug":
            # Publish the convenience CLI pointer only after a complete artifact replace.
            pointer = Path("/tmp/c11-last-cli-path")
            staged_pointer = pointer.with_name(pointer.name + "-" + manifest["invocation"])
            try:
                staged_pointer.write_text(str(destination / "Contents/Resources/bin/c11") + "\n")
                staged_pointer.chmod(0o600)
                staged_pointer.replace(pointer)
            except OSError:
                staged_pointer.unlink(missing_ok=True)
        print(f"APP_PATH={destination}\nC11_REMOTE_OK compile=ok tests=na")
        if args.launch:
            run([root / "scripts/launch-tagged-automation.sh", args.tag, "--qa", "fresh"])
        return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] in ("--remote", "--remote-locked"):
        return remote(Path(sys.argv[2]).resolve(), locked=sys.argv[1] == "--remote-locked")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("C11_REMOTE_HOST", "atlas"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--mode", choices=("debug", "test", "release"), default="debug")
    parser.add_argument("--launch", action="store_true", help="launch a returned Debug app with QA fresh")
    for option in ("clean", "wmo", "universal"):
        parser.add_argument("--" + option, action="store_true")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.extra and args.extra[0] == "--":
        args.extra.pop(0)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.tag):
        parser.error("tag must be 1–64 letters, digits, dots, underscores or hyphens")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._-]*", args.host):
        parser.error("invalid SSH host")
    if args.launch and args.mode != "debug":
        parser.error("--launch requires --mode debug")
    if args.extra and args.mode != "test":
        parser.error("extra arguments require --mode test")
    if args.mode != "release" and (args.clean or args.wmo or args.universal):
        parser.error("--clean/--wmo/--universal require --mode release")
    return client(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"[remote-build] {error}", file=sys.stderr)
        sys.exit(error.returncode if isinstance(error, subprocess.CalledProcessError) else 4)
