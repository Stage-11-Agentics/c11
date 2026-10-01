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
RULES = [("Sources/*", gen.LEAF_RHS, NAMES, "", "", set())]
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


def _b_make(rx, ex, shape, tmpl):
    def gate(self):
        for bad in ("tab", "tabId"):
            counts = rename.check_domains(wrap(tmpl.format(e=ex, n=bad)), "Sources/X.swift", [])
            self.assertGreater(counts["B"], 0, f"{bad}: {tmpl} / {ex}")
        for good in ("bonsplitTab", "bonsplitTabId"):
            counts = rename.check_domains(wrap(tmpl.format(e=ex, n=good)), "Sources/X.swift", [])
            self.assertEqual(counts["B"], 0, f"{good}: {tmpl} / {ex}")
    return gate


for i, case in enumerate(CASES):
    slug_b = re.sub(r"\W+", "_", f"{case[1]}_{case[2]}")
    setattr(LeafSources, f"test_{i:03d}_domainB_{slug_b}", _b_make(*case))
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


LEAF_EX = re.compile(r"=\s*(?:[\w?!.()]*\.)?(?:tabIdFromBonsplitTabId|panelIdFromSurfaceId)\b|\.(?:map|compactMap|flatMap|reduce|enumerated)\b"
                     r"(?!\s*\{\s*\$0\.id\s*\})")
RX_PASS2 = re.compile(gen.LEAF_RHS + r"|\b(?:bonsplitTab\w*|selectedBonsplitTab\w*)\b")


class ExcludeAndDeclarations(unittest.TestCase):
    def taint(self, stmt, name="secondTabId"):
        return rename.find_tainted(wrap(stmt), RX_PASS2, [name], {"bonsplitX"}, LEAF_EX)

    def test_converted_id_is_a_c11_id_not_a_leaf(self):
        self.assertEqual(self.taint("let secondTabId = ws.tabIdFromBonsplitTabId(bonsplitTab.id)"), set())
        self.assertEqual(self.taint("guard let secondTabId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }"), set())

    def test_conversion_inside_a_filter_closure_keeps_the_collection_a_leaf(self):
        stmt = "let secondTabId = bonsplitTabs.filter { tabIdFromBonsplitTabId($0.id) == nil }"
        self.assertEqual(self.taint(stmt), {"secondTabId"})

    def test_mapped_values_are_not_leaves_unless_plain_ids(self):
        self.assertEqual(self.taint("let secondTabId = bonsplitTabs.map { describe($0) }"), set())
        self.assertEqual(self.taint("let secondTabId = bonsplitTabs.map { $0.id }"), {"secondTabId"})

    def test_property_declarations_keep_their_name_but_local_bindings_are_classified(self):
        src = ("final class W {\n    var forceCloseTabIds: Set<TabID> = []\n"
               "    func f() { let forceCloseTabIds = bonsplitController.allTabIds; use(forceCloseTabIds) }\n}\n")
        rules = [("Sources/*", gen.LEAF_RHS, {"forceCloseTabIds": "forceCloseBonsplitTabIds"}, "", "", set())]
        out, n = rename.taint_pass(src, "Sources/X.swift", rules)
        self.assertEqual(n, 2)  # the local binding and its use; the property declaration keeps its name
        self.assertIn("var forceCloseTabIds: Set<TabID>", out)
        self.assertIn("let forceCloseBonsplitTabIds = bonsplitController.allTabIds; use(forceCloseBonsplitTabIds)", out)


class CodablePins(unittest.TestCase):
    RENAMES = {"surfaceId": [("tabId", [], None, set())], "surfaces": [("tabs", [], None, set())],
               "surface": [("tab", [], None, {"nomember", "noprop"})]}

    def test_codable_struct_without_coding_keys_gets_a_pin_for_every_stored_property(self):
        src = "struct R: Codable {\n    var sessionId: String\n    var surfaceId: String\n    var cwd: String?\n}\n"
        out, n = rename.codable_pin_pass(src, "Sources/R.swift", self.RENAMES)
        self.assertEqual(n, 1)
        self.assertIn('case tabId = "surfaceId"', out)
        self.assertIn("case sessionId\n", out)
        self.assertIn("case cwd\n", out)

    def test_existing_coding_keys_and_non_codable_types_are_left_alone(self):
        keyed = "struct R: Codable {\n    var surfaceId: String\n    enum CodingKeys: String, CodingKey { case surfaceId }\n}\n"
        self.assertEqual(rename.codable_pin_pass(keyed, "Sources/R.swift", self.RENAMES)[1], 0)
        plain = "struct R {\n    var surfaceId: String\n}\n"
        self.assertEqual(rename.codable_pin_pass(plain, "Sources/R.swift", self.RENAMES)[1], 0)

    def test_computed_and_static_properties_are_not_pinned(self):
        src = ("struct R: Codable {\n    var surfaceId: String\n    var shown: String { surfaceId }\n"
               "    static let surfaces = 3\n}\n")
        out, _ = rename.codable_pin_pass(src, "Sources/R.swift", self.RENAMES)
        self.assertIn('case tabId = "surfaceId"', out)
        self.assertNotIn("case shown", out)
        self.assertNotIn('"surfaces"', out)

    def test_a_kept_property_keeps_its_key_and_name(self):
        src = "struct R: Codable {\n    var surface: String\n    var surfaceId: String\n}\n"
        out, _ = rename.codable_pin_pass(src, "Sources/R.swift", self.RENAMES)
        self.assertIn("case surface\n", out)
        self.assertIn('case tabId = "surfaceId"', out)


# (regex alternative, example expressions/types it recognizes); a fixture runs for every example
GHOSTTY_SOURCES = [
    (r"\bghostty_surface_\w+", ["ghostty_surface_t", "ghostty_surface_context_e", "ghostty_surface_new(&cfg)", "ghostty_surface_size(h)"]),
    (r"\bGhosttySurface\w*", ["GhosttySurfaceCallbackContext", "GhosttySurfaceScrollView"]),
    (r"\bTerminalSurface(?:Registry)?\b", ["TerminalSurface", "TerminalSurfaceRegistry.shared.allSurfaces()", "x as? TerminalSurface"]),
    (r"\bIOSurface\w*", ["IOSurfaceRef", "contents as! IOSurfaceRef"]),
    (r"\blayer\??\.contents\b", ["layer.contents", "view.layer?.contents"]),
    (r"\.runtimeSurface\b", ["callbackContext.runtimeSurface"]),
    (r"=\s*(?:self\.)?surface\b(?![\w.(])(?!\s*[.(])", ["= surface", "= self.surface"]),
    # the round-2 shapes: the raw handle read out of a wrapper, and the entry points that resolve or wait for one
    (r"\.surface\.surface\b(?!\s*[!=<>]=)", ["terminalTab.surface.surface", "workspace.focusedTerminalTab?.surface.surface"]),
    (r"\.initialSurface\b", ["resolved.initialSurface"]),
    (r"\bwaitForTerminalSurface\w*", ["waitForTerminalSurfaceOffMain(tab, waitUpTo: 2.0)", "waitForTerminalSurface(tab)"]),
    (r"\bresolveTerminalSurface\w*", ["resolveTerminalSurface(from: target)"]),
    (r"\.liveSurface\b", ["resolved.liveSurface"]),
]
GHOSTTY_RX = "|".join(rx for rx, _ in GHOSTTY_SOURCES)
GH_RX = re.compile(GHOSTTY_RX)
KEEP_RULES = [("Sources/*", GHOSTTY_RX, {"surfaceId": "@keep", "surface": "@keep", "surfaces": "@keep"}, "", "", {"keep", "funcs"})]
GH_SHAPES = {
    "typed param": "func f(_ {n}: {t}) {{ use({n}) }}",
    "typed let": "let {n}: {t} = make()",
    "let": "let {n} = {e}",
    "guard let": "guard let {n} = {e} else {{ return }}",
    "for": "for {n} in {e} {{ use({n}) }}",
    "closure": "let r = {e}.map {{ {n} in use({n}) }}",
}


def gh_cases():
    for rx, examples in GHOSTTY_SOURCES:
        for ex in examples:
            for shape, tmpl in GH_SHAPES.items():
                is_type = bool(re.fullmatch(r"[A-Za-z_]\w*(?:\.\w+)*", ex)) and "typed" in shape
                if "typed" in shape and not re.fullmatch(r"[A-Za-z_]\w*", ex):
                    continue  # only type names can annotate
                if "typed" not in shape and re.fullmatch(r"[A-Za-z_]\w*", ex) and not ex.startswith("="):
                    continue  # a bare type name is not a value expression
                if ex.startswith("="):
                    if shape not in ("let", "guard let"):
                        continue
                    yield rx, ex, shape, tmpl.replace("{e}", "surface")
                else:
                    yield rx, ex, shape, tmpl.replace("{e}", ex).replace("{t}", ex)


class GhosttyKeepDomain(unittest.TestCase):
    """A binding typed or sourced from the Ghostty surface keeps its name; a tab-named one is a leak."""


def _gh_make(rx, ex, shape, tmpl):
    def keeps(self):
        src = wrap(tmpl.format(n="surfaceId", e=ex, t=ex))
        out, n = rename.taint_pass(src, "Sources/X.swift", KEEP_RULES)
        self.assertIn("surfaceId" + rename.KEEP_SENTINEL, out, src)
        self.assertEqual(rename.strip_keep(out), src)

    def flags(self):
        for bad in ("tab", "tabId", "newTab"):
            report = []
            counts = rename.check_domains(wrap(tmpl.format(n=bad, e=ex, t=ex)), "Sources/X.swift", report)
            self.assertGreater(counts["A"], 0, f"{bad}: {tmpl}")
        clean = []
        self.assertEqual(rename.check_domains(wrap(tmpl.format(n="surfaceId", e=ex, t=ex)), "Sources/X.swift", clean)["A"], 0)

    return keeps, flags


for i, case in enumerate(gh_cases()):
    k, f = _gh_make(*case)
    slug = re.sub(r"\W+", "_", f"{case[1]}_{case[2]}")
    setattr(GhosttyKeepDomain, f"test_{i:03d}_keep_{slug}", k)
    setattr(GhosttyKeepDomain, f"test_{i:03d}_flag_{slug}", f)


class GhosttyFunctionsAndLabels(unittest.TestCase):
    def test_function_with_a_ghostty_signature_is_kept_everywhere(self):
        import tempfile
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "Sources"))
        open(os.path.join(d, "Sources", "A.swift"), "w").write(
            "func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String { \"\" }\n"
            "func other(_ surface: Int) {}\nfunc other(surface: ghostty_surface_t) {}\n")
        open(os.path.join(d, "Sources", "B.swift"), "w").write("let n = cmuxSurfaceContextName(ctx)\n")
        rules = [("Sources/*", GHOSTTY_RX, {"cmuxSurfaceContextName": "@keep", "other": "@keep", "surface": "@keep"}, "", "", {"keep", "funcs"})]
        names = rename.collect_keep_funcs(d, rules)
        self.assertIn("cmuxSurfaceContextName", names)
        self.assertNotIn("other", names)  # also declared with a non-Ghostty signature: ambiguous, left to the generic rename
        self.assertEqual(rename.collect_keep_labels(d, rules).get("other"), {"surface"})

    def test_c_typed_parameters_are_declarations_not_call_labels(self):
        src = "func f(_ x: Int, surface: ghostty_surface_t) {}\nf(1, surface: s)\n"
        a = src.index("surface: ghostty")
        self.assertFalse(rename.is_call_label(src, a, a + len("surface")))
        b = src.rindex("surface:")
        self.assertTrue(rename.is_call_label(src, b, b + len("surface")))

    def test_leaf_property_is_renamed_with_its_uses_and_not_per_region(self):
        src = ("final class W {\n    private var closing: Set<TabID> = []\n    var n: Int = 0\n"
               "    func a() { closing.insert(x) }\n    func b() { let c = self.closing }\n}\n")
        rules = [("Sources/*", gen.LEAF_RHS, {"closing": "closingBonsplit"}, "", "", {"props"})]
        out, n = rename.taint_pass(src, "Sources/X.swift", rules)
        self.assertEqual(out.count("closingBonsplit"), 3)
        self.assertNotIn("closing.insert", out)


class DomainGate(unittest.TestCase):
    def leak(self, stmt):
        report = []
        counts = rename.check_domains(wrap(stmt), "Sources/X.swift", report)
        return counts, report

    def test_bonsplit_names_from_c11_sources_are_flagged(self):
        for stmt in ("let bonsplitTab = workspace.newTerminalTab(inPane: p, focus: false)",
                     "let bonsplitTabId = workspace.tabs[id]",
                     "guard let bonsplitTab = workspace.browserTab(for: id) else { return }"):
            self.assertGreater(self.leak(stmt)[0]["C"], 0, stmt)
        self.assertEqual(self.leak("let bonsplitTabId = ws.bonsplitTabIdFromTabId(tabId)")[0]["C"], 0)

    def test_c11_names_converted_from_bonsplit_ids_are_fine(self):
        for stmt in ("guard let tabId = workspace.tabIdFromBonsplitTabId(bonsplitTabId) else { return }",
                     "let tab = workspace.tab(for: bonsplitTabId)",
                     "let newTabId = createTab(spec, inPane: paneId)"):
            self.assertEqual(self.leak(stmt)[0]["B"], 0, stmt)

    def test_bonsplit_create_tab_result_must_not_be_a_c11_name(self):
        self.assertGreater(self.leak("guard let newTabId = bonsplitController.createTab(title: t) else { return }")[0]["B"], 0)
        self.assertEqual(self.leak("guard let newBonsplitTabId = bonsplitController.createTab(title: t) else { return }")[0]["B"], 0)

    def test_uuid_typed_bonsplit_entry_points_must_say_so(self):
        self.assertGreater(rename.check_domains("func locateBonsplitTab(tabId: UUID) -> Int { 1 }\n", "Sources/X.swift", [])["B"], 0)
        self.assertEqual(rename.check_domains("func locateBonsplitTab(bonsplitTabId: UUID) -> Int { 1 }\n", "Sources/X.swift", [])["B"], 0)

    def test_ghostty_lifecycle_names_must_not_take_the_tab_spelling(self):
        report = []
        counts = rename.check_domains("final class T {\n    func teardownTab() {}\n    func allTabs() -> [TerminalSurface] { [] }\n}\n",
                                      "Sources/GhosttyTerminalView.swift", report)
        self.assertGreaterEqual(counts["A"], 2)


class WorkspaceBindingsStayWorkspaces(unittest.TestCase):
    def test_workspace_manager_collection_is_not_tainted(self):
        src = wrap("for tab in manager.tabs { use(tab) }")
        self.assertEqual(rename.find_tainted(src, RX, ["tab"], set(NAMES.values())), set())
        self.assertEqual(rename.check_leaf(wrap("for ws in manager.tabs { use(ws) }"), "Sources/X.swift", RULES, RENAMES, []), 0)


# ---------------------------------------------------------------------------------------------------------------
# Evidence-only renaming: every class renames, nothing else does, and the gate proves each rename
# ---------------------------------------------------------------------------------------------------------------
import subprocess
import tempfile

gev = _load("gen_evidence", "gen-evidence.py")
g1d = _load("gen_pass1d", "gen-pass1d.py")

FIXTURE = {
    "Sources/Thing.swift": (
        "import Foundation\n"
        "final class SurfaceThing {\n"
        "    var surfaceLabel: String = \"\"\n"
        "}\n"
        "final class TerminalSurface {\n"
        "    var surfaceHandle: Int = 0\n"
        "}\n"
        "struct GhosttySurfaceCallbackContext {\n"
        "    let surfaceId: UUID\n"
        "}\n"
    ),
    "Sources/Workspace.swift": (
        "import Foundation\n"
        "final class Workspace {\n"
        "    var surfaceThings: [UUID: SurfaceThing] = [:]\n"
        "    var surfaceCursor: Int = 0\n"
        "    func render(surfaceHolder: SurfaceThing) {\n"
        "        let surfaceNote = surfaceHolder.surfaceLabel\n"
        "        use(surfaceNote)\n"
        "    }\n"
        "    func made() {\n"
        "        let surfaceRef = newTerminalSurface(inPane: 1)\n"
        "        use(surfaceRef)\n"
        "    }\n"
        "    func other() {\n"
        "        let surfaceId = makeId()\n"
        "        use(surfaceId)\n"
        "    }\n"
        "    func raw(t: TerminalSurface) {\n"
        "        let surfaceHandleRef = t.surfaceHandle\n"
        "        use(surfaceHandleRef)\n"
        "        let surfaceLiveCopy = t\n"
        "        use(surfaceLiveCopy)\n"
        "    }\n"
        "    func rawTab(terminalTab: TerminalTab) {\n"
        "        let surfaceFromWrapper = terminalTab.surface.surface\n"
        "        use(surfaceFromWrapper)\n"
        "    }\n"
        "}\n"
    ),
}


def make_repo(files):
    root = tempfile.mkdtemp(prefix="vr-fixture-")
    for rel, text in files.items():
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        open(os.path.join(root, rel), "w").write(text)
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base"]):
        subprocess.run(cmd, cwd=root, check=True, capture_output=True)
    return root


def run_evidence_pass(root, which="2a"):
    table = os.path.join(root, f"pass-{which}.tsv")
    log = os.path.join(root, f"evidence-{which}.tsv")
    gev.main(["gen-evidence.py", which, "--root", root, "--out", table])
    subprocess.run([sys.executable, os.path.join(HERE, "rename.py"), "apply", table, "--root", root, "--no-git", "--evidence-log", log],
                   check=True, capture_output=True, cwd=root)
    return table, log


def read(root, rel):
    return open(os.path.join(root, rel)).read()


class EvidenceClasses(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = make_repo(FIXTURE)
        cls.table, cls.log = run_evidence_pass(cls.root)
        cls.thing = read(cls.root, "Sources/Thing.swift")
        cls.ws = read(cls.root, "Sources/Workspace.swift")
        cls.classes = {}
        for line in open(cls.log):
            f, ln, old, new, c, site = (line.rstrip("\n").split("\t") + [""])[:6]
            cls.classes.setdefault(old, set()).add(c)

    def test_T_type_is_renamed(self):
        self.assertIn("final class TabThing", self.thing)
        self.assertEqual(self.classes["SurfaceThing"], {"T"})
        self.assertIn("[UUID: TabThing]", self.ws)

    def test_M_member_of_a_tab_type_and_of_workspace_is_renamed_with_its_uses(self):
        self.assertIn("var tabLabel: String", self.thing)
        self.assertIn("surfaceHolder.tabLabel", self.ws.replace("tabHolder", "surfaceHolder"))
        self.assertIn("var tabThings:", self.ws)
        self.assertTrue(self.classes["surfaceLabel"] <= {"M", "Muse"})

    def test_L_annotated_and_api_bound_locals_are_renamed(self):
        self.assertIn("tabHolder", self.ws)       # annotated with a c11 tab type
        self.assertIn("let tabNote", self.ws)     # one hop from it
        self.assertIn("let tabRef = newTerminalSurface", self.ws.replace("newTerminalTab", "newTerminalSurface"))
        self.assertEqual(self.classes["surfaceHolder"], {"L"})

    def test_unannotated_unevidenced_local_keeps_its_name(self):
        self.assertIn("let surfaceId = makeId()", self.ws)
        self.assertIn("use(surfaceId)", self.ws)

    def test_a_name_declared_on_a_ghostty_type_is_ambiguous_everywhere(self):
        self.assertIn("let surfaceId: UUID", self.thing)

    def test_ghostty_wrapper_domain_is_never_renamed(self):
        self.assertIn("final class TerminalSurface", self.thing)
        self.assertIn("var surfaceHandle: Int", self.thing)
        self.assertIn("let surfaceHandleRef = t.surfaceHandle", self.ws)
        self.assertIn("let surfaceLiveCopy = t", self.ws)
        self.assertIn("let surfaceFromWrapper = terminalTab.surface.surface", self.ws)

    def test_workspace_member_without_tab_evidence_keeps_its_name(self):
        self.assertIn("var surfaceCursor: Int", self.ws)

    def test_gate_proves_every_rename_and_rejects_an_unlogged_one(self):
        cmd = [sys.executable, os.path.join(HERE, "rename.py"), "check-evidence", self.log, "HEAD", "WORKTREE", self.table]
        ok = subprocess.run(cmd, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        self.assertIn("unproven: 0", ok.stdout)
        path = os.path.join(self.root, "Sources/Workspace.swift")
        before = read(self.root, "Sources/Workspace.swift")
        try:
            open(path, "w").write(before.replace("let surfaceId = makeId()", "let tabId = makeId()").replace("use(surfaceId)", "use(tabId)"))
            bad = subprocess.run(cmd, cwd=self.root, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("UNPROVEN surfaceId -> tabId".replace("surfaceId", "surfaceId"), bad.stdout.replace("Sources/Workspace.swift ", ""))
        finally:
            open(path, "w").write(before)

    def test_gate_rejects_a_class_the_tree_does_not_support(self):
        entries = [("Sources/Workspace.swift", "1", "surfaceHandleRef", "tabHandleRef", "L",
                    "let surfaceHandleRef = t.surfaceHandle (GhosttySurfaceCallbackContext)")]
        self.assertTrue(rename.verify_classes(entries, "WORKTREE", self.root))


class LeafSignatures(unittest.TestCase):
    def test_functions_returning_leaf_values_and_leaf_labels(self):
        root = make_repo({"Sources/W.swift": (
            "final class W {\n"
            "    private func tabIdsToLeft(of anchor: TabID, inPane paneId: PaneID) -> [TabID] { [] }\n"
            "    func copyTabRef(forSurfaceId bonsplitTabId: TabID) {}\n"
            "    func splitTabBar(_ c: C, didCloseTab tab: Bonsplit.Tab) {}\n"
            "    func tabTitle(forTabIDString tabIDString: String) -> String { \"\" }\n"
            "}\n")})
        funcs, labels = g1d.leaf_signatures(root)
        self.assertEqual(funcs, {"tabIdsToLeft": "bonsplitTabIdsToLeft"})
        self.assertEqual(sorted(set(labels)), [("Sources/W.swift", "copyTabRef", "forSurfaceId", "forBonsplitTabId")])


class RoundTwoShapes(unittest.TestCase):
    """The shapes the round-2 review found by hand; the gate must report each of them."""

    def flagged(self, src, rel="Sources/X.swift", dom="A"):
        report = []
        return rename.check_domains(src, rel, report)[dom], report

    def test_raw_handle_read_out_of_a_wrapper(self):
        for stmt in ("if let sourceTab = terminalTab.surface.surface, ready { use(sourceTab) }",
                     "guard let sourceTab = terminalTab.surface.surface else { continue }",
                     "if let tab = terminalTab.surface.surface { return tab }"):
            self.assertGreater(self.flagged(wrap(stmt))[0], 0, stmt)

    def test_handle_resolvers_and_waits(self):
        for stmt in ("guard let tab = waitForTerminalSurfaceOffMain(resolved.terminalTab, waitUpTo: 2.0) else { return }",
                     "if let initialTab = resolved.initialSurface { use(initialTab) }",
                     "if let liveTab = resolved.liveSurface { use(liveTab) }"):
            self.assertGreater(self.flagged(wrap(stmt))[0], 0, stmt)
        rename.GHOSTTY_RETURNING.add("resolveSurface")
        try:
            self.assertGreater(self.flagged(wrap("guard let tab = resolveSurface(from: target) else { return }"))[0], 0)
        finally:
            rename.GHOSTTY_RETURNING.discard("resolveSurface")

    def test_readiness_flags_and_derived_names(self):
        self.assertGreater(self.flagged(wrap("let hasTab = terminalTab.surface.surface != nil"))[0], 0)
        n, report = self.flagged(wrap("var exitTabHasTabBeforeCtrlD = false\n        exitTabHasTabBeforeCtrlD = terminalTab.surface.surface"))
        self.assertTrue(any("exitTabHasTabBeforeCtrlD" in r for r in report), report)
        self.assertGreater(self.flagged(wrap("let shouldWaitForTab = !early\n        if shouldWaitForTab {\n"
                                             "            let ok = await self.waitForTerminalPanelCondition(workspace: w) { t in t.ready }\n        }"))[0], 0)

    def test_wrapper_lifecycle_names(self):
        for decl in ("private static let tabLogPath = \"/tmp/x.log\"", "private static func tabLog(_ m: String) {}",
                     "fileprivate func sendTextToTab(_ chars: String) {}"):
            self.assertGreater(self.flagged("final class T {\n    " + decl + "\n}\n", "Sources/GhosttyTerminalView.swift")[0], 0, decl)

    def test_conditions_and_closure_params_over_c11_tabs_are_not_flagged(self):
        for stmt in ("if let terminalTab = workspace.focusedTerminalTab, terminalTab.surface.surface != nil { go() }",
                     "wait(for: id) { tab in tab.surface.isViewInWindow && tab.surface.surface != nil }"):
            self.assertEqual(self.flagged(wrap(stmt))[0], 0, stmt)

    def test_function_results_and_labels_for_leaf_values(self):
        self.assertGreater(self.flagged("final class W {\n    private func tabIdsToLeft(of a: TabID, inPane p: PaneID) -> [TabID] { [] }\n}\n", dom="B")[0], 0)
        self.assertEqual(self.flagged("final class W {\n    private func bonsplitTabIdsToLeft(of a: TabID, inPane p: PaneID) -> [TabID] { [] }\n}\n", dom="B")[0], 0)
        decl = "final class W {\n    func copyTabRef(forTabId bonsplitTabId: TabID) {}\n    func g() { copyTabRef(forTabId: bonsplitTab.id) }\n}\n"
        rename.LEAF_LABEL_DECLS.add("forTabId")
        try:
            self.assertGreaterEqual(self.flagged(decl, dom="B")[0], 2)
            self.assertEqual(self.flagged(decl.replace("forTabId", "forBonsplitTabId"), dom="B")[0], 0)
            self.assertEqual(self.flagged("final class W {\n    func g() { bonsplitController.splitPane(p, withTab: newBonsplitTab, insertFirst: i) }\n}\n", dom="B")[0], 0)
        finally:
            rename.LEAF_LABEL_DECLS.discard("forTabId")

    def test_c11_value_named_for_a_ghostty_surface_wrapper_is_flagged(self):
        rename.GHOSTTY_RETURNING.add("applySingleTerminal")
        try:
            self.assertGreater(self.flagged(wrap("let tab = try applySingleTerminal(command: c, submitCommand: true)"))[0], 0)
        finally:
            rename.GHOSTTY_RETURNING.discard("applySingleTerminal")


# ---------------------------------------------------------------------------------------------------------------
# Pass 3 (Pane -> Area): c11-owned panes only; Bonsplit panes and every vendor name stay
# ---------------------------------------------------------------------------------------------------------------
FIXTURE3 = {
    "vendor/bonsplit/Sources/V.swift": (
        "public struct PaneID { public let id: UUID }\n"
        "public final class BonsplitController {\n"
        "    public var focusedPaneId: PaneID? = nil\n"
        "    public func closePane(_ pane: PaneID) {}\n"
        "    public func tabs(inPane pane: PaneID) -> [Int] { [] }\n"
        "}\n"),
    "Sources/Thing.swift": (
        "import Foundation\n"
        "final class PaneThing {\n"
        "    var paneLabel: String = \"\"\n"
        "    var closePane: Int = 0\n"
        "}\n"),
    "Sources/Workspace.swift": (
        "import Foundation\n"
        "final class Workspace {\n"
        "    var paneThings: [UUID: PaneThing] = [:]\n"
        "    var paneCursor: Int = 0\n"
        "    func place(paneHolder: PaneThing) {\n"
        "        let paneNote = paneHolder.paneLabel\n"
        "        use(paneNote)\n"
        "    }\n"
        "    func leaf(paneId: PaneID) {\n"
        "        let targetPane = paneId\n"
        "        use(targetPane)\n"
        "    }\n"
        "    func focus() {\n"
        "        let focusedPane = bonsplitController.focusedPaneId\n"
        "        use(focusedPane)\n"
        "        bonsplitController.closePane(focusedPane!)\n"
        "    }\n"
        "    func geometry(w: CGFloat, h: CGFloat) {\n"
        "        let area: CGFloat = w * h\n"
        "        use(area)\n"
        "    }\n"
        "    func unrelated() {\n"
        "        let paneId = makeId()\n"
        "        use(paneId)\n"
        "    }\n"
        "}\n"),
}


class PaneEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = make_repo(FIXTURE3)
        cls.table, cls.log = run_evidence_pass(cls.root, "3")
        cls.thing = read(cls.root, "Sources/Thing.swift")
        cls.ws = read(cls.root, "Sources/Workspace.swift")

    def test_c11_pane_type_and_members_are_renamed(self):
        self.assertIn("final class AreaThing", self.thing)
        self.assertIn("var areaLabel: String", self.thing)
        self.assertIn("var areaThings: [UUID: AreaThing]", self.ws)
        self.assertIn("areaHolder", self.ws)
        self.assertIn("let areaNote = areaHolder.areaLabel", self.ws.replace("paneHolder", "areaHolder"))

    def test_bonsplit_panes_and_vendor_names_stay(self):
        self.assertIn("func leaf(paneId: PaneID)", self.ws)
        self.assertIn("let targetPane = paneId", self.ws)
        self.assertIn("let focusedPane = bonsplitController.focusedPaneId", self.ws)
        self.assertIn("bonsplitController.closePane(focusedPane!)", self.ws)
        self.assertIn("var closePane: Int", self.thing)  # a c11 member that shares a vendor name

    def test_geometry_area_and_unevidenced_names_stay(self):
        self.assertIn("let area: CGFloat = w * h", self.ws)
        self.assertIn("let paneId = makeId()", self.ws)
        self.assertIn("var paneCursor: Int", self.ws)

    def test_gate_proves_the_pass(self):
        cmd = [sys.executable, os.path.join(HERE, "rename.py"), "check-evidence", self.log, "HEAD", "WORKTREE", self.table]
        ok = subprocess.run(cmd, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        dom = subprocess.run([sys.executable, os.path.join(HERE, "rename.py"), "check-domains", "--root", self.root], capture_output=True, text=True)
        self.assertEqual(dom.returncode, 0, dom.stdout)


class PaneDomainGate(unittest.TestCase):
    """The deliberately bad fixtures: a Bonsplit pane named for the c11 area, geometry and area sharing a name."""

    def leak(self, stmt, dom):
        report = []
        return rename.check_domains(wrap(stmt), "Sources/X.swift", report)[dom], report

    def test_bonsplit_pane_values_named_area_are_flagged(self):
        for stmt in ("let areaId = bonsplitController.focusedPaneId",
                     "for areaId in bonsplitController.allPaneIds { use(areaId) }",
                     "func f(targetArea: PaneID) { use(targetArea) }",
                     "let liveAreaIds: [PaneID] = []",
                     "guard let area = bonsplitController.focusedPaneId else { return }"):
            self.assertGreater(self.leak(stmt, "D")[0], 0, stmt)

    def test_pane_spelling_and_c11_area_sources_are_fine(self):
        for stmt in ("let paneId = bonsplitController.focusedPaneId",
                     "let area = metadataStore.area(for: key)",
                     "let areaSpec = AreaSpec(surfaceIds: [])",
                     "let safeAreaInsets = view.safeAreaInsets"):
            self.assertEqual(self.leak(stmt, "D")[0], 0, stmt)

    def test_geometry_and_area_sharing_a_name_are_flagged(self):
        both = "let area = rect.width * rect.height\n        let spec = { let area = AreaSpec(surfaceIds: []); use(area) }"
        self.assertGreater(self.leak(both, "E")[0], 0)
        self.assertEqual(self.leak("let area = rect.width * rect.height", "E")[0], 0)
        self.assertEqual(self.leak("let area = AreaSpec(surfaceIds: [])", "E")[0], 0)


class LiteralSweep(unittest.TestCase):
    """check-literals: a string literal that still names a renamed identifier is a hit unless it was reviewed."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="vr-literals-")
        cls.tables = os.path.join(cls.root, "tables")
        os.makedirs(cls.tables)
        open(os.path.join(cls.tables, "pass-9.tsv"), "w").write(
            "BrowserPaneDropTargetView\tBrowserAreaDropTargetView\t!c11UITests/**\t\tev:T\n"
            "paneMetadataStoreRevision\tareaMetadataStoreRevision\t!c11UITests/**\t\tev:M\n"
            "surface\ttab\t!c11UITests/**\t\t\n")
        os.makedirs(os.path.join(cls.root, "Sources"))
        os.makedirs(os.path.join(cls.root, "c11Tests"))
        open(os.path.join(cls.root, "Sources", "A.swift"), "w").write(
            'let reflected = String(describing: type(of: v)).contains("BrowserPaneDropTargetView")\n'
            'let prose = "BrowserPaneDropTargetViewSpace is a different name"\n'
            '// "BrowserPaneDropTargetView" in a comment is not a literal\n'
            'let interp = "x \\(BrowserAreaDropTargetView.self) y"\n'
            'let key = "paneMetadataStoreRevision"\n'
            'let word = "surface"\n')
        open(os.path.join(cls.root, "c11Tests", "B.swift"), "w").write('let q = "a BrowserPaneDropTargetView b"\n')

    def run_check(self, allow=None):
        cmd = [sys.executable, os.path.join(HERE, "rename.py"), "check-literals", "--root", self.root, "--tables", self.tables,
               "--allow", allow or os.devnull]
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_reflected_type_name_is_a_hit_and_look_alikes_are_not(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("LITERAL Sources/A.swift:1 BrowserPaneDropTargetView", r.stdout)
        self.assertIn("LITERAL c11Tests/B.swift:1 BrowserPaneDropTargetView", r.stdout)
        self.assertIn("A.swift:5 paneMetadataStoreRevision", r.stdout)
        self.assertNotIn("A.swift:2", r.stdout)   # a longer identifier
        self.assertNotIn("A.swift:3", r.stdout)   # a comment
        self.assertNotIn("A.swift:4", r.stdout)   # the interpolation is code, not literal text
        self.assertNotIn("A.swift:6", r.stdout)   # a plain word is too common to judge by spelling

    def test_reviewed_hits_pass_and_new_ones_fail(self):
        allow = os.path.join(self.root, "allow.tsv")
        open(allow, "w").write("Sources/A.swift\tBrowserPaneDropTargetView\tlog\tr\n"
                               "Sources/A.swift\tpaneMetadataStoreRevision\twire\tr\n"
                               "c11Tests/B.swift\tBrowserPaneDropTargetView\tmsg\tr\n")
        ok = self.run_check(allow)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        self.assertIn("0 unreviewed", ok.stdout)
        open(allow, "w").write("Sources/A.swift\tBrowserPaneDropTargetView\tlog\tr\n")
        self.assertEqual(self.run_check(allow).returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
