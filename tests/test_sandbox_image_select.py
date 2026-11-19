#!/usr/bin/env python3
"""sandbox-up picks a serial slot, then clones that slot's image.

Runs scripts/sandbox-up.sh against a stand-in tart (C11_SANDBOX_TART_BIN) under a
throwaway HOME, so no VM, real ~/.c11-sandbox state or real tart is touched. The fake
`tart set` fails, so each run stops right after its clone; the clone call and the
run's golden/image records are what is checked.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SANDBOX_UP = REPO / "scripts" / "sandbox-up.sh"

FAKE_TART = r'''#!/usr/bin/env python3
import json, os, sys
state = os.environ["FAKE_TART_STATE"]
with open(state) as f:
    vms = json.load(f)
calls = os.environ["FAKE_TART_CALLS"]
with open(calls, "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
def save():
    with open(state, "w") as f:
        json.dump(vms, f)
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "list":
    print("Source Name Disk Size Accessed State")
    for name, st in vms.items():
        print(f"local {name} 50 32 now {st}")
elif cmd == "clone":
    src, dst = sys.argv[2], sys.argv[3]
    if src not in vms:
        sys.exit(f"no such vm {src}")
    vms[dst] = "stopped"; save()
elif cmd == "set":
    sys.exit(1)  # stop the run right after the clone
elif cmd == "delete":
    vms.pop(sys.argv[2], None); save()
elif cmd == "stop":
    pass
else:
    sys.exit(f"fake tart: unsupported {cmd}")
'''

C11_A, C11_B = "c11-sandbox-golden", "c11-sandbox-golden-b"
H_A, H_B = "c11h-sandbox-golden", "c11h-sandbox-golden-b"


class SandboxImageSelect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.home = t / "home"
        (self.home / ".ssh").mkdir(parents=True)
        (self.home / ".ssh" / "c11-sandbox").write_text("not a key\n")
        self.root = self.home / ".c11-sandbox"
        self.tart = t / "tart"
        self.tart.write_text(FAKE_TART)
        self.tart.chmod(0o755)
        self.state = t / "vms.json"
        self.calls = t / "calls.jsonl"
        self.calls.write_text("")
        app = t / "Probe.app" / "Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_text("<plist/>\n")
        self.app = t / "Probe.app"

    def tearDown(self):
        self.tmp.cleanup()

    def vms(self, **vms):
        self.state.write_text(json.dumps(vms))

    def record(self, run_id, name, value):
        d = self.root / "runs" / run_id
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(value + "\n")

    def run_up(self, run_id, *extra, images=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
        env.update(HOME=str(self.home), C11_SANDBOX_HOST="local", C11_SANDBOX_TART_BIN=str(self.tart),
                   FAKE_TART_STATE=str(self.state), FAKE_TART_CALLS=str(self.calls))
        if images:
            env.update(C11_SANDBOX_IMAGE=H_A, C11_SANDBOX_IMAGE_B=H_B)
        return subprocess.run([str(SANDBOX_UP), run_id, str(self.app), *extra], env=env,
                              capture_output=True, text=True, timeout=120)

    def clones(self):
        return [c[1:] for c in map(json.loads, self.calls.read_text().splitlines()) if c[0] == "clone"]

    def recorded(self, run_id, name):
        return (self.root / "runs" / run_id / name).read_text().strip()

    def test_default_clones_the_golden(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped"})
        self.run_up("t1")
        self.assertEqual(self.clones(), [[C11_A, "c11-sb-t1"]])
        self.assertEqual(self.recorded("t1", "golden"), C11_A)
        self.assertEqual(self.recorded("t1", "image"), C11_A)

    def test_image_clones_the_image_and_records_the_slot(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", H_A: "stopped", H_B: "stopped"})
        self.run_up("t2", images=True)
        self.assertEqual(self.clones(), [[H_A, "c11-sb-t2"]])
        # c11's own scripts read this record to keep serials apart: it must stay the c11 slot.
        self.assertEqual(self.recorded("t2", "golden"), C11_A)
        self.assertEqual(self.recorded("t2", "image"), H_A)

    def test_second_guest_takes_slot_b_image_when_c11_holds_slot_a(self):
        # A c11 guest (recorded the way c11's unchanged sandbox-up records it) holds serial A.
        self.vms(**{C11_A: "stopped", C11_B: "stopped", H_A: "stopped", H_B: "stopped",
                    "c11-sb-c11-other": "running"})
        self.record("c11-other", "golden", C11_A)
        self.run_up("t3", "--allow-second", images=True)
        self.assertEqual(self.clones(), [[H_B, "c11-sb-t3"]])
        self.assertEqual(self.recorded("t3", "golden"), C11_B)
        self.assertEqual(self.recorded("t3", "image"), H_B)

    def test_c11_guest_holding_slot_a_sends_the_next_one_to_b(self):
        # An earlier c11 guest cloned from the A image: its record says serial A.
        self.vms(**{C11_A: "stopped", C11_B: "stopped", H_A: "stopped", H_B: "stopped",
                    "c11-sb-t4a": "running"})
        self.record("t4a", "golden", C11_A)
        self.record("t4a", "image", H_A)
        self.run_up("t4", "--allow-second")  # a c11-style run with no image vars
        self.assertEqual(self.clones(), [[C11_B, "c11-sb-t4"]])

    def test_missing_image_fails_before_any_clone(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", H_B: "stopped"})
        r = self.run_up("t5", images=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"golden image {H_A} is missing", r.stderr)
        self.assertEqual(self.clones(), [])

    def test_running_image_fails_before_any_clone(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", H_A: "running", H_B: "stopped"})
        r = self.run_up("t6", images=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"{H_A} is running", r.stderr)
        self.assertEqual(self.clones(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
