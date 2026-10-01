#!/usr/bin/env python3
"""Tests for the leaf classification (plain unittest, no dependencies).

    python3 scripts/vocab-rename/test_rename.py

One fixture per entry of gen-pass1.py's LEAF_SOURCES, in four binding shapes (direct chained closure,
`let`, `for`, `guard let` / `if let`). Each must be tainted by `find_tainted`, renamed to its bonsplit
spelling by `taint_pass`, and flagged by `check_leaf` when mis-renamed to `workspace` or the collision
fallback `ws`.
"""
import importlib.util
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rename  # noqa: E402


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load("gen_pass1", "gen-pass1.py")
RX = re.compile(gen.LEAF_RHS)
NAMES = {"tab": "bonsplitTab"}
RULES = [("Sources/*", gen.LEAF_RHS, NAMES, "")]
RENAMES = {"tab": [("workspace", [], "ws", set())]}
SHAPES = {
    "chained closure": "let r = {e}.map {{ {n} in _ = {n}.id }}",
    "chained closure, where:": "let r = {e}.first(where: {{ {n} in {n}.id == target }})",
    "chained closure, two params": "let r = {e}.sorted(by: {{ {n}, other in {n}.id < other.id }})",
    "let": "let {n} = {e}",
    "for": "for {n} in {e} {{ use({n}) }}",
    "guard let": "guard let {n} = {e} else {{ return }}",
    "if let": "if let {n} = {e} {{ use({n}) }}",
}


def wrap(stmt):
    return "struct S {\n    func f() {\n        " + stmt + "\n    }\n}\n"


CASES = [(rx, ex, shape, tmpl) for rx, exs in gen.LEAF_SOURCES for ex in exs for shape, tmpl in SHAPES.items()]


class LeafSources(unittest.TestCase):
    def test_alternatives_compose_leaf_rhs(self):
        self.assertEqual("|".join(rx for rx, _ in gen.LEAF_SOURCES), gen.LEAF_RHS)

    def test_every_example_matches_its_alternative(self):
        for rx, exs in gen.LEAF_SOURCES:
            for ex in exs:
                self.assertTrue(re.search(rx, ex), (rx, ex))

    def test_statement_tail_seeds_open_call(self):
        text = "x.tabs(inPane: p).map { t in t.id }\nnext()"
        m = re.search(r"\btabs\(inPane:", text)
        self.assertEqual(rename._open_depth(m.group(0)), 1)
        self.assertIn("map { t in t.id }", rename._statement_tail(text, m.end(), 1))
        self.assertNotIn("next()", rename._statement_tail(text, m.end(), 1))


def _make(rx, ex, shape, tmpl):
    def taints(self):
        src = wrap(tmpl.format(e=ex, n="tab"))
        found = rename.find_tainted(src, RX, ["tab"], set(NAMES.values()))
        self.assertEqual(found, {"tab"}, src)
        out, n = rename.taint_pass(src, "Sources/X.swift", RULES)
        self.assertGreater(n, 0, src)
        self.assertIn("bonsplitTab", out)
        self.assertNotRegex(out, r"(?<![.\w])tab\b")

    def checks(self):
        for bad in ("workspace", "ws"):
            src = wrap(tmpl.format(e=ex, n=bad))
            report = []
            hits = rename.check_leaf(src, "Sources/X.swift", RULES, RENAMES, report)
            self.assertGreater(hits, 0, f"{bad}: {src}")
            self.assertTrue(report)
        clean = wrap(tmpl.format(e=ex, n="bonsplitTab"))
        self.assertEqual(rename.check_leaf(clean, "Sources/X.swift", RULES, RENAMES, []), 0, clean)

    return taints, checks


for i, case in enumerate(CASES):
    taints, checks = _make(*case)
    slug = re.sub(r"\W+", "_", f"{case[1]}_{case[2]}")
    setattr(LeafSources, f"test_{i:03d}_taint_{slug}", taints)
    setattr(LeafSources, f"test_{i:03d}_check_{slug}", checks)


class PartialCallSources(unittest.TestCase):
    """The leaf match ends inside an open call: the chained closure after the `)` must still be found."""

    def test_bare_partial_call_chains(self):
        for e in ("tabs(inPane: paneId)", "selectedTab(inPane: paneId)", "bonsplitController.tab(tabId)",
                  "f(g(decode(Bonsplit.Tab.self)))"):
            src = wrap(f"let r = {e}.map {{ tab in tab.id }}")
            self.assertEqual(rename.find_tainted(src, RX, ["tab"], set(NAMES.values())), {"tab"}, e)
            bad = wrap(f"let r = {e}.map {{ ws in ws.id }}")
            self.assertGreater(rename.check_leaf(bad, "Sources/X.swift", RULES, RENAMES, []), 0, e)

    def test_multiline_chain(self):
        src = wrap("let r = controller.tabs(\n    inPane: paneId\n)\n    .filter { tab in tab.isPinned }\n    .map { t in t.id }")
        self.assertEqual(rename.find_tainted(src, RX, ["tab"], set(NAMES.values())), {"tab"})

    def test_unrelated_next_statement_is_not_tainted(self):
        src = wrap("let n = controller.tabs(inPane: paneId).count\n        let r = others.map { tab in tab.id }")
        self.assertEqual(rename.find_tainted(src, RX, ["tab"], set(NAMES.values())), set())


class WorkspaceBindingsStayWorkspaces(unittest.TestCase):
    def test_workspace_manager_collection_is_not_tainted(self):
        src = wrap("for tab in manager.tabs { use(tab) }")
        self.assertEqual(rename.find_tainted(src, RX, ["tab"], set(NAMES.values())), set())
        self.assertEqual(rename.check_leaf(wrap("for ws in manager.tabs { use(ws) }"), "Sources/X.swift", RULES, RENAMES, []), 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
