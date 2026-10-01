#!/usr/bin/env python3
"""Generate pass-1.tsv: workspace-meaning Tab* identifiers -> Workspace*.

Scans the current tree for identifiers, applies the substring rules and the
curated lists below, and writes the explicit symbol table. Re-run on fresh main
to pick up identifiers introduced since; the output is the reviewed artifact.
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idents

HERE = os.path.dirname(os.path.abspath(__file__))
NOT_CLI = "!CLI/**"
# Files where generic Tab names (tab, tabs, tabId...) are bonsplit/leaf/KVC names.
LEAF_FILES = [
    "!Sources/Workspace.swift", "!Sources/WorkspaceContentView.swift",
    "!Sources/TabSheetDetail.swift", "!Sources/AppleScriptSupport.swift",
    "!Sources/SocketHandlers/MiscHandlers.swift", "!Sources/SocketHandlers/DebugHandlers.swift",
    "!Sources/BrowserWindowPortal.swift", "!Sources/WorkspacePlanCapture.swift",
    "!Sources/WorkspaceLayoutExecutor.swift", "!c11Tests/WorkspaceUnitTests.swift",
    "!c11UITests/**", "!Sources/TabLayoutSettings.swift", "!c11Tests/TabLayoutSettingsTests.swift",
]
BONSPLIT_SIGNAL = r"bonsplitController\.|\bTabID\b|Bonsplit\.Tab\b|BonsplitTab|\bTabInfo\b|inPane:|splitTabBar"
# Callees whose argument labels follow (rename) or ignore (keep) the rename: from compile errors.
# Exact one-off edits the renamer cannot infer (persisted keys, member uses of kept declarations).
FIXES = [
    ("Sources/SessionPersistence.swift",
     "    var workspaceManager: SessionWorkspaceManagerSnapshot\n    var sidebar: SessionSidebarSnapshot\n}\n",
     "    var workspaceManager: SessionWorkspaceManagerSnapshot\n    var sidebar: SessionSidebarSnapshot\n\n"
     "    // Persisted session files key the workspace list as `tabManager`; keep that on-disk key.\n"
     "    enum CodingKeys: String, CodingKey {\n        case frame\n        case display\n"
     "        case workspaceManager = \"tabManager\"\n        case sidebar\n    }\n}\n"),
    ("Sources/AppDelegate.swift",
     "target.workspace.panel(for: target.workspaceId)", "target.workspace.panel(for: target.tabId)"),
]
CALLEES = {"BrowserPaneDragTransfer": "keep", "move": "keep", "equalizeSplits": "rename",
           "matchesCurrentTerminalFocusTarget": "rename", "resolveSurfaceId": "rename",
           "preloadTerminalPanelForDebugStress": "keep", "DebugStressTerminalLoadTarget": "keep", "ScriptTab": "keep",
           "moveBonsplitTab": "keep", "locateBonsplitSurface": "keep",
           "newSplit": "rename", "clearNotifications": "rename"}
NOIMPLICIT = {"tab", "tabs", "selectedTab", "selectedTabId", "tabId", "tabIds"}

SUBSTRING_RULES = [  # (old substring, new substring), applied to whole identifiers
    ("TabManager", "WorkspaceManager"), ("tabManager", "workspaceManager"),
    ("ActiveTabIndicator", "ActiveWorkspaceIndicator"), ("activeTabIndicator", "activeWorkspaceIndicator"),
    ("WorkspaceTab", "Workspace"), ("workspaceTab", "workspace"),
    ("SidebarTab", "SidebarWorkspace"), ("sidebarTab", "sidebarWorkspace"),
]
EXPLICIT = {
    "VerticalTabsSidebar": "WorkspaceSidebar",
    "TabItemView": "WorkspaceRowView",
    "TabSurfaceKey": "WorkspaceSurfaceKey",
    "ScriptTab": "ScriptWorkspace",
    "selectNextTab": "selectNextWorkspace",
    "selectPreviousTab": "selectPreviousWorkspace",
    "selectLastTab": "selectLastWorkspace",
    "moveTabToTop": "moveWorkspaceToTop",
    "moveTabsToTop": "moveWorkspacesToTop",
    "moveTabToTopForNotification": "moveWorkspaceToTopForNotification",
    "setTabColor": "setWorkspaceColor",
    "applyTabColor": "applyWorkspaceColor",
    "resolvedCustomTabColor": "resolvedCustomWorkspaceColor",
    "tabColorSwatchColor": "workspaceColorSwatchColor",
    "defaultTabColorBinding": "defaultWorkspaceColorBinding",
    "baseTabColorHex": "baseWorkspaceColorHex",
    "tabHistory": "workspaceHistory",
    "recordTabInHistory": "recordWorkspaceInHistory",
    "lastFocusedPanelByTab": "lastFocusedPanelByWorkspace",
    "unreadByTabSurface": "unreadByWorkspaceSurface",
    "rawUnreadByTabSurface": "rawUnreadByWorkspaceSurface",
    "previousUnreadByTab": "previousUnreadByWorkspace",
    "tabsCancellable": "workspacesCancellable",
    "selectedTabCancellable": "selectedWorkspaceCancellable",
}
ID_FAMILY = """tabId tabIds selectedTabId selectedTabIds forTabId targetTabId draggedTabId orderedTabIds
pinnedTabIds newTabId newDraggedTabId tabIdKey callbackTabId activeSelectedTabId owningSelectedTabId
surfaceTabId previousTabId pendingTabId lastTabId preferredSelectedTabId sidebarDraggedTabId
unreadCountByTabId latestByTabId latestUnreadByTabId rawUnreadCountByTabId closeMainWindowContainingTabId
contextContainingTabId candidateTabId tabId1 tabId2 tabIdString tabIdRaw tabIdForSurface
selectedTabIdWhenPrompted initialTabIds initialSelectedTabId secondFirstTabId expectedTabId
expectedLatestTabId probeTabId focusedTabId targetTabIndex tabForSidebarMutation resolveTabIdForSidebarMutation
resolveTabForReport tabResolution tabArg tabRaw""".split()
GENERIC = {"tab": ("workspace", "ws"), "tabs": ("workspaces", "workspaceList")}
SKIP_NAME = re.compile(r"^test|Tests?$|(?i:m1b)|.+_|Bonsplit|bonsplit|CmuxScriptTab")


def main():
    universe = idents.collect(".")
    rows = {}
    def add(old, new, globs):
        rows[old] = (new, globs)
    for ident in universe:
        if SKIP_NAME.search(ident):
            continue
        for a, b in SUBSTRING_RULES:
            if a in ident:
                add(ident, ident.replace(a, b), [NOT_CLI])
                break
    for old, new in EXPLICIT.items():
        if old in universe:
            add(old, new, [NOT_CLI])
    for old in ID_FAMILY:
        if old in universe and old not in rows:
            new = old.replace("Tab", "Workspace", 1) if old != "tabId" and not old.startswith("tab") else old.replace("tab", "workspace", 1)
            add(old, new, [NOT_CLI] + LEAF_FILES)
    for old, (new, fb) in GENERIC.items():
        add(old, new, [NOT_CLI] + LEAF_FILES)
    add("selectedTab", "selectedWorkspace", [NOT_CLI] + LEAF_FILES)
    out = ["# Pass 1: workspace-meaning Tab* -> Workspace*. Generated by gen-pass1.py; review before applying.",
           "# Columns: old<TAB>new<TAB>globs<TAB>fallback-on-shadowing-collision<TAB>flags",
           "@path\tSources/TabManager.swift\tSources/WorkspaceManager.swift",
           "@delete\tSources/TabManager.swift\tvar selectedTab: Workspace? { selectedWorkspace }"]
    for rel, old, new in FIXES:
        out.append("\t".join(["@fix", rel, old.replace("\n", "\\n"), new.replace("\n", "\\n")]))
    for name, how in sorted(CALLEES.items()):
        out.append(f"@callee\t{name}\t{how}")
    out.append("@keep\tSources/TerminalController.swift\tLayoutDebugSelectedPanel|splitViews: \\[LayoutDebugSplitView\\]\tselectedTabId")
    leaf_positive = ",".join(g[1:] for g in LEAF_FILES if not g.startswith("!c11UITests"))
    for old in sorted(rows):
        new, globs = rows[old]
        fb = GENERIC.get(old, (None, ""))[1] if old in GENERIC else ""
        flags = "noimplicit" if old in NOIMPLICIT else ""
        out.append("\t".join([old, new, ",".join(globs), fb, flags]))
        lf = []
        if old in ("tabs", "selectedTab", "selectedTabId"):
            lf.append("recvmgr")
        if lf:
            out.append("\t".join([old, new, leaf_positive, "", ",".join(lf)]))
    with open(os.path.join(HERE, "pass-1.tsv"), "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(len(rows), "entries")

if __name__ == "__main__":
    main()
