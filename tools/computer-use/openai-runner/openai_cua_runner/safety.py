from __future__ import annotations

from dataclasses import dataclass
import time


class SafetyBlocked(RuntimeError):
    pass


@dataclass(frozen=True)
class SafetyLimits:
    max_actions: int = 25
    max_seconds: int = 180
    allow_system_prompts: bool = False


class SafetyBudget:
    def __init__(self, limits: SafetyLimits) -> None:
        self.limits = limits
        self.started = time.monotonic()
        self.actions = 0

    def record_action(self) -> None:
        self.actions += 1
        if self.actions > self.limits.max_actions:
            raise SafetyBlocked(f"max action count exceeded: {self.limits.max_actions}")
        elapsed = time.monotonic() - self.started
        if elapsed > self.limits.max_seconds:
            raise SafetyBlocked(f"max wall time exceeded: {self.limits.max_seconds}s")
