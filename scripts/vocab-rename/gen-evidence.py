#!/usr/bin/env python3
"""Generate pass-2a.tsv (Surface -> Tab), pass-2b.tsv (Panel -> Tab), pass-3.tsv (Pane -> Area) and the C11-337
passes pass-r8a.tsv / pass-r8b.tsv (Tab -> Panel) by evidence.

  gen-evidence.py 2a|2b|3|r8a|r8b        run on the tree as the previous pass left it

r8a restores what 2a and 2b produced: every name those passes (and the later passes that renamed it again) left in
the tree goes to its Panel spelling, 2b's back to the name it had before (`TabContent` -> `Panel`). r8b renames the
names born Tab since, by the same evidence rules, with every name Bonsplit declares or uses kept.

An identifier is renamed only with positive evidence that it belongs to the c11 tab domain; a name that could
belong to either domain (the Ghostty surface, IOSurface, AppKit panels, a Bonsplit leaf) keeps its old spelling.
Evidence classes (each rule in the table is tagged `ev:<class>`, each applied rename is logged with its class):

  T  a type that c11 declares in the tab domain (and its file): TabContent, TerminalTab, SurfaceMetadataStore, ...
  M  a member declared on such a type, or on Workspace/WorkspaceManager with a signature in the tab domain
     (a c11 tab type, a [UUID: ...] map, a panel id); every declaration of the name must agree, else it keeps
  L  a local or parameter annotated with a c11 tab type, or bound directly from a c11 tab API, a renamed M
     member, or the id of such a value
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rename

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SKIP = re.compile(r"^test|Tests?$|UITests$|.+_")
HOSTS = ("Workspace", "WorkspaceManager")
PANEL_TYPES = ("Panel", "TerminalPanel", "BrowserPanel", "MarkdownPanel")
# the Ghostty / IOSurface domain: a declaration or binding that mentions these is never renamed
GHOSTTY_SIG = (r"\bghostty_surface_\w+|\bGhosttySurface\w*|\bTerminalSurface(?:Registry)?\b|\bIOSurface\w*|"
               r"\blayer\??\.contents\b|\.runtimeSurface\b|\bGhosttyNSView\b")
LEAF_SIG = r"\bbonsplitController\b|\bTabID\b|\bBonsplit\.Tab\b|\bbonsplitTab\w*|\bBonsplitTab\w*"
ALL_GLOBS = "Sources/*,CLI/*,c11Tests/*"
PREV_TABLE = None  # tests point this at a fixture table

PASSES = {
    "2a": {
        "words": {"surface": "tab", "surfaces": "tabs"},
        "keep": (r"(?i)ghostty|iosurface|surfaceview|scrollprobe|TerminalSurface|terminalSurface|^surface_|_surface|"
                 r"^surfaceOpt$|^surfacePrefix$|^surface$|^surfaces$"),
        "explicit": {"newTerminalSurface": "newTerminalTab", "newTerminalSurfaceInFocusedPane": "newTerminalTabInFocusedPane",
                     "Surface": "TabRecord"},  # MailboxGlobalResolver.Surface: never a bare Swift type named Tab
        "id_rule": None,
        "dirs": [],
        "fixes": [],
        "allow_conflict": set(),
    },
    "3": {
        # c11-owned Pane* -> Area*. Bonsplit's panes (PaneID, inPane:, focusedPaneId, every vendor member) stay panes.
        "words": {"pane": "area", "panes": "areas"},
        "keep": r"^PaneID$|PaneID$|^PaneState$|ExternalPaneNode|^Pane(?:Geometry|Bounds)$",
        "explicit": {},
        "id_rule": None,
        "dirs": [],
        "fixes": [],
        "allow_conflict": set(),
        "extra_owners": (),
        "use_prev": False,
        "vendor": True,
        "leaf_extra": r"|\bPaneID\b|\bPaneState\b|\bExternalPaneNode\b|\binPane\b|\bfocusedPaneId\b|\bbonsplitPane\w*",
        "sources": (),
        "word_rx": r"[Pp]ane(?!l)",
    },
    "r8a": {
        "words": {"tab": "panel", "tabs": "panels"},
        "keep": r"(?!x)x",
        "explicit": {},  # filled by r8_products(): every live 2a/2b product, nothing else
        "id_rule": r"\b\w*[tT]ab(?:Id|Ids|ID|IDs)\b",
        "dirs": [("Sources/Tabs", "Sources/Panels")],
        "fixes": [],
        "allow_conflict": set(),
        "extra_owners": ("TabContent", "TerminalTab", "BrowserTab", "MarkdownTab"),
        "use_prev": False,
        "only_explicit": True,
        "names_clash_by_scope": True,
        "allow_conflict": {"TabKey"},  # PortScanner.TabKey / AgentDetector.TabKey are nested; CLI's PanelKey is another module
    },
    "r8b": {
        "words": {"tab": "panel", "tabs": "panels"},
        # Bonsplit (TabID, TabBar*, TabInfo, ExternalTab*, bonsplitTab*), names that mean the workspace (upstream cmux),
        # the Tab key, and the CLI's --tab argument locals that would collide with the --panel ones
        "keep": (r"onsplit|^TabID$|TabBar|^TabInfo$|^ExternalTab|^(?:addTab|newTabInsertIndex|titleForTab|focusTabFromNotification|"
                 r"openTab|selectedTab|onNewTab|newTab)$|[sS]idebarActiveTab|^WorkspaceRowView$|^SidebarActiveTabIndicator|"
                 r"^WorkspaceTabColor|^(?:tabArg|tabRaw|tabArgRaw)$|(?i:tabkey|backtab|shifttab|ctrltab|cmdtab|inserttab|tabbing|tabbed)"),
        "explicit": {},
        "id_rule": r"\b\w*(?:[tT]ab|[pP]anel)(?:Id|Ids|ID|IDs)\b",
        "dirs": [],
        "fixes": [],
        "allow_conflict": set(),
        "extra_owners": ("Panel", "TerminalPanel", "BrowserPanel", "MarkdownPanel"),
        "prev_table": "pass-r8a.tsv",
        "vendor": True,
        "names_clash_by_scope": True,
    },
    "2b": {
        "words": {"panel": "tab", "panels": "tabs"},
        "keep": (r"^(NS|WK)\w*|FloatingPanel|nonactivatingPanel|modalPanel|JavaScript\w*Panel|OpenPanel|^openPanel$|^savePanel$|"
                 r"usesFindPanel|^AboutPanelView$|^modelPanel$|^BrowserPopupPanel$|^panelOpen$|^panel$|^panels$|"
                 r"^(panelArg|panelRaw|panelArgRaw)$"),
        "explicit": {"Panel": "TabContent", "PanelType": "TabContentType", "TerminalPanel": "TerminalTab",
                     "BrowserPanel": "BrowserTab", "MarkdownPanel": "MarkdownTab"},
        "id_rule": r"\b\w*[pP]anel(?:Id|Ids|ID|IDs)\b",
        "dirs": [("Sources/Panels", "Sources/Tabs")],
        # aliases of a renamed member that become duplicate declarations of it (text as it reads after the renames)
        # the alias of `panelDirectories` becomes a duplicate declaration of it once both read tabDirectories
        "fixes": [("Sources/Workspace.swift",
                   "    var tabDirectories: [UUID: String] {\n        get { tabDirectories }\n        set { tabDirectories = newValue }\n    }\n\n", "")],
        "allow_conflict": {"panelDirectories"},
    },
}


def seg_replace(ident, words):
    parts = re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+|[^A-Za-z0-9]+", ident)
    out, changed = [], False
    for p in parts:
        low = p.lower()
        if low in words:
            new = words[low]
            out.append(new[0].upper() + new[1:] if p[0].isupper() else new)
            changed = True
        else:
            out.append(p)
    return "".join(out) if changed else None


def new_name(ident, cfg):
    if cfg.get("only_explicit"):
        return cfg["explicit"].get(ident)
    pre = re.sub(r"^surfaceTab([A-Z])", lambda m: "tabStrip" + m.group(1), ident)  # tab-strip appearance tokens
    new = cfg["explicit"].get(ident) or seg_replace(pre, cfg["words"]) or (pre if pre != ident else None)
    if new:
        new = new.replace("TabTab", "Tab").replace("tabTab", "tab").replace("PanelPanel", "Panel").replace("panelPanel", "panel")
    return new if new and new != ident else None


R8_EXPLICIT = {"TabContent": "Panel", "TabContentType": "PanelType"}  # 2b's explicit rows, inverted


def _table_pairs(tag):
    """(old, new) for every rename a pass made: table rows, taint targets and the evidence log."""
    out = []
    path = os.path.join(HERE, f"pass-{tag}.tsv")
    if not os.path.exists(path):
        return out
    renames, paths, deletes, keeps, callees, taints, fixes, receivers, region_renames = rename.load_table(path)
    for o, lst in renames.items():
        out.extend((o, n) for n, *_ in lst if n != o)
    for g, rx, mp, rr, ex, opts in taints:
        out.extend((o, n) for o, n in mp.items() if n not in ("@keep", o))
    log = os.path.join(HERE, f"evidence-{tag}.tsv")
    if os.path.exists(log):
        for line in open(log, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and cols[2] and cols[3] and " " not in cols[2] and cols[3].split()[-1] != cols[2]:
                out.append((cols[2], cols[3].split()[-1]))
    return out


def r8_products(universe):
    """{name as it reads now: Panel name} for every name passes 2a and 2b produced that is still in the tree. A product
    a later pass renamed again (3: Pane -> Area, p6: test names) is followed to its current spelling."""
    later = {}
    for tag in ("3", "p6"):
        for o, n in _table_pairs(tag):
            later.setdefault(o, n)
    words = {"tab": "panel", "tabs": "panels"}
    out, disagree = {}, []
    for tag in ("2a", "2b"):
        for o, n in _table_pairs(tag):
            cur, hops = n, 0
            while cur in later and hops < 5:
                cur, hops = later[cur], hops + 1
            if cur not in universe:
                continue
            if cur in R8_EXPLICIT:
                target = R8_EXPLICIT[cur]
            elif tag == "2b" and cur == n:
                target = o  # the exact name 2b took away
            else:
                target = seg_replace(cur, words)
            if not target or target == cur:
                continue
            if out.get(cur, target) != target:
                disagree.append((cur, out[cur], target))
                continue
            out[cur] = target
    for cur, a, b in disagree:
        print(f"PRODUCT {cur}: {a} or {b}; kept {a}")
    return out


def scan(root):
    """(types {name: kind}, members [(name, owner, kind, signature, file)]) over c11-owned sources (no UI tests)."""
    types, members = {}, []
    for full in rename.swift_files(root):
        rel = os.path.relpath(full, root)
        if rel.startswith("c11UITests"):
            continue
        src = open(full, encoding="utf-8").read()
        lx = rename.Lexer(src)
        lx.scan(0, False)
        bodies = rename.type_bodies(src, lx)
        for (kind, name, header, op, cl), inside in zip(bodies, rename.own_depth_idents(src, lx, bodies)):
            if cl is None or not name:
                continue
            if kind != "extension":
                types.setdefault(name, kind)
            props, cases = rename.declared_names(src, inside)
            for a, b in props:
                members.append((src[a:b], name, "var", rename._decl_statement(src, a, b), rel))
            for a, b in cases:
                members.append((src[a:b], name, "case", rename._decl_statement(src, a, b), rel))
            for k, (a, b) in enumerate(inside):
                if src[a:b] == "func" and k + 1 < len(inside):
                    na, nb = inside[k + 1]
                    if src[b:na].strip() == "":
                        members.append((src[na:nb], name, "func", src[a:a + 600].split("{")[0], rel))
    return types, members


def prev_tab_types(which, cfg=None):
    """Tab-domain type names an earlier pass already produced (spelled as they read now)."""
    prev = (cfg or {}).get("prev_table")
    if which != "2b" and not prev:
        return set()
    path = PREV_TABLE or os.path.join(HERE, prev or "pass-2a.tsv")
    out = set()
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and "ev:T" in cols[4].split(","):
                out.add(cols[1])
    return out


def _hand_paths_as_on_entry(out):
    """Hand rows name files as the curator saw them, often after this pass moved them; the pass applies every row to
    the tree as it is on entry. A file named by a hand row that does not exist yet, but that one of the table's @path
    rows produces, is rewritten to the path it has on entry (`Sources/PanelRailTipPolicy.swift` ->
    `Sources/TabRailTipPolicy.swift`)."""
    moves = [(l.split("\t")[1], l.split("\t")[2]) for l in out if l.startswith("@path\t")]

    def on_entry(rel):
        if "*" in rel or os.path.exists(os.path.join(ROOT, rel)):
            return rel
        cur = rel
        for old, new in reversed(moves):  # undo the directory moves, then the file moves
            if cur == new or cur.startswith(new + "/"):
                cur = old + cur[len(new):]
        return cur if os.path.exists(os.path.join(ROOT, cur)) else rel

    def globs(col):
        return ",".join(("!" + on_entry(g[1:])) if g.startswith("!") else on_entry(g) for g in col.split(",") if g)

    res, in_hand = [], False
    for line in out:
        if line.startswith("# ---- pass-") and line.endswith(".hand.tsv"):
            in_hand = True
        elif in_hand and not line.startswith("#"):
            cols = line.split("\t")
            if cols[0] in ("@fix", "@fixall", "@delete", "@regionrename", "@novendor") and len(cols) > 1:
                cols[1] = on_entry(cols[1])
            elif not cols[0].startswith("@") and len(cols) > 2:
                cols[2] = globs(cols[2])
            line = "\t".join(cols)
        res.append(line)
    return res


def main(argv=None):
    global ROOT
    argv = argv or sys.argv
    which = argv[1]
    if "--root" in argv:
        ROOT = os.path.abspath(argv[argv.index("--root") + 1])
    out_path = argv[argv.index("--out") + 1] if "--out" in argv else os.path.join(HERE, f"pass-{which}.tsv")
    cfg = dict(PASSES[which])
    for k, v in (("extra_owners", PANEL_TYPES), ("use_prev", True), ("vendor", False), ("leaf_extra", ""), ("word_rx", None), ("sources", None)):
        cfg.setdefault(k, v)
    keep = re.compile(cfg["keep"])
    types, members = scan(ROOT)
    universe = set()
    import idents
    for ident in idents.collect(ROOT):
        universe.add(ident)

    vendor_names = set()
    if cfg["vendor"]:  # every identifier Bonsplit declares or uses is a vendor name: types and members keep it
        vroot = os.path.join(ROOT, "vendor", "bonsplit", "Sources")
        for dp, dn, fn in os.walk(vroot):
            for f in fn:
                if f.endswith(".swift"):
                    vsrc = open(os.path.join(dp, f), encoding="utf-8").read()
                    vlx = rename.Lexer(vsrc)
                    vlx.scan(0, False)
                    vendor_names.update(vsrc[a:b] for a, b in vlx.idents)
    word_rx = re.compile(cfg["word_rx"]) if cfg["word_rx"] else None

    if cfg.get("only_explicit"):
        cfg["explicit"] = r8_products(universe)

    def cand(ident):
        if SKIP.search(ident) or keep.search(ident):
            return False
        if word_rx and not word_rx.search(ident):
            return False
        return new_name(ident, cfg) is not None

    def declared_ok(ident, is_type=False):  # types and members additionally never take a vendor name or one that already exists
        nn = new_name(ident, cfg)
        if ident in vendor_names:
            return False
        if cfg.get("names_clash_by_scope"):
            # r8: the new name is often already a local somewhere (`panelId`); a member only clashes on its own owner
            # (the CONFLICT check below) and inside one member (rename.py's COLLISION fallback), a type with a type
            if is_type and nn in types and ident not in cfg["allow_conflict"]:
                clashes.append((ident, nn))
                return False
            return True
        if nn in universe and ident not in cfg["allow_conflict"]:
            clashes.append((ident, nn))
            return False
        return True
    clashes = []

    # ---- T: c11-declared types in the family
    T = {n for n, k in types.items() if k in ("class", "struct", "enum", "protocol", "actor") and cand(n) and declared_ok(n, True)}
    T |= {n for n in cfg["explicit"] if n in types and n not in T}
    prevT = prev_tab_types(which, cfg) if cfg["use_prev"] else set()
    tab_types = set(T) | prevT | set(cfg["extra_owners"])
    tab_types_rx = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, tab_types), key=len, reverse=True)) + r")\b") if tab_types else None
    owner_types = set(T) | prevT | set(cfg["extra_owners"])
    gh = re.compile(GHOSTTY_SIG)
    leaf = re.compile(LEAF_SIG + cfg["leaf_extra"])  # a signature that also names a Bonsplit leaf is ambiguous: it keeps its name
    id_rx = re.compile(cfg["id_rule"]) if cfg["id_rule"] else None

    def host_evident(sig):
        return bool(tab_types_rx.search(sig)) or bool(re.search(r"\[UUID\s*:", sig)) or bool(id_rx and id_rx.search(sig))

    # ---- M: members whose every declaration is evident
    decls = {}
    for name, owner, kind, sig, rel in members:
        if cand(name) and name not in T and declared_ok(name):
            ok = (not gh.search(sig)) and (not leaf.search(sig)) and (owner in owner_types or (owner in HOSTS and host_evident(sig)))
            decls.setdefault(name, []).append((ok, owner, rel, sig))
    declared_anywhere = {}
    for name, owner, kind, sig, rel in members:
        declared_anywhere.setdefault(owner, set()).add(name)
    M, conflicts, ambiguous = set(), [], []
    for name, ds in sorted(decls.items()):
        if not all(ok for ok, *_ in ds):
            ambiguous.append(name)
            continue
        nn = new_name(name, cfg)
        if name not in cfg["allow_conflict"] and any(nn in declared_anywhere.get(o, ()) for _, o, _, _ in ds):
            conflicts.append((name, nn))
            continue
        M.add(name)

    # ---- L: bindings with evidence, for every other candidate name
    L_names = sorted(n for n in universe if cand(n) and n not in T and n not in M)
    m_words = "|".join(sorted(map(re.escape, M), key=len, reverse=True))
    sources = list(cfg["sources"] if cfg["sources"] is not None else (r"\bnew(?:Terminal|Browser|Markdown)(?:Panel|Surface)\w*\(",
               # a c11 id converted from a Bonsplit id: the head of the initializer, or the result of a map/flatMap over it
               r"=\s*(?:[\w?!.()]*\.)?tabIdFromBonsplitTabId\(", r"\.(?:flatMap|compactMap|map)\s*\{[^}]*tabIdFromBonsplitTabId"))
    if m_words:
        sources.append(r"\.(?:" + m_words + r")\b")
    if tab_types_rx:
        sources.append(tab_types_rx.pattern)
    l_rx = "|".join(sources)
    l_ex = GHOSTTY_SIG + "|" + LEAF_SIG + cfg["leaf_extra"]

    out = [f"# Pass {which}: evidence-based renames. Generated by gen-evidence.py.",
           "# Columns: old<TAB>new<TAB>globs<TAB>fallback<TAB>flags (ev:T type, ev:M member); @taint rows are ev:L"]
    for n in sorted(T):
        out.append("\t".join([n, new_name(n, cfg), "!c11UITests/**", "", "ev:T"]))
    for n in sorted(M):
        out.append("\t".join([n, new_name(n, cfg), "!c11UITests/**", "", "ev:M"]))
    if L_names:
        mp = ",".join(f"{n}={new_name(n, cfg)}" for n in L_names)
        out.append("\t".join(["@taint", ALL_GLOBS, l_rx, mp, "", l_ex, "ev:L,noextra,onehop,noleaftype"]))
    hand = os.path.join(HERE, f"pass-{which}.hand.tsv")  # hand rows (F/X evidence) that the generator cannot derive
    if os.path.exists(hand) and out_path == os.path.join(HERE, f"pass-{which}.tsv"):
        out.append(f"# ---- pass-{which}.hand.tsv")
        out.extend(l.rstrip("\n") for l in open(hand, encoding="utf-8") if l.strip() and not l.startswith("#"))
    for rel, old, new in cfg["fixes"]:
        out.append("\t".join(["@fix", rel, old.replace("\n", "\\n"), new.replace("\n", "\\n")]))
    # file renames: a source file whose stem is a renamed type
    for dp, dn, fn in os.walk(os.path.join(ROOT, "Sources")):
        for f in sorted(fn):
            if f.endswith(".swift") and f[:-6] in T:
                nn = new_name(f[:-6], cfg)
                old_rel = os.path.relpath(os.path.join(dp, f), ROOT)
                new_rel = os.path.relpath(os.path.join(dp, nn + ".swift"), ROOT)
                if os.path.exists(os.path.join(ROOT, new_rel)):
                    print(f"CLASH file {new_rel}")
                    continue
                out.append("\t".join(["@path", old_rel, new_rel]))
    for old_dir, new_dir in cfg["dirs"]:
        out.append("\t".join(["@path", old_dir, new_dir]))
    out = _hand_paths_as_on_entry(out)
    path = out_path
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"T={len(T)} types, M={len(M)} members, L candidates={len(L_names)} -> {path}")
    print(f"ambiguous member names kept: {len(ambiguous)}; conflicts kept: {len(conflicts)}; existing-name clashes kept: {len(set(clashes))}")
    for n, nn in sorted(set(clashes)):
        print(f"CLASH {n} -> {nn} already exists; kept")
    for n, nn in conflicts:
        print(f"CONFLICT {n} -> {nn} already declared on the same owner; kept")
    if "--verbose" in argv:
        for n in ambiguous:
            print(f"AMBIGUOUS {n}: " + "; ".join(f"{o}{'' if ok else '!'}" for ok, o, r, sig in decls[n]))


if __name__ == "__main__":
    main()
