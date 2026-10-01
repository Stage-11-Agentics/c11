#!/usr/bin/env python3
"""Generate pass-1d.tsv: compound `*Tab` / `*TabId(s)` names that hold Bonsplit leaf values.

Pass 1 renamed the generic names (tab, tabs, tabId, ...) and a curated id family per binding. Compound
names such as newTab, secondTabId, replacementTab or anchorTabId were left alone; where they are bound to
a Bonsplit value (TabID, Bonsplit.Tab, tabs(inPane:), bonsplitTabIdFromTabId(...), ...) they become
bonsplitTab*, so the later Surface/Panel -> Tab passes cannot merge them with a c11 tab id.
Run on the tree as it is after pass 1c.
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idents
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("gen_pass1", os.path.join(HERE, "gen-pass1.py"))
gen1 = importlib.util.module_from_spec(_s)
_s.loader.exec_module(gen1)

# any lower-case identifier with a Tab segment (tab, tabs, tabsNow, movingTab, newTabId, tabIdRaw, ...): it is only
# renamed where a binding of that name holds a Bonsplit value
NAME = re.compile(r"^[a-z]\w*$")
TAB_SEGMENT = re.compile(r"(?:^|[a-z0-9])[Tt]ab(?:s|Id|Ids|ID|IDs)?(?=[A-Z]|$)")
SKIP = re.compile(r"^(test|bonsplit|selectedBonsplit|new(Terminal|Browser|Markdown)Tab)|[Bb]onsplit|External|OpenLink|InNewTab|ghostty|^kVK_|layoutIsTabs|^(show|default)\w*OnBlank|^tabLayout|^tabBar|^tabStrip|^tabSheet|^tabRail|^tabOrdinal")
GLOBS = "Sources/*,CLI/*,c11Tests/*"
SKIP_REVERSE = re.compile(r"^(test|move|has|hasBonsplit)|IdFrom|IdTo|Transfer|Drag")
# a binding transformed by map/compactMap/... (other than `$0.id`) is not itself a leaf value
LEAF_RX = gen1.LEAF_RHS + r"|\b\w*[bB]onsplitTab\w*\b"
LEAF_EX = (r"=\s*(?:[\w?!.()]*\.)?(?:tabIdFromBonsplitTabId|panelIdFromSurfaceId)\b|\.(?:map|compactMap|flatMap|reduce|enumerated)\b"
           r"(?!\s*\{\s*\$0\.id\s*\})")


# call labels of local functions whose parameter was renamed (taint renames bindings, not labels)
FIXALL = [("Sources/SocketHandlers/MiscHandlers.swift", "insertionIndexToRight(anchorTabId:", "insertionIndexToRight(anchorBonsplitTabId:"),
          ("Sources/Workspace.swift", "duplicateBrowserToRight(anchorTabId:", "duplicateBrowserToRight(anchorBonsplitTabId:")]


# Workspace-meaning shims that survived pass 1 and would collide with the Panel -> Tab renames
EXTRA = [
    "@delete\tSources/WorkspaceManager.swift\tfunc closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }",
    "closeCurrentTabWithConfirmation\tcloseCurrentWorkspaceWithConfirmation\tSources/c11App.swift\t\tev:X",
    "closeTabOrWindow\tcloseWorkspaceOrWindow\tSources/c11App.swift\t\tev:X",
]


# c11 tab sources (names as they read before the Surface/Panel passes): a binding named bonsplitTab* that
# holds one of these is a c11 tab, not a Bonsplit leaf
C11_RX = (r"\bnew(?:Terminal|Browser|Markdown)(?:Panel|Surface)\w*\(|\.(?:panels|surfaces)\[|"
          r"\b(?:terminalPanel|browserPanel|markdownPanel|panel)\(for\b|"
          r"\b(?:TerminalPanel|BrowserPanel|MarkdownPanel)\b|=\s*(?:[\w?!.()]*\.)?tabIdFromBonsplitTabId\b")
# converting a c11 id *to* a Bonsplit one, or anything read from a Bonsplit controller, yields a leaf
C11_EX = r"\bbonsplitTabIdFromTabId\b|\bsurfaceIdFromPanelId\b|\bTabID\b|\bbonsplitController\b|\bBonsplit\.Tab\b"
REVERSE_NAME = re.compile(r"^(?:[a-z]\w*)?[bB]onsplitTab(?:s|Id|Ids)?$|^selectedBonsplitTab(?:Id)?$")

# Bonsplit-owned values that keep their name outside of bindings: (file, region regex, old=new[,old=new])
REGION_RENAMES = [
    # AppDelegate's two UUID-typed Bonsplit entry points take a Bonsplit tab id, never a c11 tab id
    ("Sources/AppDelegate.swift", r"func locateBonsplitSurface\(", "tabId=bonsplitTabId"),
    ("Sources/AppDelegate.swift", r"func moveBonsplitTab\(", "tabId=bonsplitTabId"),
]
EXTRA_FIXES = [
    # the UUID parameter and the Bonsplit TabID built from it must not share a name
    ("Sources/AppDelegate.swift", "        let bonsplitTabId = TabID(uuid: bonsplitTabId)\n        for context in mainWindowContexts.values {",
     "        let leafId = TabID(uuid: bonsplitTabId)\n        for context in mainWindowContexts.values {"),
    ("Sources/AppDelegate.swift", "if let panelId = workspace.tabIdFromBonsplitTabId(bonsplitTabId) {\n                    return (context.windowId, workspace.id, panelId, context.workspaceManager)",
     "if let panelId = workspace.tabIdFromBonsplitTabId(leafId) {\n                    return (context.windowId, workspace.id, panelId, context.workspaceManager)"),
    ("Sources/AppDelegate.swift", "locateBonsplitSurface(tabId: bonsplitTabId)", "locateBonsplitSurface(bonsplitTabId: bonsplitTabId)"),
    ("Sources/ContentView.swift", "app.locateBonsplitSurface(tabId: transfer.bonsplitTab.id)", "app.locateBonsplitSurface(bonsplitTabId: transfer.bonsplitTab.id)"),
    ("Sources/ContentView.swift", "app.moveBonsplitTab(\n            tabId: transfer.bonsplitTab.id,", "app.moveBonsplitTab(\n            bonsplitTabId: transfer.bonsplitTab.id,"),
    ("Sources/BrowserWindowPortal.swift", "moveBonsplitTab(\n                tabId: bonsplitTabId,", "moveBonsplitTab(\n                bonsplitTabId: bonsplitTabId,"),
    ("Sources/Workspace.swift", "app.moveBonsplitTab(\n            tabId: request.tabId.uuid,", "app.moveBonsplitTab(\n            bonsplitTabId: request.tabId.uuid,"),
]


def bonsplit_name(old):
    return gen1.bonsplit_name(old)


def appkit_panel_fixes():
    """`let panel = NSOpenPanel()` locals in files that also use `panel` for c11 tabs become `openPanel`,
    so the Panel -> Tab pass never sees an AppKit panel under that name."""
    out = []
    for rel in ("Sources/ContentView.swift", "Sources/c11App.swift"):
        path = os.path.join(HERE, "..", "..", rel)
        lines = open(path, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            if line.strip() == "let panel = NSOpenPanel()":
                ind = len(line) - len(line.lstrip())
                # the local's scope: up to the line that closes the enclosing block
                j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() and len(lines[k]) - len(lines[k].lstrip()) < ind) - 1
                old = "\n".join(lines[i:j + 1])
                new = re.sub(r'(?<![\w."])panel\b', "openPanel", old)
                out.append("\t".join(["@fix", rel, old.replace("\n", "\\n"), new.replace("\n", "\\n")]))
    return out


LEAF_TYPE = r"(?:\[TabID\]|Set<TabID>|TabID|\[Bonsplit\.Tab\]|Bonsplit\.Tab)\??"
C11_WORD = re.compile(r"(?i)tab|surface|panel")


def leaf_signatures(root=None):
    """Evidence class Leaf for function signatures: a function that returns Bonsplit leaf values is named for
    the leaf domain (tabIdsToLeft -> bonsplitTabIdsToLeft), and an external label in front of a leaf-typed
    parameter is too (`f(forSurfaceId bonsplitTabId: TabID)` -> `forBonsplitTabId`). Returns (name rows,
    region renames for the declaration labels, call-site text fixes)."""
    funcs, labels = {}, []
    decl = re.compile(r"func\s+(\w+)\s*\(([^)]*)\)\s*(?:async\s+)?(?:throws\s+)?(?:->\s*(" + LEAF_TYPE + r"))?")
    root = root or os.path.join(HERE, "..", "..")
    for sub in ("Sources", "CLI"):
        for dp, dn, fn in os.walk(os.path.join(root, sub)):
            for f in fn:
                if not f.endswith(".swift"):
                    continue
                path = os.path.join(dp, f)
                rel = os.path.relpath(path, root)
                src = open(path, encoding="utf-8").read()
                for m in decl.finditer(src):
                    name, params, ret = m.group(1), m.group(2), m.group(3)
                    if ret and C11_WORD.search(name) and not re.search(r"(?i)bonsplit|^(test|new)", name) and not name.startswith("tabIdFromBonsplit"):
                        funcs[name] = bonsplit_name(name) if name.startswith("tab") else re.sub(r"(?i)(tab|surface|panel)", "BonsplitTab", name, count=1)
                    for pm in re.finditer(r"(?:^|,)\s*(\w+)\s+(\w+)\s*:\s*" + LEAF_TYPE + r"(?=\s*(?:,|$|=))", params):
                        label = pm.group(1)
                        # only our own `for`/`of`/`with` labels; delegate requirements (didCloseTab, ...) are Bonsplit's spelling
                        if re.match(r"(?:for|of|with)(?:Tab|Surface|Panel)", label):
                            new = re.sub(r"(Tab|Surface|Panel)(Id|Ids)?$", r"BonsplitTab\2", label)
                            if new != label:
                                labels.append((rel, name, label, new))
    return funcs, labels


def main():
    universe = idents.collect(".")
    names = sorted(n for n in universe if NAME.match(n) and TAB_SEGMENT.search(n) and not SKIP.search(n))
    mp = ",".join(f"{n}={bonsplit_name(n)}" for n in names)
    rev = sorted(n for n in universe if REVERSE_NAME.match(n) and not SKIP_REVERSE.search(n))
    rmp = ",".join(f"{n}={n.replace('bonsplitTab', 'panel').replace('BonsplitTab', 'Panel')}" for n in rev)
    out = ["# Pass 1d: compound Tab names bound to Bonsplit values -> bonsplitTab*. Generated by gen-pass1d.py.",
           "\t".join(["@taint", GLOBS, LEAF_RX, mp, "", LEAF_EX, "props,ev:Leaf,relabel"]),
           # the reverse direction: bonsplitTab* names that hold c11 tabs go back to the c11 word (panel, until pass 2b)
           "\t".join(["@taint", GLOBS, C11_RX, rmp, "", C11_EX, "bindonly,ev:L"])]
    for rel, rr, pair in REGION_RENAMES:
        out.append("\t".join(["@regionrename", rel, rr, pair]))
    lfuncs, llabels = leaf_signatures()
    for old_, new_ in sorted(lfuncs.items()):
        out.append("\t".join([old_, new_, "!c11UITests/**", "", "ev:Leaf"]))
    for rel, fname, label, new in sorted(set(llabels)):
        out.append("\t".join(["@regionrename", rel, rf"func {fname}\(", f"{label}={new}"]))
        out.append("\t".join(["@fixall", rel, f"{fname}({label}:", f"{fname}({new}:"]))
    out.append("selectedTabId\tselectedBonsplitTabId\tSources/TerminalController.swift\t\tnomember,ev:X")  # Bonsplit layout JSON's selected leaf
    out.extend(EXTRA)
    out.extend(appkit_panel_fixes())
    for rel, old, new in EXTRA_FIXES:
        out.append("\t".join(["@fix", rel, old.replace("\n", "\\n"), new.replace("\n", "\\n")]))
    for rel, old, new in FIXALL:
        out.append("\t".join(["@fixall", rel, old, new]))
    with open(os.path.join(HERE, "pass-1d.tsv"), "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(len(names), "names")


if __name__ == "__main__":
    main()
