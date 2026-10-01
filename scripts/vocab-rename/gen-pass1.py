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
     "target.workspace.panel(for: target.workspaceId)", "target.workspace.panel(for: target.bonsplitTabId)"),
    ("Sources/AppDelegate.swift",
     "                                paneId: paneId,\n                                tabId: bonsplitTab.id,",
     "                                paneId: paneId,\n                                bonsplitTabId: bonsplitTab.id,"),
    ("Sources/WorkspaceContentView.swift",
     ".filter { $0.tabId == workspace.id && !$0.isRead }", ".filter { $0.workspaceId == workspace.id && !$0.isRead }"),
    # BrowserPaneDragTransfer.tabId is the bonsplit leaf tab id decoded from the drag payload.
    ("c11Tests/BrowserPanelTests.swift", "XCTAssertEqual(transfer?.workspaceId, bonsplitTabId)", "XCTAssertEqual(transfer?.tabId, bonsplitTabId)"),
    # ExternalPaneNode (bonsplit's external view) keeps `tabs` / `selectedTabId`.
    ("c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift", "livePane.workspaces.map", "livePane.tabs.map"),
    ("c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift", "livePane.selectedWorkspaceId", "livePane.selectedTabId"),
    # Capture lists bind the outer local (renamed `ws` after a collision) under the shorthand `guard let` name.
    ("Sources/TabManager.swift", ".sink { [weak self, weak ws] count in", ".sink { [weak self, weak workspace = ws] count in"),
    ("Sources/TabManager.swift", "Task { @MainActor [weak workspace] in", "Task { @MainActor [weak workspace = ws] in"),
]
# `controller` is a vendor receiver name (bonsplit), but here it is a TerminalController.
FIXALL = [
    # BonsplitTabDragPayload.Transfer.tab is a Bonsplit tab record (wire key `tab`, pinned by CodingKeys).
    ("Sources/ContentView.swift", "transfer.workspace.id", "transfer.bonsplitTab.id"),
    ("Sources/ContentView.swift", "self.workspace = try container.decode(TabInfo.self", "self.bonsplitTab = try container.decode(TabInfo.self"),
    ("c11Tests/NotificationAndMenuBarTests.swift", "controller.tabManager", "controller.workspaceManager"),
    ("c11Tests/WorkspaceUnitTests.swift", "restored.tabs", "restored.workspaces"),
]
CALLEES = {"BrowserPaneDragTransfer": "keep", "move": "keep", "equalizeSplits": "rename",
           "matchesCurrentTerminalFocusTarget": "rename", "resolveSurfaceId": "rename",
           "preloadTerminalPanelForDebugStress": "keep", "DebugStressTerminalLoadTarget": "keep", "ScriptTab": "keep",
           "moveBonsplitTab": "keep", "locateBonsplitSurface": "keep",
           "newSplit": "rename", "clearNotifications": "rename", "addNotification": "rename",
           "hasUnreadNotification": "rename", "markRead": "rename", "unreadNotificationCreatedAt": "rename",
           "workspaceManagerFor": "rename", "tabManagerFor": "rename",
           "reorderWorkspace": "rename", "updateSurfaceDirectory": "rename", "nextMountedWorkspaceIds": "rename"}
RECEIVERS = ["GhosttyNotificationKey."]
NOIMPLICIT = {"tab", "tabs", "selectedTab", "selectedTabId", "tabId", "tabIds"}

# Per-binding classification (not per file): a binding whose declared type or initializer is a Bonsplit
# leaf value is a bonsplit tab, never a workspace. `rename.py` runs these @taint rules before the generic
# renames, so the generic `tab` -> `workspace` rule never sees them; `check-leaf` reports any miss.
# The leaf files (LEAF_FILES) are handled by pass 1b, which renames every tab name in them.
ALL_GLOBS = "Sources/*,CLI/*,c11Tests/*," + ",".join(g for g in LEAF_FILES if not g.startswith("!c11UITests"))
# (regex alternative, example expressions that match it); the fixtures in test_rename.py exercise each one.
LEAF_SOURCES = [
    (r"\btabs\(\s*inPane:", ["controller.tabs(inPane: paneId)"]),
    (r"\bselectedTab\(\s*inPane:", ["controller.selectedTab(inPane: paneId)"]),
    (r"\ballTabIds\b", ["controller.allTabIds"]),
    (r"\bbonsplitController\??\.(?:tabs|selectedTab|allTabIds|tab\()",
     ["workspace.bonsplitController.tabs", "workspace.bonsplitController?.selectedTab",
      "workspace.bonsplitController.allTabIds", "workspace.bonsplitController.tab(tabId)"]),
    (r"\bsurfaceIdFromPanelId\b", ["workspace.surfaceIdFromPanelId(panelId)"]),
    (r"\bbonsplitTabIdFromTabId\b", ["workspace.bonsplitTabIdFromTabId(panelId)"]),
    (r"\bBonsplit\.Tab\b", ["decode(Bonsplit.Tab.self)"]),
    (r"\bTabInfo\b", ["decode(TabInfo.self)"]),
    (r"\bTabID\b", ["TabID(uuid: raw)"]),
    (r"\b\w*[pP]ane\.(?:tabs|selectedTabId)\b", ["livePane.tabs", "pane.selectedTabId"]),
    (r"\bExternalPaneNode\b", ["(node as? ExternalPaneNode)"]),
    (r"\bExternalTab\w*", ["(node as? ExternalTab)"]),
]
LEAF_RHS = "|".join(rx for rx, _ in LEAF_SOURCES)
# Value classes that are c11 tabs (not Bonsplit): (file glob, rhs regex, tab-name, tabs-name)
OTHER_LEAF = [
    ("Sources/WorkspaceBlueprintMarkdown.swift", r'\["tabs"\]|lookup\("tabs"\)|\btabs\b.*as\? \[\[String: Any\]\]', "tabNode", "tabNodes"),
    ("Sources/SocketHandlers/BrowserQueryHandlers.swift", r"\bbrowserPanels\b", "browserTab", "browserTabs"),
]

# Locals that only usage reveals as bonsplit ids: (file glob, rhs regex, mapping, region regex)
REGION_LEAF = [
    ("c11Tests/BrowserPanelTests.swift", r"\bUUID\(\)", "tabId=bonsplitTabId", r"BrowserPaneDragTransfer"),
]

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


def bonsplit_name(old):
    if old.startswith("tab"):
        return "bonsplitTab" + old[3:]
    if old == "selectedTab":
        return "selectedBonsplitTab"
    return old.replace("Tab", "BonsplitTab", 1)


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
    for rel, old, new in FIXALL:
        out.append("\t".join(["@fixall", rel, old, new]))
    fam = ["tab", "tabs", "tabId", "tabIds", "selectedTab", "selectedTabId"] + [i for i in ID_FAMILY if i not in ("tabId", "tabIds", "selectedTabId")]
    fam = [n for n in fam if n in universe or n in ("tab", "tabs")]
    out.append("\t".join(["@taint", ALL_GLOBS, LEAF_RHS, ",".join(f"{n}={bonsplit_name(n)}" for n in fam)]))
    for glob, rx, one, many in OTHER_LEAF:
        out.append("\t".join(["@taint", glob, rx, f"tab={one},tabs={many}"]))
    for glob, rx, names, region in REGION_LEAF:
        out.append("\t".join(["@taint", glob, rx, names, region]))
    for rc in RECEIVERS:
        out.append(f"@receiver\t{rc}")
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
