from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from .scenarios import ScenarioConfig, dependency_report, run_doctor, run_scenario, run_smoke


DEFAULT_TAG = "openai-cua"
DEFAULT_MODEL = os.environ.get("OPENAI_CUA_MODEL", "gpt-5.5")


def repo_root_from_here() -> Path:
    return Path(__file__).resolve().parents[4]


def config_from_args(args: argparse.Namespace) -> ScenarioConfig:
    return ScenarioConfig(
        repo_root=Path(args.repo_root).resolve(),
        tag=args.tag,
        model=args.model,
        build=args.build,
        max_actions=args.max_actions,
        max_seconds=args.max_seconds,
    )


def main(argv: list[str] | None = None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo-root", default=str(repo_root_from_here()))
    common.add_argument("--tag", default=DEFAULT_TAG)
    common.add_argument("--model", default=DEFAULT_MODEL)
    common.add_argument("--build", action="store_true", help="Run ./scripts/reload.sh --tag before launch/smoke/scenario.")
    common.add_argument("--max-actions", type=int, default=25)
    common.add_argument("--max-seconds", type=int, default=180)

    parser = argparse.ArgumentParser(prog="python -m openai_cua_runner")
    sub = parser.add_subparsers(dest="command", required=True)
    doctor = sub.add_parser("doctor", parents=[common], help="Check environment, adapter, target app, permissions, and API key.")
    doctor.add_argument("--launch", action="store_true", help="Launch tagged c11 before adapter doctor checks.")
    sub.add_parser("smoke", parents=[common], help="Launch tagged c11 and capture one screenshot without a model call.")
    scenario = sub.add_parser("scenario", parents=[common], help="Run one OpenAI computer-use scenario.")
    scenario.add_argument("name", choices=["launch-window", "create-split", "focus-and-type"])
    sub.add_parser("deps", help="Show local dependency paths.")

    args = parser.parse_args(argv)
    if args.command == "deps":
        print(json.dumps(dependency_report(), indent=2, sort_keys=True))
        return 0

    config = config_from_args(args)
    try:
        if args.command == "doctor":
            result = run_doctor(config, launch=args.launch)
        elif args.command == "smoke":
            result = run_smoke(config)
        elif args.command == "scenario":
            result = run_scenario(args.name, config)
        else:
            raise AssertionError(args.command)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, indent=2, sort_keys=True))
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get("ok") is False and not result.get("blocked"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
