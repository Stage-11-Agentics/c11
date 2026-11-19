"""The operator's dev hosts, for scripts that reach another machine. No host lives in the tree.

    from dev_hosts import dev_host
    host = args.host or dev_host("C11_REMOTE_HOST", "--host")

dev_host(KEY, FLAG) returns the environment variable KEY when it is set, else the last KEY=value
line of ${C11_DEV_HOSTS:-~/.config/c11/dev-hosts} (plain KEY=value lines, # comments; the file is
parsed, never executed). Unset everywhere, it prints one line naming KEY and exits 2. A script's
own FLAG wins over both; the caller checks it first. scripts/dev-hosts.sh is the shell twin.
"""
import os
import sys


def config_path():
    return os.environ.get("C11_DEV_HOSTS") or os.path.join(os.path.expanduser("~"), ".config/c11/dev-hosts")


def lookup(key):
    value = os.environ.get(key, "").strip()
    if value:
        return value
    try:
        with open(config_path(), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        name, sep, rest = line.strip().partition("=")
        if sep and name.strip() == key and rest.strip():
            value = rest.strip()
    return value or None


def unset_message(key, flag=None):
    hint = "<ssh host>" if key.endswith("_HOST") else "<value>"
    where = os.environ.get("C11_DEV_HOSTS") or "~/.config/c11/dev-hosts"
    return "%s is unset: %sexport it, or add %s=%s to %s" % (
        key, "pass %s, " % flag if flag else "", key, hint, where)


def dev_host(key, flag=None):
    value = lookup(key)
    if value:
        return value
    sys.stderr.write(unset_message(key, flag) + "\n")
    sys.exit(2)
