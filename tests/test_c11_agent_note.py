#!/usr/bin/env python3
"""
C11H-35: each agent wrapper passes the c11 per-launch note by its harness's own flag.

The note is in c11, absent outside a c11 terminal, never duplicated, never replaces a flag
the operator passed, and nothing under HOME (~/.claude, ~/.codex, ...) is written or changed.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import socket
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "Resources" / "bin"
VERSION = "9.9.9"
NOTE_FILES = ("c11-agent-note.sh", "c11-agent-note.txt")

# harness -> (flag the note rides on, the operator-owned flag that must win)
HARNESSES = ("claude", "codex", "grok", "pi", "omp", "opencode")


def run_all(launches: list["Launch"]) -> list["Result"]:
    """Each launch is ~0.3 s of process start-up; the merge gate allows 30 s in all."""
    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(lambda launch: launch.run(), launches))


def tree(path: Path) -> dict[str, bytes | None]:
    out: dict[str, bytes | None] = {}
    for p in sorted(path.rglob("*")):
        out[str(p.relative_to(path))] = p.read_bytes() if p.is_file() else None
    return out


class Launch:
    def __init__(self, harness: str, argv: list[str], *, in_c11: bool = True, with_note: bool = True,
                 env_extra: dict[str, str] | None = None, codex_config: str | None = None,
                 home_files: dict[str, str] | None = None, project_files: dict[str, str] | None = None,
                 note_text: str | None = None, info_extra: dict[str, str] | None = None):
        self.harness, self.argv = harness, argv
        self.in_c11, self.with_note = in_c11, with_note
        self.env_extra = env_extra or {}
        self.codex_config = codex_config
        self.home_files, self.project_files = home_files or {}, project_files or {}
        self.note_text = note_text
        self.info_extra = info_extra or {}

    def run(self) -> "Result":
        with tempfile.TemporaryDirectory(prefix="c11-note-") as td:
            tmp = Path(td)
            contents = tmp / "c11.app" / "Contents"
            bindir = contents / "Resources" / "bin"
            bindir.mkdir(parents=True)
            with (contents / "Info.plist").open("wb") as f:
                plistlib.dump({"CFBundleShortVersionString": VERSION, **self.info_extra}, f)
            shutil.copy2(BIN / self.harness, bindir / self.harness)
            (bindir / self.harness).chmod(0o755)
            if self.with_note:
                for name in NOTE_FILES:
                    shutil.copy2(BIN / name, bindir / name)
            if self.note_text is not None:
                (bindir / "c11-agent-note.txt").write_text(self.note_text)
            for name in ("omp-prompt-cache.ts", "omp-native-mail.ts", "pi-lifecycle.ts"):
                (bindir / name).write_text("// fixture\n")
            shim = bindir / "c11"
            shim.write_text("#!/usr/bin/env bash\nexit 0\n")
            shim.chmod(0o755)

            real = tmp / "real"
            real.mkdir()
            fake = real / self.harness
            fake.write_text(
                "#!/usr/bin/env bash\n"
                'if [[ "${1:-}" == "--version" ]]; then echo 1.15.13; exit 0; fi\n'
                ': > "$FAKE_ARGS"\n'
                'for a in "$@"; do printf "%s\\n" "$a" >> "$FAKE_ARGS"; done\n'
                'printf "%s" "${OPENCODE_CONFIG_CONTENT-}" > "$FAKE_OPENCODE_CONFIG"\n'
                'printf "%s" "${C11_AGENT_NOTE_SENT-unset}" > "$FAKE_NOTE_SENT"\n'
            )
            fake.chmod(0o755)

            home = tmp / "home"
            (home / ".claude").mkdir(parents=True)
            (home / ".claude" / "settings.json").write_text('{"keep":"me"}\n')
            (home / ".codex").mkdir()
            (home / ".codex" / "config.toml").write_text(self.codex_config or 'model = "x"\n')
            for rel, text in self.home_files.items():
                (home / rel).parent.mkdir(parents=True, exist_ok=True)
                (home / rel).write_text(text)
            project = tmp / "proj" / "deep"
            project.mkdir(parents=True)
            for rel, text in self.project_files.items():
                (project / rel).parent.mkdir(parents=True, exist_ok=True)
                (project / rel).write_text(text)
            before = tree(home)

            sock_path = str(tmp / "c11.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(sock_path)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("CMUX_", "C11_", "OPENCODE_", "CODEX_"))}
            env.update(HOME=str(home), PATH=f"{bindir}:{real}:/usr/bin:/bin",
                       FAKE_ARGS=str(tmp / "args.log"),
                       FAKE_OPENCODE_CONFIG=str(tmp / "opencode-config.log"),
                       FAKE_NOTE_SENT=str(tmp / "note-sent.log"))
            if self.in_c11:
                env.update(CMUX_SOCKET_PATH=sock_path, C11_SOCKET_PATH=sock_path,
                           CMUX_SURFACE_ID="22222222-2222-2222-2222-222222222222",
                           CMUX_WORKSPACE_ID="11111111-1111-1111-1111-111111111111")
            env.update(self.env_extra)
            try:
                # Files, not pipes: a wrapper's detached watcher may outlive it briefly and
                # would hold a pipe open.
                with (tmp / "out.log").open("w") as out:
                    proc = subprocess.run([str(bindir / self.harness), *self.argv], cwd=project, env=env,
                                          stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                          text=True, timeout=20)
                proc.stdout, proc.stderr = (tmp / "out.log").read_text(), ""
            finally:
                listener.close()
            args_file = tmp / "args.log"
            args = args_file.read_text().splitlines() if args_file.exists() else None
            config_file = tmp / "opencode-config.log"
            sent_file = tmp / "note-sent.log"
            result = Result(proc, args, config_file.read_text() if config_file.exists() else "",
                            before, tree(home), str(bindir))
            result.note_sent = sent_file.read_text() if sent_file.exists() else None
            return result


class Result:
    def __init__(self, proc, args, opencode_config, home_before, home_after, bindir):
        self.proc, self.args, self.opencode_config = proc, args, opencode_config
        self.home_before, self.home_after, self.bindir = home_before, home_after, bindir


FLAG = {"claude": "--append-system-prompt", "grok": "--rules", "pi": "--append-system-prompt",
        "omp": "--append-system-prompt"}


def note_value(harness: str, args: list[str]) -> list[str]:
    """The note text(s) the wrapper passed, empty when none."""
    if harness == "codex":
        return [a for i, a in enumerate(args) if i and args[i - 1] == "-c" and a.startswith('developer_instructions="c11 ')]
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == FLAG[harness]]


class AgentNoteTests(unittest.TestCase):
    def check_ok(self, r: Result):
        self.assertIsNotNone(r.args, (r.proc.stdout, r.proc.stderr))

    def test_note_is_passed_inside_c11_by_each_harness_flag(self):
        for harness in ("claude", "codex", "grok", "pi", "omp"):
            with self.subTest(harness=harness):
                r = Launch(harness, ["--probe"]).run()
                self.check_ok(r)
                notes = note_value(harness, r.args)
                self.assertEqual(len(notes), 1, (r.args, r.proc.stderr))
                self.assertIn(f"c11 {VERSION}.", notes[0])
                self.assertIn("run `c11 guide`", notes[0])
                # Every agent names its panel on its first task (the SessionStart text that said so left in #267).
                self.assertIn("c11 rename-panel --panel", notes[0])
                self.assertIn("c11 set-description --panel", notes[0])
                self.assertIn("Awaiting first task", notes[0])
                self.assertIn("A command that is not in that guide does not exist in this build", notes[0])
                self.assertIn("does not exist in this build", notes[0])
                self.assertEqual(r.args[-1], "--probe", "operator args stay last")

    def test_note_names_c11_version_line_when_the_bundle_has_one(self):
        cases = (
            ({"C11Version": VERSION + "-h7"}, f"c11 {VERSION}-h7."),
            # An unexpanded build setting is never shown; the plain version is.
            ({"C11Version": "$(MARKETING_VERSION)-h7"}, f"c11 {VERSION}."),
            ({}, f"c11 {VERSION}."),
        )
        for extra, expect in cases:
            with self.subTest(extra=extra):
                r = Launch("claude", ["--probe"], info_extra=extra).run()
                self.check_ok(r)
                notes = note_value("claude", r.args)
                self.assertEqual(len(notes), 1, (r.args, r.proc.stderr))
                self.assertTrue(notes[0].startswith(expect), notes[0])

    def test_claude_tells_its_session_start_hook_whether_the_note_rode_on_the_flag(self):
        """The note is the one launch instruction: the hook sends it only when the flag did not."""
        cases = (
            (["--probe"], {}, "1"),
            (["--append-system-prompt", "mine", "--probe"], {}, "unset"),
            (["--probe"], {"C11_AGENT_NOTE_DISABLED": "1"}, "unset"),
            # An inherited marker never claims a note this launch did not pass.
            (["--append-system-prompt", "mine", "--probe"], {"C11_AGENT_NOTE_SENT": "1"}, "unset"),
        )
        launches = [Launch("claude", argv, env_extra=extra) for argv, extra, _ in cases]
        for (argv, extra, expect), r in zip(cases, run_all(launches)):
            with self.subTest(argv=argv, extra=extra):
                self.check_ok(r)
                self.assertEqual(r.note_sent, expect)

    def test_opencode_gets_the_bundled_note_file_as_an_instruction(self):
        r = Launch("opencode", ["--probe"]).run()
        self.check_ok(r)
        self.assertIn('"instructions":["' + r.bindir + '/c11-agent-note.txt"]', r.opencode_config)
        self.assertEqual(r.opencode_config.count("c11-agent-note.txt"), 1)

    def test_nothing_is_added_outside_a_c11_terminal(self):
        for harness in HARNESSES:
            with self.subTest(harness=harness):
                r = Launch(harness, ["--probe"], in_c11=False).run()
                self.check_ok(r)
                self.assertEqual(r.args, ["--probe"])
                self.assertNotIn("c11-agent-note", r.opencode_config)

    def test_a_missing_note_means_an_unchanged_launch(self):
        for harness in ("claude", "codex", "grok", "pi", "omp"):
            with self.subTest(harness=harness):
                with_note = Launch(harness, ["--probe"]).run()
                without = Launch(harness, ["--probe"], with_note=False).run()
                self.assertEqual(note_value(harness, without.args), [])
                self.assertLess(len(without.args), len(with_note.args))
        r = Launch("opencode", ["--probe"], with_note=False).run()
        self.assertNotIn("instructions", r.opencode_config)

    def test_the_operator_flag_is_never_replaced_or_duplicated(self):
        cases = {
            "claude": (["--append-system-prompt", "mine"], ["mine"]),
            "grok": (["--rules", "mine"], ["mine"]),
        }
        for harness, (argv, expect) in cases.items():
            with self.subTest(harness=harness):
                r = Launch(harness, argv).run()
                self.check_ok(r)
                self.assertEqual(note_value(harness, r.args), expect)
        r = Launch("claude", ["--append-system-prompt-file", "/x"]).run()
        self.assertEqual(note_value("claude", r.args), [])
        r = Launch("grok", ["--rules=mine"]).run()
        self.assertEqual(note_value("grok", r.args), [])
        # Codex: by flag in either spelling, and in the operator's own config.toml.
        for argv in (["-c", 'developer_instructions="mine"'], ["--config=developer_instructions=\"mine\""],
                     ['-cdeveloper_instructions="mine"']):
            with self.subTest(codex=argv):
                self.assertEqual(note_value("codex", Launch("codex", argv).run().args), [])
        r = Launch("codex", ["--probe"], codex_config='developer_instructions = "mine"\n').run()
        self.assertEqual(note_value("codex", r.args), [])
        # Pi and omp repeat the flag; the operator's comes after ours, so theirs wins.
        for harness in ("pi", "omp"):
            with self.subTest(harness=harness):
                r = Launch(harness, ["--append-system-prompt", "mine"]).run()
                self.assertEqual(r.args[-2:], ["--append-system-prompt", "mine"])
                self.assertEqual(len(note_value(harness, r.args)), 2)

    def test_codex_yields_to_developer_instructions_in_any_layer_a_dash_c_would_replace(self):
        mine = 'developer_instructions = "repo rules"\n'
        cases = {
            "project config in the working directory's parent": dict(project_files={"../.codex/config.toml": mine}),
            "project config in the working directory": dict(project_files={".codex/config.toml": mine}),
            "profile file, --profile NAME": dict(home_files={".codex/work.config.toml": mine}, argv=["--profile", "work"]),
            "profile file, --profile=NAME": dict(home_files={".codex/work.config.toml": mine}, argv=["--profile=work"]),
            "profile file, -p NAME": dict(home_files={".codex/work.config.toml": mine}, argv=["-p", "work"]),
            "profile file, -pNAME": dict(home_files={".codex/work.config.toml": mine}, argv=["-pwork"]),
            "quoted key in the user file": dict(codex_config='"developer_instructions" = "mine"\n'),
            "--config KEY as two tokens": dict(argv=["--config", 'developer_instructions="mine"']),
        }
        launches = [Launch("codex", kw.pop("argv", ["--probe"]), **kw) for kw in cases.values()]
        # A profile file for a different profile does not count; the note is still passed.
        launches.append(Launch("codex", ["--profile", "other"], home_files={".codex/work.config.toml": mine}))
        results = run_all(launches)
        for name, r in zip(cases, results):
            with self.subTest(layer=name):
                self.check_ok(r)
                self.assertEqual(note_value("codex", r.args), [], r.args)
        self.assertEqual(len(note_value("codex", results[-1].args)), 1, results[-1].args)

    def test_pi_and_omp_leave_a_discoverable_append_system_file_to_the_harness(self):
        cases = {
            "pi": {"user agent dir": dict(home_files={".pi/agent/APPEND_SYSTEM.md": "x"}),
                   "project": dict(project_files={".pi/APPEND_SYSTEM.md": "x"})},
            "omp": {"user .omp/agent": dict(home_files={".omp/agent/APPEND_SYSTEM.md": "x"}),
                    "user .claude": dict(home_files={".claude/APPEND_SYSTEM.md": "x"}),
                    "user .gemini": dict(home_files={".gemini/APPEND_SYSTEM.md": "x"}),
                    "project .omp": dict(project_files={".omp/APPEND_SYSTEM.md": "x"}),
                    "project .codex": dict(project_files={".codex/APPEND_SYSTEM.md": "x"})},
        }
        jobs = [(h, n, Launch(h, ["--probe"], **kw)) for h, layers in cases.items() for n, kw in layers.items()]
        jobs += [(h, "none", Launch(h, ["--probe"])) for h in cases]
        for (harness, name, _), r in zip(jobs, run_all([j[2] for j in jobs])):
            with self.subTest(harness=harness, layer=name):
                self.check_ok(r)
                # With none of those files, the note is still passed.
                self.assertEqual(len(note_value(harness, r.args)), 1 if name == "none" else 0, r.args)

    def test_the_operator_can_turn_the_note_off(self):
        for harness in ("claude", "codex", "grok", "pi", "omp"):
            with self.subTest(harness=harness):
                r = Launch(harness, ["--probe"], env_extra={"C11_AGENT_NOTE_DISABLED": "1"}).run()
                self.assertEqual(note_value(harness, r.args), [])
        r = Launch("opencode", ["--probe"], env_extra={"C11_AGENT_NOTE_DISABLED": "1"}).run()
        self.check_ok(r)
        self.assertNotIn("instructions", r.opencode_config)

    def test_codex_quoting_survives_a_toml_string(self):
        r = Launch("codex", ["--probe"], note_text='say "hi" and keep a \\ backslash\n').run()
        value = note_value("codex", r.args)[0]
        self.assertEqual(value, 'developer_instructions="c11 9.9.9. say \\"hi\\" and keep a \\\\ backslash"')

    def test_harness_config_under_home_is_untouched(self):
        for harness in HARNESSES:
            with self.subTest(harness=harness):
                r = Launch(harness, ["--probe"]).run()
                self.check_ok(r)
                self.assertEqual(r.home_before, r.home_after)
                self.assertEqual(r.home_after[".claude/settings.json"], b'{"keep":"me"}\n')


if __name__ == "__main__":
    unittest.main()
