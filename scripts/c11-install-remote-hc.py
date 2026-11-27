#!/usr/bin/env python3
"""Install a trusted bundled hc on this machine, without starting any process.

Used by c11-atlas-link.sh install --from APP on the destination machine.
Only codesign is executed; hc, its sessions and the relay are never touched.
"""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid


# Keep aligned with HCRetainedTrust/HCCoreBinary and c11-release.sh. Never
# derive a trust anchor from the input manifest, a signature's display text,
# PATH, or an environment override. A release adds its signed helper hash here
# and to HCCoreBinary.shippedHelperSHA256 for subsequent releases.
SHIPPED_HELPER_SHA256 = frozenset({
    # c11 2.0.0 (build 200, 284b8ae22), from the published release's hc-pin.json.
    "2744b886409c742b5b1bb2d36730dcfef805860f83d742c20dc1691d52338311",
})
RELEASE_TEAM = "UKQ4QALWD4"
APP_IDENTIFIER = "com.stage11.c11"
HELPER_IDENTIFIER = "com.stage11.c11.herdr-core"
CONFIG_CONTENTS = b'headless = "200x120"\n'
MANIFEST_MAX_BYTES = 64 * 1024
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
DIRECTORY_FLAGS = READ_FLAGS | os.O_DIRECTORY


class InstallError(Exception):
    pass


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def absolute_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or "\x00" in str(path):
        raise InstallError("expected an absolute path without parent traversal")
    return path


class Directories:
    """Walk with openat/O_NOFOLLOW; never resolve an input symlink for a write."""

    def __init__(self, stack, home=None):
        self.stack = stack
        self.home = home
        self.links = []

    def open(self, path, create=False):
        path = absolute_path(path)
        fd = os.open("/", DIRECTORY_FLAGS)
        self.stack.callback(os.close, fd)
        prefix = Path("/")
        for name in path.parts[1:]:
            prefix /= name
            try:
                child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    return None
                self.check()
                os.mkdir(name, 0o700, dir_fd=fd)
                child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
            except OSError as exc:
                raise InstallError("directory is a symlink or not a directory: %s" % prefix) from exc
            self.stack.callback(os.close, child)
            info = os.fstat(child)
            if self.home is not None and (prefix == self.home or self.home in prefix.parents):
                if info.st_uid != os.getuid():
                    raise InstallError("destination directory is not owned by this user: %s" % prefix)
            self.links.append((fd, name, child, (info.st_dev, info.st_ino, info.st_uid)))
            fd = child
        return fd

    def check(self):
        for parent, name, fd, expected in self.links:
            there = os.stat(name, dir_fd=parent, follow_symlinks=False)
            here = os.fstat(fd)
            if (not stat.S_ISDIR(there.st_mode)
                    or (there.st_dev, there.st_ino, there.st_uid) != expected
                    or (here.st_dev, here.st_ino, here.st_uid) != expected):
                raise InstallError("directory changed during installation")


class Snapshot:
    """HCRetainedTrust's open-descriptor hash and unchanged-path check."""

    def __init__(self, stack, parent, name, owned=False, optional=False):
        self.parent, self.name = parent, name
        try:
            self.fd = os.open(name, READ_FLAGS, dir_fd=parent)
        except FileNotFoundError:
            if optional:
                self.fd = None
                return
            raise
        except OSError as exc:
            raise InstallError("file is a symlink or not regular: %s" % name) from exc
        stack.callback(os.close, self.fd)
        info = os.fstat(self.fd)
        if not stat.S_ISREG(info.st_mode):
            raise InstallError("file is not regular: %s" % name)
        if owned and info.st_uid != os.getuid():
            raise InstallError("destination file is not owned by this user: %s" % name)
        self.before = identity(info)
        self.mode = stat.S_IMODE(info.st_mode)

    def read(self, limit=None):
        os.lseek(self.fd, 0, os.SEEK_SET)
        parts = []
        size = 0
        while True:
            chunk = os.read(self.fd, min(1024 * 1024, limit + 1 - size) if limit is not None else 1024 * 1024)
            if not chunk:
                break
            parts.append(chunk)
            size += len(chunk)
            if limit is not None and size > limit:
                raise InstallError("file exceeds size limit: %s" % self.name)
        self.check()
        return b"".join(parts)

    def digest(self):
        os.lseek(self.fd, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(self.fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        self.check()
        return digest.hexdigest()

    def check(self):
        there = os.stat(self.name, dir_fd=self.parent, follow_symlinks=False)
        if (not stat.S_ISREG(there.st_mode) or identity(there) != self.before
                or identity(os.fstat(self.fd)) != self.before):
            raise InstallError("file changed during verification: %s" % self.name)


def signature_requirement(identifier):
    return ('identifier "%s" and anchor apple generic '
            'and certificate leaf[subject.OU] = "%s"') % (identifier, RELEASE_TEAM)


def verify_signature(path, requirement, *, deep=False, run=subprocess.run):
    args = ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
            "--test-requirement", "=" + requirement]
    if deep:
        args.append("--deep")
    args.append(str(path))
    result = run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
    if result.returncode != 0:
        raise InstallError("c11 signature does not verify: %s" % path)


def manifest_from(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise InstallError("duplicate manifest field: %s" % key)
            result[key] = value
        return result
    try:
        record = json.loads(data, object_pairs_hook=unique)
        version = record["version"]
        generation = record["protocolGeneration"]
        valid = (isinstance(version, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version)
                 and type(generation) is int and generation > 0
                 and all(isinstance(record[key], str) and re.fullmatch(r"[0-9a-f]{64}", record[key])
                         for key in ("sourceSHA256", "executableSHA256")))
    except (ValueError, TypeError, KeyError) as exc:
        raise InstallError("invalid hc-pin.json") from exc
    if not valid:
        raise InstallError("invalid hc-pin.json")
    return record


def temporary_file(parent):
    name = ".c11-install-" + uuid.uuid4().hex
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=parent)
    return name, fd


def write_all(fd, data):
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise InstallError("short write")
        view = view[count:]


def install(app, home, *, run=subprocess.run):
    """The process callable is a test-only import seam; the CLI cannot replace it."""
    app, home = absolute_path(app), absolute_path(home)
    with ExitStack() as stack:
        source_dirs = Directories(stack)
        helpers = source_dirs.open(app / "Contents/Helpers")
        resources = source_dirs.open(app / "Contents/Resources")
        if helpers is None or resources is None:
            raise InstallError("app has no bundled hc helper and manifest")
        helper = Snapshot(stack, helpers, "herdr-core")
        manifest = Snapshot(stack, resources, "hc-pin.json")
        record = manifest_from(manifest.read(MANIFEST_MAX_BYTES))
        sha = record["executableSHA256"]
        if helper.digest() != sha or not helper.mode & 0o111:
            raise InstallError("bundled helper does not match its manifest or is not executable")
        if sha not in SHIPPED_HELPER_SHA256:
            # Establish c11's anchor using the signed app, then admit its
            # helper under that same anchor. Signature display metadata alone
            # cannot establish trust, even when it names the expected team.
            verify_signature(app, signature_requirement(APP_IDENTIFIER), deep=True, run=run)
            verify_signature(app / "Contents/Helpers/herdr-core",
                             signature_requirement(HELPER_IDENTIFIER), run=run)
        source_dirs.check()
        helper.check()
        manifest.check()

        root = home / ".local/share/c11"
        key = "%s-%s" % (record["version"], sha[:12])
        folder = root / "hc" / key
        destination = folder / "herdr-core"
        config_folder = root / "config/herdr-core"
        dest_dirs = Directories(stack, home)
        if dest_dirs.open(home) is None:
            raise InstallError("destination home does not exist")
        # Preflight both trees and existing files before mkdir, chmod or write.
        existing_folder = dest_dirs.open(folder)
        existing_config_folder = dest_dirs.open(config_folder)
        existing = None
        if existing_folder is not None:
            existing = Snapshot(stack, existing_folder, "herdr-core", owned=True, optional=True)
            if existing.fd is None:
                raise InstallError("existing hash-keyed folder has no helper; refusing to replace it")
            if existing.digest() != sha:
                raise InstallError("existing hash-keyed helper has a different hash; never replaced")
        config = None
        if existing_config_folder is not None:
            config = Snapshot(stack, existing_config_folder, "config.toml", owned=True, optional=True)
        config_same = (config is not None and config.fd is not None
                       and config.read(MANIFEST_MAX_BYTES) == CONFIG_CONTENTS)
        source_dirs.check()
        helper.check()
        manifest.check()
        dest_dirs.check()

        if existing is None:
            hc_folder = dest_dirs.open(root / "hc", create=True)
            # mkdir and link are exclusive: neither can replace a serving file,
            # including one installed concurrently after our preflight.
            os.mkdir(key, 0o700, dir_fd=hc_folder)
            dest_folder = dest_dirs.open(folder)
            temp, fd = temporary_file(dest_folder)
            published = False
            try:
                digest = hashlib.sha256()
                os.lseek(helper.fd, 0, os.SEEK_SET)
                while True:
                    chunk = os.read(helper.fd, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    write_all(fd, chunk)
                if digest.hexdigest() != sha:
                    raise InstallError("helper changed while copying")
                os.fsync(fd)
                os.fchmod(fd, 0o555)
                copied = Snapshot(stack, dest_folder, temp)
                if copied.digest() != sha:
                    raise InstallError("copied helper hash differs")
                source_dirs.check()
                helper.check()
                manifest.check()
                dest_dirs.check()
                copied.check()
                os.link(temp, "herdr-core", src_dir_fd=dest_folder, dst_dir_fd=dest_folder,
                        follow_symlinks=False)
                published = True
            finally:
                os.close(fd)
                os.unlink(temp, dir_fd=dest_folder)
                if not published:
                    os.rmdir(key, dir_fd=hc_folder)
            os.fchmod(dest_folder, 0o555)
        else:
            existing.check()
            if existing.mode != 0o555:
                os.fchmod(existing.fd, 0o555)
            if stat.S_IMODE(os.fstat(existing_folder).st_mode) != 0o555:
                os.fchmod(existing_folder, 0o555)

        config_root = dest_dirs.open(root / "config", create=True)
        config_parent = dest_dirs.open(config_folder, create=True)
        for fd in (config_root, config_parent):
            if stat.S_IMODE(os.fstat(fd).st_mode) != 0o700:
                os.fchmod(fd, 0o700)
        if config_same:
            config.check()
            if config.mode != 0o600:
                os.fchmod(config.fd, 0o600)
        else:
            temp, fd = temporary_file(config_parent)
            try:
                write_all(fd, CONFIG_CONTENTS)
                os.fsync(fd)
                dest_dirs.check()
                if config is not None and config.fd is not None:
                    config.check()
                else:
                    try:
                        os.stat("config.toml", dir_fd=config_parent, follow_symlinks=False)
                    except FileNotFoundError:
                        pass
                    else:
                        raise InstallError("config appeared during installation; refusing to replace it")
                os.replace(temp, "config.toml", src_dir_fd=config_parent, dst_dir_fd=config_parent)
            finally:
                os.close(fd)
                try:
                    os.unlink(temp, dir_fd=config_parent)
                except FileNotFoundError:
                    pass
        return {"status": "unchanged" if existing is not None else "installed",
                "path": str(destination), "sha256": sha, "config_changed": not config_same}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="app", required=True, help="trusted c11.app on this machine")
    parser.add_argument("--home", default=os.environ.get("HOME"), help="destination user's home")
    args = parser.parse_args(argv)
    try:
        if not args.home:
            raise InstallError("HOME is unset; supply --home")
        result = install(args.app, args.home)
        print("%(status)s %(path)s sha256=%(sha256)s" % result)
        return 0
    except (InstallError, OSError, subprocess.SubprocessError) as exc:
        print("c11-install-remote-hc: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
