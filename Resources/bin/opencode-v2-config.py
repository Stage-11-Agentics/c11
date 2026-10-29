#!/usr/bin/env python3
"""Fail-closed version probe and OpenCode 2 runtime config composer."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

VERSION_RE = re.compile(r"(?:^|\s)v?(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?(?:\s|$)")


def probe(binary: str) -> int:
    try:
        real = Path(binary).resolve(strict=True)
        st = real.stat()
        key = hashlib.sha256(f"{real}\0{st.st_mtime_ns}\0{st.st_size}".encode()).hexdigest()
        cache_dir = Path("/tmp") / f"c11-opencode-version-{os.getuid()}"
        try:
            cache_dir.mkdir(mode=0o700)
        except FileExistsError:
            pass
        dir_stat = cache_dir.lstat()
        if not stat.S_ISDIR(dir_stat.st_mode) or dir_stat.st_uid != os.getuid():
            return 2
        if stat.S_IMODE(dir_stat.st_mode) != 0o700:
            os.chmod(cache_dir, 0o700)
        dir_fd = os.open(cache_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                         getattr(os, "O_NOFOLLOW", 0))
        cache_name = key
        try:
            cache_fd = os.open(cache_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
            cache_stat = os.fstat(cache_fd)
            if (stat.S_ISREG(cache_stat.st_mode) and cache_stat.st_uid == os.getuid() and
                    stat.S_IMODE(cache_stat.st_mode) == 0o600):
                with os.fdopen(cache_fd, "r", encoding="ascii") as cached:
                    cache_fd = -1
                    value = cached.read(64).strip()
            else:
                value = ""
            if cache_fd >= 0:
                os.close(cache_fd)
            if re.fullmatch(r"\d+\.\d+\.\d+", value):
                print(value)
                return 0
        except (OSError, UnicodeError):
            pass
        result = subprocess.run([str(real), "--version"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=0.8, check=False, env=os.environ.copy())
        if result.returncode != 0:
            return 2
        match = VERSION_RE.search(result.stdout)
        if not match:
            return 2
        version = ".".join(match.groups())
        try:
            fd = os.open(cache_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=dir_fd)
            with os.fdopen(fd, "w", encoding="ascii") as target:
                target.write(version + "\n")
        except FileExistsError:
            pass
        except OSError:
            pass
        print(version)
        return 0
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return 2
    finally:
        try:
            os.close(dir_fd)
        except (OSError, UnboundLocalError):
            pass


def parse_jsonc(source: str):
    def skip_trivia(position: int) -> int:
        while position < len(source):
            if source[position].isspace():
                position += 1
                continue
            if source.startswith("//", position):
                position += 2
                while position < len(source) and source[position] not in "\r\n":
                    position += 1
                continue
            if source.startswith("/*", position):
                end = source.find("*/", position + 2)
                if end < 0:
                    raise ValueError("unterminated JSONC comment")
                position = end + 2
                continue
            break
        return position

    out = []
    i = 0
    string = False
    escape = False
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                string = False
            i += 1
            continue
        if ch == '"':
            string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            i += 2
            while i < len(source) and source[i] not in "\r\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            end = source.find("*/", i + 2)
            if end < 0:
                raise ValueError("unterminated JSONC comment")
            i = end + 2
            continue
        if ch == ",":
            j = skip_trivia(i + 1)
            if j < len(source) and source[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads("".join(out))


def config_path() -> Path:
    explicit = os.environ.get("OPENCODE_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser() / "cli.json"
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg and Path(xdg).is_absolute():
        return Path(xdg) / "opencode" / "cli.json"
    home = os.environ.get("HOME")
    if not home:
        raise ValueError("HOME is unavailable")
    return Path(home) / ".config" / "opencode" / "cli.json"


def merge_records(base: dict, overlay: dict) -> dict:
    """Mirror the pinned CLI config merge: nested objects merge; arrays replace."""
    result = dict(base)
    for key, value in overlay.items():
        current = result.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            result[key] = merge_records(current, value)
        else:
            result[key] = value
    return result


def compose(plugin_dir: str) -> int:
    try:
        env_content = os.environ.get("OPENCODE_CLI_CONFIG_CONTENT")
        file_config = {}
        path = config_path()
        if path.exists():
            loaded = parse_jsonc(path.read_text(encoding="utf-8"))
            if not isinstance(loaded, dict):
                raise ValueError("cli.json must be an object")
            file_config = loaded
        if env_content is not None and env_content.strip():
            env_config = parse_jsonc(env_content)
            if not isinstance(env_config, dict):
                raise ValueError("OPENCODE_CLI_CONFIG_CONTENT must be an object")
        else:
            env_config = {}

        # OpenCode reapplies OPENCODE_CLI_CONFIG_CONTENT after each cli.json
        # update. Keep the operator's original environment overlay intact, but
        # do not copy file-only settings into it: that would turn a snapshot of
        # cli.json into a permanent override after the operator changes a
        # setting. The plugin array is the one deliberate snapshot because it
        # must combine file plugins, environment plugins, and this extension.
        effective_config = merge_records(file_config, env_config)
        plugins = effective_config.get("plugins", [])
        if not isinstance(plugins, list):
            raise ValueError("effective plugins must be an array of strings or plugin objects")
        for item in plugins:
            if isinstance(item, str):
                if not item:
                    raise ValueError("plugin package names cannot be empty")
                continue
            if (not isinstance(item, dict) or set(item) - {"package", "options"} or
                    not isinstance(item.get("package"), str) or not item["package"] or
                    ("options" in item and not isinstance(item["options"], dict))):
                raise ValueError("plugin entries must be package strings or {package, options} objects")
        resolved = str(Path(plugin_dir).resolve(strict=True))
        output_config = env_config.copy()
        output_config["plugins"] = [*plugins, {"package": resolved}]
        print(json.dumps(output_config, separators=(",", ":"), ensure_ascii=False))
        return 0
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"c11 OpenCode v2 plugin disabled: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "version":
        raise SystemExit(probe(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "compose":
        raise SystemExit(compose(sys.argv[2]))
    raise SystemExit(64)
