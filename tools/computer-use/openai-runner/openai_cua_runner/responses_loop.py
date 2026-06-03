from __future__ import annotations

import base64
import os
from pathlib import Path
from typing import Any

from .adapter_client import AdapterClient
from .artifacts import RunArtifacts
from .safety import SafetyBudget, SafetyLimits


def _dump(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    if isinstance(value, list):
        return [_dump(item) for item in value]
    if isinstance(value, dict):
        return {key: _dump(item) for key, item in value.items()}
    return value


def _get(value: Any, key: str, default: Any = None) -> Any:
    if isinstance(value, dict):
        return value.get(key, default)
    return getattr(value, key, default)


def _response_output(response: Any) -> list[Any]:
    return list(_get(response, "output", []) or [])


def _output_text(response: Any) -> str:
    direct = _get(response, "output_text")
    if isinstance(direct, str) and direct:
        return direct
    chunks: list[str] = []
    for item in _response_output(response):
        if _get(item, "type") == "message":
            for content in _get(item, "content", []) or []:
                text = _get(content, "text")
                if text:
                    chunks.append(text)
    return "\n".join(chunks)


def _computer_calls(response: Any) -> list[Any]:
    return [item for item in _response_output(response) if _get(item, "type") == "computer_call"]


def _normalize_action(action: dict[str, Any]) -> dict[str, Any]:
    action_type = action.get("type") or action.get("action")
    normalized: dict[str, Any] = {"type": action_type}
    for src, dst in [
        ("x", "x"), ("y", "y"), ("button", "button"), ("text", "text"),
        ("dx", "dx"), ("dy", "dy"), ("scroll_x", "dx"), ("scroll_y", "dy"),
        ("scrollX", "dx"), ("scrollY", "dy"), ("duration_ms", "durationMs"),
        ("durationMs", "durationMs"), ("path", "path")
    ]:
        if src in action:
            normalized[dst] = action[src]
    if "keys" in action:
        normalized["keys"] = action["keys"]
    elif "key" in action:
        normalized["keys"] = [action["key"]]
    return {key: value for key, value in normalized.items() if value is not None}


def _call_actions(call: Any) -> list[dict[str, Any]]:
    actions = _get(call, "actions")
    if actions:
        return [_normalize_action(_dump(action)) for action in actions]
    action = _get(call, "action")
    if action:
        return [_normalize_action(_dump(action))]
    return []


class ResponsesComputerLoop:
    def __init__(
        self,
        *,
        adapter: AdapterClient,
        artifacts: RunArtifacts,
        model: str,
        limits: SafetyLimits | None = None,
    ) -> None:
        self.adapter = adapter
        self.artifacts = artifacts
        self.model = model
        self.budget = SafetyBudget(limits or SafetyLimits())

    def run(self, prompt: str) -> dict[str, Any]:
        try:
            from openai import OpenAI
        except ImportError as exc:
            raise RuntimeError("openai package is not installed; run from tools/computer-use/openai-runner with your Python env installed") from exc

        request_timeout = float(os.environ.get("OPENAI_CUA_REQUEST_TIMEOUT", "120"))
        client = OpenAI(timeout=request_timeout)
        self.artifacts.write_text("prompt.md", prompt)
        response = client.responses.create(
            model=self.model,
            tools=[{"type": "computer"}],
            input=prompt,
        )
        self.artifacts.write_json("response-000.json", _dump(response))

        turn = 0
        while True:
            calls = _computer_calls(response)
            if not calls:
                final = _output_text(response)
                self.artifacts.write_text("final.md", final)
                return {"ok": True, "final": final, "actions": self.budget.actions, "response_id": _get(response, "id")}

            outputs: list[dict[str, Any]] = []
            for call in calls:
                call_id = _get(call, "call_id") or _get(call, "id")
                pending_safety = _get(call, "pending_safety_checks") or []
                if pending_safety:
                    raise RuntimeError(f"computer call returned pending safety checks; stopping fail-closed: {pending_safety}")
                actions = _call_actions(call)
                if not actions:
                    actions = [{"type": "screenshot"}]
                for action in actions:
                    self.budget.record_action()
                    self.artifacts.append_jsonl("actions.jsonl", {"turn": turn, "call_id": call_id, "action": action})
                    if action["type"] != "screenshot":
                        self.adapter.launch(wait=2)
                        result = self.adapter.act(action)
                        self.artifacts.append_jsonl("actions.jsonl", {"turn": turn, "call_id": call_id, "result": result})
                    self.adapter.launch(wait=2)
                    shot = self.artifacts.screenshot_path(self.budget.actions, f"after-{action['type']}")
                    obs = self.adapter.observe(out=shot, include_base64=False)
                    self.artifacts.append_jsonl("observations.jsonl", {"turn": turn, "call_id": call_id, "observation": obs})
                    image_url = self._image_data_url(shot)
                    outputs.append({
                        "type": "computer_call_output",
                        "call_id": call_id,
                        "output": {
                            "type": "input_image",
                            "image_url": image_url,
                        },
                    })

            turn += 1
            response = client.responses.create(
                model=self.model,
                tools=[{"type": "computer"}],
                previous_response_id=_get(response, "id"),
                input=outputs,
            )
            self.artifacts.write_json(f"response-{turn:03d}.json", _dump(response))

    @staticmethod
    def _image_data_url(path: Path) -> str:
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        return f"data:image/png;base64,{encoded}"
