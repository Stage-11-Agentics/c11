#!/usr/bin/env python3
"""Build a pinned kit only as a child of remote_build's build-host admission."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile


def require_passing_tests(output):
    counts = re.findall(r"\b([1-9][0-9]*)/([1-9][0-9]*) tests passed\b", output)
    if not counts or any(a != b for a, b in counts):
        raise ValueError("native tests did not report a nonzero passing test count")
    return max(int(a) for a, _ in counts)


def check_guard_mutation(ghostty, artifacts, relative_path, guard, test_filter, label):
    """Exercise a null-argument rule on the admitted, isolated build copy."""
    source = ghostty / relative_path
    original = source.read_text()
    if original.count(guard) != 1:
        raise ValueError(f"{label} mutation guard is not unique")
    try:
        source.write_text(original.replace(guard, guard.replace("return false", "return true"), 1))
        red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                              "-Demit-xcframework=false", "-Dtest-filter=" + test_filter,
                              "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=1800)
        (artifacts / (label + "-mutation-red.log")).write_text(red.stdout)
        if red.returncode == 0 or test_filter not in red.stdout or "TestUnexpectedResult" not in red.stdout:
            raise ValueError(f"{label} mutation did not fail its behavioral test")
        print(f"C11_GHOSTTY_MUTATION_RED {label}", flush=True)
    finally:
        source.write_text(original)


def check_key_release_mutation(ghostty, artifacts):
    source = ghostty / "src/input/transaction_encode.zig"
    original = source.read_text()
    needle = "release.action = .release;"
    if original.count(needle) != 1:
        raise ValueError("key release mutation is not unique")
    try:
        source.write_text(original.replace(needle, "release.action = .press;", 1))
        red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                              "-Demit-xcframework=false", "-Dtest-filter=synchronous key encoding",
                              "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=1800)
        (artifacts / "key-release-mutation-red.log").write_text(red.stdout)
        if red.returncode == 0 or "synchronous key encoding" not in red.stdout or "TestExpectedEqual" not in red.stdout:
            raise ValueError("key release mutation did not fail its behavioral test")
        print("C11_GHOSTTY_MUTATION_RED key-release", flush=True)
    finally:
        source.write_text(original)


def check_surface_metrics_lock_mutation(ghostty, artifacts):
    source = ghostty / "src/renderer/generic.zig"
    original = source.read_text()
    needle = "fn initialGridMetrics(grid: *font.SharedGrid) font.Metrics {\n"
    if original.count(needle) != 1:
        raise ValueError("surface creation metrics mutation is not unique")
    try:
        source.write_text(original.replace(
            needle, needle + "    grid.lock.lockShared();\n    defer grid.lock.unlockShared();\n", 1))
        red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                              "-Demit-xcframework=false", "-Dtest-filter=surface creation metrics",
                              "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=1800)
        (artifacts / "surface-metrics-lock-mutation-red.log").write_text(red.stdout)
        if (red.returncode == 0 or "surface creation metrics" not in red.stdout
                or "TestUnexpectedResult" not in red.stdout):
            raise ValueError("surface metrics lock mutation did not fail its behavioral test")
        print("C11_GHOSTTY_MUTATION_RED surface-metrics-lock", flush=True)
    finally:
        source.write_text(original)


def check_surface_font_size_lock_mutation(ghostty, artifacts):
    source = ghostty / "src/Surface.zig"
    original = source.read_text()
    needle = "    return self.font_size.points;"
    if original.count(needle) != 1:
        raise ValueError("surface font size mutation is not unique")
    try:
        source.write_text(original.replace(needle,
            "    const grid = self.renderer.font_grid;\n"
            "    grid.lock.lockShared();\n    defer grid.lock.unlockShared();\n" + needle, 1))
        red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                              "-Demit-xcframework=false", "-Dtest-filter=surface font size",
                              "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=1800)
        (artifacts / "surface-font-size-lock-mutation-red.log").write_text(red.stdout)
        if (red.returncode == 0 or "surface font size" not in red.stdout
                or "TestUnexpectedResult" not in red.stdout):
            raise ValueError("surface font size lock mutation did not fail its behavioral test")
        print("C11_GHOSTTY_MUTATION_RED surface-font-size-lock", flush=True)
    finally:
        source.write_text(original)


def check_hyperlink_at_mutations(ghostty, artifacts):
    """The hyperlink lookup must report the URI and its full length (C11H-325)."""
    source = ghostty / "src/Surface.zig"
    original = source.read_text()
    needle = "    return uri.len;\n"
    if original.count(needle) != 1:
        raise ValueError("hyperlink lookup mutation is not unique")
    for label, replacement in (("hyperlink-at-none", "    return 0;\n"),
                               ("hyperlink-at-truncated", "    return n;\n")):
        try:
            source.write_text(original.replace(needle, replacement, 1))
            red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                                  "-Demit-xcframework=false", "-Dtest-filter=hyperlink at viewport",
                                  "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, timeout=1800)
            (artifacts / (label + "-mutation-red.log")).write_text(red.stdout)
            if (red.returncode == 0 or "hyperlink at viewport" not in red.stdout
                    or "TestExpected" not in red.stdout):
                raise ValueError(f"{label} mutation did not fail its behavioral test")
            print(f"C11_GHOSTTY_MUTATION_RED {label}", flush=True)
        finally:
            source.write_text(original)


def check_kitty_direct_only_mutation(ghostty, artifacts):
    """Path media on a direct-only surface must be refused before loading (C11H-363)."""
    source = ghostty / "src/terminal/kitty/graphics_exec.zig"
    original = source.read_text()
    needle = "    return terminal.kitty_graphics_direct_only and t.medium != .direct;\n"
    if original.count(needle) != 1:
        raise ValueError("kitty direct-only mutation is not unique")
    try:
        source.write_text(original.replace(needle, "    _ = terminal;\n    _ = t;\n    return false;\n", 1))
        red = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                              "-Demit-xcframework=false", "-Dtest-filter=kitty path media",
                              "--summary", "all"], cwd=ghostty, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=1800)
        (artifacts / "kitty-direct-only-mutation-red.log").write_text(red.stdout)
        if (red.returncode == 0 or "kitty path media" not in red.stdout
                or "TestExpected" not in red.stdout):
            raise ValueError("kitty direct-only mutation did not fail its behavioral test")
        print("C11_GHOSTTY_MUTATION_RED kitty-direct-only", flush=True)
    finally:
        source.write_text(original)


def main():
    if not os.environ.get("C11_ATLAS_LOCK_OWNER"):
        raise SystemExit("use atlas-build --mode ghosttykit; build-host admission is required")
    root = Path(__file__).resolve().parent.parent
    artifacts = Path(sys.argv[1]).resolve()
    ghostty = root / "ghostty"
    sha = subprocess.check_output(["git", "-C", str(ghostty), "rev-parse", "HEAD"], text=True).strip()
    check_guard_mutation(ghostty, artifacts, "src/main_c.zig", "const out = result orelse return false;",
                         "clipboard request accessor", "clipboard-accessor")
    check_guard_mutation(ghostty, artifacts, "src/config/CApi.zig", "const visit_field = callback orelse return false;",
                         "launch fields visitor", "launch-fields")
    check_key_release_mutation(ghostty, artifacts)
    check_surface_metrics_lock_mutation(ghostty, artifacts)
    check_surface_font_size_lock_mutation(ghostty, artifacts)
    check_hyperlink_at_mutations(ghostty, artifacts)
    check_kitty_direct_only_mutation(ghostty, artifacts)
    test = subprocess.run(["zig", "build", "test", "-j2", "-Demit-macos-app=false",
                           "-Demit-xcframework=false", "-Dtest-filter=transaction encoding",
                           "-Dtest-filter=launch config visitor",
                           "-Dtest-filter=clipboard request accessor",
                           "-Dtest-filter=launch fields visitor",
                           "-Dtest-filter=synchronous key encoding",
                           "-Dtest-filter=surface creation metrics",
                           "-Dtest-filter=surface font size",
                           "-Dtest-filter=hyperlink at viewport",
                           "-Dtest-filter=kitty path media",
                           "--summary", "all"], cwd=ghostty,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
    print(test.stdout, end="", flush=True)
    test.check_returncode()
    count = require_passing_tests(test.stdout)
    print(f"C11_GHOSTTY_TEST_OK tests={count}", flush=True)
    subprocess.run(["zig", "build", "-j2", "-Demit-xcframework=true", "-Demit-macos-app=false",
                    "-Dxcframework-target=universal", "-Doptimize=ReleaseFast"],
                   cwd=ghostty, check=True, timeout=2700)
    kit = ghostty / "macos/GhosttyKit.xcframework"
    if not (kit / "Info.plist").is_file():
        raise ValueError("native build produced no kit")
    archive = artifacts / "GhosttyKit.xcframework.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(kit, arcname="GhosttyKit.xcframework")
    # Chunked, not hashlib.file_digest: The build host runs this with Xcode's python3, 3.9, which lacks it.
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    (artifacts / "ghosttykit-checksum.txt").write_text(f"{sha} {checksum}\n")
    # The app's existing assert-ghosttykit route consumes this SHA-keyed cache.
    # Publishing a release is a separate action; this never contacts GitHub.
    cache = Path.home() / ".cache/cmux/ghosttykit" / sha
    if not cache.exists():
        staged = cache.with_name(sha + ".incoming-" + artifacts.name)
        staged.mkdir(parents=True)
        shutil.copytree(kit, staged / kit.name, symlinks=True)
        staged.rename(cache)
    print(f"GHOSTTYKIT_SHA={sha} GHOSTTYKIT_SHA256={checksum}", flush=True)


if __name__ == "__main__":
    main()
