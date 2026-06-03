from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shutil
from typing import Any

from .adapter_client import AdapterClient
from .artifacts import RunArtifacts
from .c11_oracle import C11Oracle, TaggedC11, count_panes
from .responses_loop import ResponsesComputerLoop
from .safety import SafetyLimits


@dataclass(frozen=True)
class ScenarioConfig:
    repo_root: Path
    tag: str
    model: str
    build: bool = False
    max_actions: int = 25
    max_seconds: int = 180

    @property
    def tagged(self) -> TaggedC11:
        return TaggedC11(tag=self.tag, repo_root=self.repo_root)


SCENARIO_PROMPTS: dict[str, str] = {
    "launch-window": """You are testing the c11 macOS app through a computer-use screenshot.

Inspect the visible c11 window and report whether the app appears ready for operator use. Do not edit files. If the app is still launching, wait once and inspect again.
""",
    "create-split": """You are testing c11 through its visible macOS UI.

Create one new terminal split using the visible UI or a normal user keyboard shortcut. Inspect the screen first. Do not use terminal commands, socket commands, or shell shortcuts as the action path. Stop and explain if no user-facing split affordance or shortcut is reasonably available from the visible state.
""",
    "focus-and-type": """You are testing c11 terminal focus and keyboard event routing through the visible macOS UI.

Click inside the visible terminal surface, type exactly:
printf 'openai-cua-ok\\n'

Then press Enter. Do not use socket commands or paste through any out-of-band mechanism.
""",
}


def make_adapter(config: ScenarioConfig) -> AdapterClient:
    return AdapterClient(bundle_id=config.tagged.bundle_id, app_path=config.tagged.app_path, repo_root=config.repo_root)


def run_doctor(config: ScenarioConfig, *, launch: bool = False) -> dict[str, Any]:
    adapter = make_adapter(config)
    result: dict[str, Any] = {
        "openai_api_key_present": bool(os.environ.get("OPENAI_API_KEY")),
        "openai_model": config.model,
        "adapter_executable": str(adapter.executable),
        "adapter_available": adapter.available(),
        "tag": config.tag,
        "bundle_id": config.tagged.bundle_id,
        "app_path": str(config.tagged.app_path),
        "app_exists": config.tagged.app_path.exists(),
        "socket_path": str(config.tagged.socket_path),
        "socket_exists": config.tagged.socket_path.exists(),
        "build_command": f"./scripts/reload.sh --tag {config.tag}",
        "launch_command": f"./scripts/launch-tagged-automation.sh {config.tag} --wait-socket 10",
    }
    if not adapter.available():
        result["adapter_build_command"] = f"swift build --package-path {adapter.package_dir}"
        return result
    if launch:
        result["launch_output"] = _launch_tagged(config)
    try:
        result["adapter_doctor"] = adapter.doctor()
    except Exception as exc:
        result["adapter_doctor_error"] = str(exc)
    return result


def run_smoke(config: ScenarioConfig) -> dict[str, Any]:
    adapter = make_adapter(config)
    if not adapter.available():
        adapter.build()
    artifacts = RunArtifacts.create("smoke", config.repo_root / "artifacts/openai-cua-runs")
    doctor = adapter.doctor()
    blocked = _permission_block(doctor)
    if blocked:
        run = {"ok": False, "blocked": True, "reason": blocked, "adapter_doctor": doctor, "artifacts": str(artifacts.root)}
        artifacts.write_json("run.json", run)
        return run
    launch_result = _launch_tagged(config)
    artifacts.write_text("logs/launch.txt", launch_result.get("stdout", ""))
    adapter_launch = adapter.launch(wait=10)
    shot = artifacts.screenshot_path(0, "initial")
    observation = adapter.observe(out=shot, frontmost_required=False)
    oracle = C11Oracle(config.tagged)
    tree = oracle.tree()
    identify = oracle.identify()
    artifacts.write_json("c11/tree-before.json", tree)
    artifacts.write_json("c11/identify.json", identify)
    run = {
        "ok": launch_result["returncode"] == 0 and bool(observation.get("ok")),
        "artifacts": str(artifacts.root),
        "launch": launch_result,
        "adapter_launch": adapter_launch,
        "observation": observation,
        "tree_panes": count_panes(tree),
    }
    artifacts.write_json("run.json", run)
    return run


def run_scenario(name: str, config: ScenarioConfig) -> dict[str, Any]:
    if name not in SCENARIO_PROMPTS:
        raise ValueError(f"unknown scenario: {name}")
    if not os.environ.get("OPENAI_API_KEY"):
        return {"ok": False, "blocked": True, "reason": "OPENAI_API_KEY is not present in the environment"}

    adapter = make_adapter(config)
    if not adapter.available():
        adapter.build()
    artifacts = RunArtifacts.create(name, config.repo_root / "artifacts/openai-cua-runs")
    doctor = adapter.doctor()
    blocked = _permission_block(doctor)
    if blocked:
        run = {"ok": False, "blocked": True, "reason": blocked, "adapter_doctor": doctor, "artifacts": str(artifacts.root)}
        artifacts.write_json("run.json", run)
        return run
    launch_result = _launch_tagged(config)
    artifacts.write_text("logs/launch.txt", launch_result.get("stdout", ""))
    if launch_result["returncode"] != 0:
        run = {"ok": False, "blocked": True, "reason": "tagged c11 launch failed", "launch": launch_result, "artifacts": str(artifacts.root)}
        artifacts.write_json("run.json", run)
        return run

    adapter.launch(wait=10)
    initial_shot = artifacts.screenshot_path(0, "initial")
    adapter.observe(out=initial_shot, frontmost_required=False)
    oracle = C11Oracle(config.tagged)
    before = oracle.tree()
    artifacts.write_json("c11/tree-before.json", before)

    loop = ResponsesComputerLoop(
        adapter=adapter,
        artifacts=artifacts,
        model=config.model,
        limits=SafetyLimits(max_actions=config.max_actions, max_seconds=config.max_seconds),
    )
    prompt = SCENARIO_PROMPTS[name]
    try:
        loop_result = loop.run(prompt)
    except Exception as exc:
        after_error = oracle.tree()
        artifacts.write_json("c11/tree-after-error.json", after_error)
        run = {
            "ok": False,
            "scenario": name,
            "model": config.model,
            "artifacts": str(artifacts.root),
            "error": str(exc),
        }
        artifacts.write_json("run.json", run)
        return run
    after = oracle.tree()
    artifacts.write_json("c11/tree-after.json", after)

    oracle_result = _oracle_result(name, oracle, before, after)
    run = {
        "ok": bool(loop_result.get("ok")) and oracle_result.get("ok", True),
        "scenario": name,
        "model": config.model,
        "artifacts": str(artifacts.root),
        "loop": loop_result,
        "oracle": oracle_result,
    }
    artifacts.write_json("run.json", run)
    return run


def _launch_tagged(config: ScenarioConfig) -> dict[str, Any]:
    if config.build:
        build = config.tagged.build()
        if build.returncode != 0:
            return {"returncode": build.returncode, "stdout": build.stdout, "phase": "build"}
    if not config.tagged.app_path.exists():
        return {
            "returncode": 2,
            "stdout": f"tagged app not found at {config.tagged.app_path}\nrun: ./scripts/reload.sh --tag {config.tag}\n",
            "phase": "preflight",
        }
    launch = config.tagged.launch(wait_socket=10)
    return {"returncode": launch.returncode, "stdout": launch.stdout, "phase": "launch"}


def _oracle_result(name: str, oracle: C11Oracle, before: Any, after: Any) -> dict[str, Any]:
    if name == "create-split":
        before_count = count_panes(before)
        after_count = count_panes(after)
        return {"ok": after_count > before_count, "before_panes": before_count, "after_panes": after_count}
    if name == "focus-and-type":
        screen = oracle.read_screen(lines=120)
        stdout = screen.get("stdout", "") if isinstance(screen, dict) else ""
        return {"ok": "openai-cua-ok" in stdout, "read_screen_contains_expected": "openai-cua-ok" in stdout}
    if name == "launch-window":
        after_count = count_panes(after)
        return {"ok": after_count >= 1, "after_panes": after_count}
    return {"ok": True}


def _permission_block(doctor: dict[str, Any]) -> str | None:
    permissions = doctor.get("permissions", {})
    missing: list[str] = []
    if not permissions.get("screenRecording"):
        missing.append("Screen Recording")
    if not permissions.get("accessibility"):
        missing.append("Accessibility")
    if not missing:
        return None
    remediation = " ".join(permissions.get("remediation", []))
    return f"missing macOS permission(s): {', '.join(missing)}. {remediation}".strip()


def dependency_report() -> dict[str, Any]:
    return {
        "python": shutil.which("python3"),
        "swift": shutil.which("swift"),
        "c11": shutil.which("c11"),
    }
