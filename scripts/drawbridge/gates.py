#!/usr/bin/env python3
"""Drawbridge deterministic gates (lane 2).

Plain code, not an LLM. The judge's verdict is ONE input; nothing here trusts it
alone. Every autonomous action requires every gate to pass. Any error, missing
input, or malformed file fails safe to the review lane (non-zero exit).

Inputs are plain JSON files fetched by the workflow (or fixtures in tests):
  --policy       TRIAGE_POLICY.md (machine config block is parsed out of it)
  --verdict      judge verdict JSON
  --item-type    pr | issue
  --pr-json      `gh api repos/{r}/pulls/{n}` output            (PRs only)
  --files-json   `gh api repos/{r}/pulls/{n}/files --paginate`  (PRs only)
  --checks-json  `gh api repos/{r}/commits/{sha}/check-runs`    (PRs only)
  --skip-ci      mark the CI gate "pending" instead of reading checks-json
  --output       where to write the gates result JSON (default stdout)

Exit codes: 0 = evaluated (route in output), 2 = bad invocation/input (caller
must treat as escalation).
"""

import argparse
import json
import re
import sys

FIRST_TIMER_ASSOCIATIONS = {"FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "NONE", "MANNEQUIN"}
GREEN_CONCLUSIONS = {"success", "neutral", "skipped"}
# Check runs spawned by drawbridge's own workflow; excluded from the CI gate.
SELF_CHECK_PREFIX = "drawbridge"

CONFIG_FENCE_RE = re.compile(
    r"```json[ \t]+drawbridge-config[ \t]*\n(.*?)\n```", re.DOTALL
)


def load_policy_config(policy_path):
    with open(policy_path, encoding="utf-8") as f:
        text = f.read()
    m = CONFIG_FENCE_RE.search(text)
    if not m:
        raise ValueError(f"no ```json drawbridge-config block found in {policy_path}")
    return json.loads(m.group(1))


def synthesize_escalation(reason):
    """The one fail-safe verdict, shared by main() and --emit-escalation."""
    return {
        "scope_fit": "low",
        "alignment": "low",
        "category": "other",
        "risk_flags": [reason],
        "verdict": "maintainer_review",
        "reasoning": f"Escalated fail-safe: {reason}.",
    }


def glob_to_regex(pattern):
    """Translate a drawbridge glob to an anchored regex.

    `**` crosses path segments, `*` stays within one segment. A pattern with no
    glob characters matches that exact path.
    """
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i : i + 3] == "**/":
                out.append("(?:[^/]+/)*")
                i += 3
            elif pattern[i : i + 2] == "**":
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("".join(out) + r"\Z")


def match_any(path, patterns, casefold=False):
    """Match path against glob patterns.

    casefold=True is used for DENY matching only: this project is developed on
    case-insensitive filesystems, so `docs/claude.md` must hit the `**/CLAUDE.md`
    deny entry. Allowlists stay case-sensitive — an unexpected-case path then
    simply fails the allowlist and escalates (fail-safe).
    """
    if casefold:
        path = path.casefold()
        patterns = [p.casefold() for p in patterns]
    return any(glob_to_regex(p).match(path) for p in patterns)


# Modes a PR may introduce on the autonomous lane: regular and executable
# blobs. Symlinks (120000) and gitlinks/submodules (160000) always escalate.
REGULAR_FILE_MODES = {"100644", "100755"}


def touched_paths(files):
    """All paths a PR touches, including rename sources."""
    paths = set()
    for f in files:
        paths.add(f["filename"])
        if f.get("previous_filename"):
            paths.add(f["previous_filename"])
    return sorted(paths)


def resolve_tier(config, association):
    for name, tier in config["tiers"].items():
        if association in tier["associations"]:
            return name, tier
    return None, None


def valid_verdict(verdict):
    return (
        isinstance(verdict, dict)
        and verdict.get("scope_fit") in {"high", "medium", "low"}
        and verdict.get("alignment") in {"high", "medium", "low"}
        and isinstance(verdict.get("risk_flags"), list)
        and verdict.get("verdict") in {"autonomous", "maintainer_review", "close_suggest"}
    )


def evaluate_pr(config, verdict, pr, files, checks, skip_ci, judged_sha=None, tree=None):
    gates = {}

    def gate(name, ok, detail):
        gates[name] = {"pass": bool(ok), "detail": detail}

    # Gate: judged head is current — the verdict must describe the same head
    # SHA the gates are evaluating, or an older autonomous verdict could be
    # applied to a newer pushed head.
    current_sha = (pr.get("head") or {}).get("sha")
    gate(
        "judged_head_current",
        bool(judged_sha) and bool(current_sha) and judged_sha == current_sha,
        f"judged={judged_sha} current={current_sha}",
    )

    # Gate: judge verdict — autonomous requires high/high and zero risk flags.
    flags = verdict.get("risk_flags", [])
    gate(
        "judge_verdict",
        verdict.get("verdict") == "autonomous"
        and verdict.get("scope_fit") == "high"
        and verdict.get("alignment") == "high"
        and not flags,
        f"verdict={verdict.get('verdict')} scope_fit={verdict.get('scope_fit')} "
        f"alignment={verdict.get('alignment')} risk_flags={flags}",
    )

    # Gate: trust tier — first-timers and unknowns never pass (spec MUST 5).
    association = pr.get("author_association", "NONE")
    tier_name, tier = resolve_tier(config, association)
    if association in FIRST_TIMER_ASSOCIATIONS or tier is None:
        gate("trust_tier", False, f"author_association={association} (no autonomous tier)")
        allowed_categories = []
    else:
        gate("trust_tier", True, f"author_association={association} tier={tier_name}")
        allowed_categories = list(tier["categories"])

    # The bugfix category is only in play when the judge classified the change
    # as a bug fix — the verdict feeds the gate but path bounds still apply.
    if "bugfix" in allowed_categories and verdict.get("category") != "bugfix":
        allowed_categories.remove("bugfix")

    paths = touched_paths(files)

    # Gate: deny list — always escalates, regardless of anything else.
    # Case-insensitive: see match_any.
    denied = [p for p in paths if match_any(p, config["deny_paths"], casefold=True)]
    gate("no_denied_paths", not denied, f"denied={denied}" if denied else "no denied paths")

    # Gate: regular files only — the autonomous lane may not introduce
    # symlinks or gitlinks/submodules. Checked against the head tree (the
    # Files API does not expose modes). Deleted paths are absent from the
    # head tree and are fine.
    if tree is None:
        gate("regular_files_only", False, "head tree not provided — cannot verify file modes")
    elif tree.get("truncated"):
        gate("regular_files_only", False, "head tree truncated — cannot verify file modes")
    else:
        modes = {e["path"]: e.get("mode") for e in tree.get("tree", [])}
        irregular = [
            f"{f['filename']} (mode {modes[f['filename']]})"
            for f in files
            if f["filename"] in modes and modes[f["filename"]] not in REGULAR_FILE_MODES
        ]
        gate(
            "regular_files_only",
            not irregular,
            f"irregular={irregular}" if irregular else "all touched paths are regular files",
        )

    # Gate: allowlist — every touched path inside the tier's allowed categories.
    allowed_patterns = []
    for cat in allowed_categories:
        allowed_patterns.extend(config["categories"][cat])
    outside = [p for p in paths if not match_any(p, allowed_patterns)]
    gate(
        "paths_allowed",
        bool(paths) and not outside,
        f"categories={allowed_categories} outside_allowlist={outside}"
        if outside or not paths
        else f"all {len(paths)} paths in categories={allowed_categories}",
    )

    # Gate: size cap.
    cap = config["size_cap"]
    lines = pr.get("additions", 0) + pr.get("deletions", 0)
    nfiles = pr.get("changed_files", len(files))
    gate(
        "size_cap",
        lines <= cap["max_changed_lines"] and nfiles <= cap["max_changed_files"],
        f"{lines} lines / {nfiles} files (cap {cap['max_changed_lines']}/{cap['max_changed_files']})",
    )

    # Gate: not a draft.
    gate("not_draft", not pr.get("draft", False), f"draft={pr.get('draft', False)}")

    # Gate: CI fully green.
    if skip_ci:
        gate("ci_green", False, "skipped (pre-CI pass) — pending")
    else:
        runs = [
            r
            for r in checks.get("check_runs", [])
            if not r.get("name", "").lower().startswith(SELF_CHECK_PREFIX)
        ]
        # CI path-ignores docs-tier paths; such diffs legitimately have zero
        # check runs and are exempt from the required-checks list below.
        all_ignored = bool(paths) and all(
            match_any(p, config["ci_ignored_paths"]) for p in paths
        )
        pending = [r["name"] for r in runs if r.get("status") != "completed"]
        red = [
            r["name"]
            for r in runs
            if r.get("status") == "completed"
            and r.get("conclusion") not in GREEN_CONCLUSIONS
        ]
        if not runs:
            gate(
                "ci_green",
                all_ignored,
                "no check runs; all paths CI-ignored"
                if all_ignored
                else "no check runs and paths are not CI-ignored",
            )
        else:
            # For code paths, the configured required checks must each be
            # present and conclude "success" specifically — `skipped`/`neutral`
            # is acceptable only for non-required checks. Catches e.g. the
            # paid-runner fork guard skipping the app build on fork PRs.
            unsatisfied = []
            if not all_ignored:
                for req in config.get("required_checks", []):
                    matching = [
                        r for r in runs
                        if r.get("name") == req or r.get("name", "").startswith(req + " (")
                    ]
                    ok = matching and all(
                        r.get("status") == "completed" and r.get("conclusion") == "success"
                        for r in matching
                    )
                    if not ok:
                        unsatisfied.append(req)
            gate(
                "ci_green",
                not pending and not red and not unsatisfied,
                f"pending={pending} failed={red} required_not_success={unsatisfied}"
                if (pending or red or unsatisfied)
                else f"{len(runs)} checks green; required checks satisfied",
            )

    all_pass = all(g["pass"] for g in gates.values())
    if all_pass:
        route = "autonomous"
    elif verdict.get("verdict") == "close_suggest":
        route = "close_suggest"
    else:
        route = "review"
    return route, gates


def evaluate_issue(verdict):
    # Issues have no diff, CI, or merge action — nothing autonomous to do.
    route = "close_suggest" if verdict.get("verdict") == "close_suggest" else "review"
    gates = {
        "issue_no_autonomous_lane": {
            "pass": True,
            "detail": "issues always route to the maintainer lane",
        }
    }
    return route, gates


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--policy")
    ap.add_argument("--verdict")
    ap.add_argument("--item-type", choices=["pr", "issue"])
    ap.add_argument("--pr-json")
    ap.add_argument("--files-json")
    ap.add_argument("--checks-json")
    ap.add_argument("--judged-sha", help="head SHA the judge's verdict describes (PRs)")
    ap.add_argument("--tree-json", help="head tree JSON (git/trees API, recursive) for file-mode checks (PRs)")
    ap.add_argument("--skip-ci", action="store_true")
    ap.add_argument("--output")
    # Utility modes — single source of truth for config parsing and the
    # escalation verdict (consumed by notify.sh and the workflow).
    ap.add_argument("--emit-config-key", metavar="KEY",
                    help="print config[KEY] from the policy block as JSON and exit")
    ap.add_argument("--emit-escalation", metavar="REASON",
                    help="print the fail-safe escalation verdict JSON and exit")
    ap.add_argument("--emit-all-ci-ignored", action="store_true",
                    help="print 'true' if every path in --files-json is CI-ignored, else 'false'")
    args = ap.parse_args(argv)

    if args.emit_escalation:
        print(json.dumps(synthesize_escalation(args.emit_escalation), indent=2))
        return 0

    if args.emit_config_key:
        if not args.policy:
            ap.error("--policy is required with --emit-config-key")
        config = load_policy_config(args.policy)
        if args.emit_config_key not in config:
            ap.error(f"no '{args.emit_config_key}' key in drawbridge-config")
        print(json.dumps(config[args.emit_config_key], indent=2))
        return 0

    if args.emit_all_ci_ignored:
        if not args.policy or not args.files_json:
            ap.error("--policy and --files-json are required with --emit-all-ci-ignored")
        config = load_policy_config(args.policy)
        with open(args.files_json, encoding="utf-8") as f:
            files = json.load(f)
        paths = touched_paths(files)
        all_ignored = bool(paths) and all(
            match_any(p, config["ci_ignored_paths"]) for p in paths
        )
        print("true" if all_ignored else "false")
        return 0

    if not (args.policy and args.verdict and args.item_type):
        ap.error("--policy, --verdict, and --item-type are required for gate evaluation")

    config = load_policy_config(args.policy)
    with open(args.verdict, encoding="utf-8") as f:
        verdict = json.load(f)

    if not valid_verdict(verdict):
        # Malformed judge output: synthesize an escalation, never autonomous.
        verdict = synthesize_escalation("judge verdict malformed")

    if args.item_type == "pr":
        if not args.pr_json or not args.files_json:
            ap.error("--pr-json and --files-json are required for item-type=pr")
        if not args.skip_ci and not args.checks_json:
            ap.error("--checks-json is required for item-type=pr without --skip-ci")
        with open(args.pr_json, encoding="utf-8") as f:
            pr = json.load(f)
        with open(args.files_json, encoding="utf-8") as f:
            files = json.load(f)
        checks = {}
        if args.checks_json:
            with open(args.checks_json, encoding="utf-8") as f:
                checks = json.load(f)
        tree = None
        if args.tree_json:
            with open(args.tree_json, encoding="utf-8") as f:
                tree = json.load(f)
        route, gates = evaluate_pr(
            config, verdict, pr, files, checks, args.skip_ci,
            judged_sha=args.judged_sha, tree=tree,
        )
    else:
        route, gates = evaluate_issue(verdict)

    result = {
        "item_type": args.item_type,
        "mode": config["mode"],
        "route": route,
        "gates": gates,
        "verdict": verdict,
    }
    out = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(out + "\n")
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
