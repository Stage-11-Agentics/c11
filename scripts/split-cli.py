#!/usr/bin/env python3
"""C11-317: split CLI/c11.swift into one file per command family.

Behavior-preserving and re-runnable. It moves declarations, never edits their
bodies. The only text change is access control: a declaration that lived in
`struct CMUXCLI` (or a file-level private type) loses `private`/`fileprivate`
so the sibling files of the same executable module can see it.

    scripts/split-cli.py              # regenerate the CLI/ family files from origin/main
    scripts/split-cli.py --from REF   # ... from CLI/c11.swift at another ref
    scripts/split-cli.py --verify     # prove the working tree equals that source

Re-running on a newer main (other tickets keep editing CLI/c11.swift until the
split lands):

    git checkout -B c11/C11-317-cli-split origin/main
    scripts/split-cli.py && scripts/split-cli.py --verify

The source is always the monolith read from git, so a re-run never depends on
what the working tree holds. Layout is the ANCHORS table below: a declaration
named in it starts a new file; every declaration after it (including ones other
tickets add later) stays in that file until the next anchor. An anchor that no
longer exists is an error, so a rename upstream is noticed rather than lost.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI_DIR = os.path.join(ROOT, "CLI")
MAIN = os.path.join(CLI_DIR, "c11.swift")
PBXPROJ = os.path.join(ROOT, "GhosttyTabs.xcodeproj", "project.pbxproj")

SPLIT_MARK = "// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.\n"


# ---------------------------------------------------------------------------
# Lexing: a mask of which characters are code (not string, char or comment).
# ---------------------------------------------------------------------------

def code_mask(src):
    n = len(src)
    mask = bytearray(b"\x01") * n
    i = 0

    def skip_string(i, hashes, multiline):
        """i is just after the opening quote(s). Returns index after closing."""
        close = ('"""' if multiline else '"') + "#" * hashes
        interp = "\\" + "#" * hashes + "("
        while i < n:
            if src.startswith(interp, i):
                depth = 1
                i += len(interp)
                while i < n and depth:
                    c = src[i]
                    if c == '"':
                        j = skip_string_start(i)
                        i = j
                        continue
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    i += 1
                continue
            if src[i] == "\\" and hashes == 0:
                i += 2
                continue
            if hashes and src[i] == "\\" and src.startswith("\\" + "#" * hashes, i):
                i += 1 + hashes + 1
                continue
            if src.startswith(close, i):
                return i + len(close)
            i += 1
        return i

    def skip_string_start(i):
        # at an opening quote (possibly preceded by hashes handled by caller)
        if src.startswith('"""', i):
            return skip_string(i + 3, 0, True)
        return skip_string(i + 1, 0, False)

    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            mask[i:j] = b"\x00" * (j - i)
            i = j
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            mask[i:j] = b"\x00" * (j - i)
            i = j
        elif c == "#" or c == '"':
            hashes = 0
            j = i
            while j < n and src[j] == "#":
                hashes += 1
                j += 1
            if j < n and src[j] == '"':
                multiline = src.startswith('"""', j)
                start = j + (3 if multiline else 1)
                end = skip_string(start, hashes, multiline)
                mask[i:end] = b"\x00" * (end - i)
                i = end
            else:
                i = j if hashes else i + 1
        else:
            i += 1
    return mask


def depth_at_line_starts(src, mask):
    """Per line: (brace_paren_bracket depth at line start)."""
    depths = []
    d = 0
    line_start = True
    for idx, ch in enumerate(src):
        if line_start:
            depths.append(d)
            line_start = False
        if mask[idx]:
            if ch in "{([":
                d += 1
            elif ch in "})]":
                d -= 1
        if ch == "\n":
            line_start = True
    if line_start or not depths:
        depths.append(d)
    return depths


# ---------------------------------------------------------------------------
# Splitting into items
# ---------------------------------------------------------------------------

class Item:
    __slots__ = ("text", "kind", "name", "head")

    def __init__(self, text, kind, name, head):
        self.text = text
        self.kind = kind
        self.name = name
        self.head = head


DECL_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|fileprivate|internal|public|open|final|static|class|nonisolated|mutating|override|lazy|dynamic|indirect|convenience)\s+)*"
    r"(?P<kw>func|var|let|struct|enum|class|actor|extension|typealias|init|protocol|subscript)\b\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)?"
)


def classify(head_line):
    m = DECL_RE.match(head_line)
    if not m:
        return ("other", head_line.strip()[:40])
    kw = m.group("kw")
    name = m.group("name") or kw
    return (kw, name)


def split_items(lines, depths, base_depth, first, last):
    """Split lines[first:last] (all at base_depth) into items with their
    leading comments/attributes/blank lines attached to the following item."""
    items = []
    cur = []
    i = first
    pending = []  # leading trivia lines
    while i < last:
        line = lines[i]
        stripped = line.strip()
        if depths[i] == base_depth and (stripped == "" or stripped.startswith("//") or stripped.startswith("@") and not DECL_RE.match(line) or re.match(r"^\s*@\w+(\([^)]*\))?\s*$", line)):
            pending.append(line)
            i += 1
            continue
        # a declaration (or #if block) starts here
        start = i
        if stripped.startswith("#if"):
            nest = 0
            j = i
            while j < last:
                s = lines[j].strip()
                if depths[j] == base_depth:
                    if s.startswith("#if"):
                        nest += 1
                    elif s.startswith("#endif"):
                        nest -= 1
                        if nest == 0:
                            break
                j += 1
            end = j + 1
            # the first real line inside decides the name
            head = next((l for l in lines[i + 1:end] if l.strip() and not l.strip().startswith(("#", "//"))), lines[i])
            kind, name = classify(head)
            kind = "ifdef:" + kind
        else:
            j = i
            # extend to end of balanced declaration
            while True:
                # consume until depth returns to base and the line ends a statement
                j += 1
                while j < last and depths[j] != base_depth:
                    j += 1
                if j >= last:
                    break
                nxt = lines[j].strip()
                prev_end = lines[j - 1].rstrip()
                # continuation lines that belong to the previous declaration
                if nxt.startswith((")", "]", "}", "else", "catch", "where", "throws", "->", "&&", "||", "?", ":", ".", "{")):
                    continue
                if prev_end.endswith(("=", ",", "&&", "||", "->", "?", ":", "+", "(", "[")):
                    continue
                break
            end = j
            kind, name = classify(lines[start])
        text = "".join(pending) + "".join(lines[start:end])
        items.append(Item(text, kind, name, lines[start]))
        pending = []
        i = end
    trailing = "".join(pending)
    return items, trailing


def parse_monolith(src):
    mask = code_mask(src)
    lines = src.splitlines(keepends=True)
    # recompute depths per line using the mask
    depths = []
    d = 0
    pos = 0
    for line in lines:
        depths.append(d)
        for k, ch in enumerate(line):
            if mask[pos + k]:
                if ch in "{([":
                    d += 1
                elif ch in "})]":
                    d -= 1
        pos += len(line)
    # find the end of the import block
    first = 0
    for idx, line in enumerate(lines):
        s = line.strip()
        if s.startswith(("import ", "#if canImport", "#endif")) and depths[idx] == 0:
            # only imports in the preamble
            if s.startswith("#if canImport") or s.startswith("#endif") or s.startswith("import "):
                first = idx + 1
                continue
        if s and not s.startswith("//"):
            break
    header = "".join(lines[:first])
    # trim the header so it ends at the last import/endif only
    top, trailing = split_items(lines, depths, 0, first, len(lines))
    return header, top, trailing, lines, depths


def struct_members(item_text):
    """Split `struct CMUXCLI { ... }` text into (open, members, close)."""
    src = item_text
    mask = code_mask(src)
    lines = src.splitlines(keepends=True)
    depths = []
    d = 0
    pos = 0
    for line in lines:
        depths.append(d)
        for k, ch in enumerate(line):
            if mask[pos + k]:
                if ch in "{([":
                    d += 1
                elif ch in "})]":
                    d -= 1
        pos += len(line)
    # first line containing "struct CMUXCLI"
    open_idx = next(i for i, l in enumerate(lines) if re.match(r"\s*struct CMUXCLI\b", l))
    # last line is the closing brace at depth 1
    close_idx = max(i for i, l in enumerate(lines) if l.strip() == "}" and depths[i] == 1)
    body = (open_idx + 1, close_idx)
    items, trailing = split_items(lines, depths, 1, body[0], body[1])
    return "".join(lines[: open_idx + 1]), items, trailing, "".join(lines[close_idx:])


# ---------------------------------------------------------------------------
# Layout: (declaration key, file). Key is the declaration name; `extension X#n`
# is the nth `extension X`; `name#n` the nth declaration of that name.
# ---------------------------------------------------------------------------

TOP_ANCHORS = [
    ("CLIError", "c11.swift"),
    ("CLIFlagReadLog", "CLIFlagReadLog.swift"),
    ("CLIVersionSkew", "CLIVersionSkew.swift"),
    ("mirrorC11CmuxEnv", "c11.swift"),
    ("CLISocketSentryTelemetry", "CLISocketSentryTelemetry.swift"),
    ("WindowInfo", "CLIModels.swift"),
    ("ClaudeHookParsedInput", "CLIClaudeHookSession.swift"),
    ("CLIIDFormat", "CLISocketConfig.swift"),
    ("SocketClient", "CLISocketClient.swift"),
    ("CLIProcessResult", "CLIProcessRunner.swift"),
    ("CMUXCLI", "c11.swift"),
    ("extension String#1", "CLIExtensions.swift"),
    ("CMUXTermMain", "c11.swift"),
    ("extension CMUXCLI#1", "CMUXCLI+Skill.swift"),
    ("extension CMUXCLI#2", "CMUXCLI+Mailbox.swift"),
]

# Members of `struct CMUXCLI`, in source order.
MEMBER_ANCHORS = [
    ("debugLastSocketHintPath", "CMUXCLI+SocketDiscovery.swift"),
    ("run", "CMUXCLI+Run.swift"),
    ("FailureSeverity", "CMUXCLI+Blueprint.swift"),
    ("runSnapshotCreate", "CMUXCLI+Snapshot.swift"),
    ("runMarkdownCommand", "CMUXCLI+Markdown.swift"),
    ("runFeedback", "CMUXCLI+Feedback.swift"),
    ("connectClient", "CMUXCLI+Handles.swift"),
    ("debugString", "CMUXCLI+DebugFormat.swift"),
    ("runMoveSurface", "CMUXCLI+PanelMove.swift"),
    ("parseWorkspaceGroupOptions", "CMUXCLI+WorkspaceGroup.swift"),
    ("runWorkspaceAction", "CMUXCLI+PanelTitleBar.swift"),
    ("SSHCommandOptions", "CMUXCLI+SSH.swift"),
    ("runBrowserCommand", "CMUXCLI+Browser.swift"),
    ("parseWindows", "CMUXCLI+Resolve.swift"),
    ("AgentsArgs", "CMUXCLI+Agents.swift"),
    ("runHistoryCommand", "CMUXCLI+History.swift"),
    ("subcommandUsage", "CMUXCLI+SubcommandHelp.swift"),
    ("cmuxThemeOverrideBundleIdentifier", "CMUXCLI+Themes.swift"),
    ("runWorkspaceColor", "CMUXCLI+Colors.swift"),
    ("availableThemeNames", "CMUXCLI+ThemeFiles.swift"),
    ("socketQuote", "CMUXCLI+Args.swift"),
    ("resolveMetadataTarget", "CMUXCLI+Metadata.swift"),
    ("runConversationCommand", "CMUXCLI+Conversation.swift"),
    ("stateUsage", "CMUXCLI+State.swift"),
    ("appUsage", "CMUXCLI+App.swift"),
    ("forwardSidebarMetadataCommand", "CMUXCLI+Sidebar.swift"),
    ("TreeScope", "CMUXCLI+Tree.swift"),
    ("resolveFloorPlanCanvasWidth", "CMUXCLI+FloorPlan.swift"),
    ("treeWindowLabel", "CMUXCLI+Tree.swift"),
    ("printBrandHuman", "CMUXCLI+Output.swift"),
    ("TmuxParsedArguments", "CMUXCLI+TmuxCompat.swift"),
    ("ClaudeTeamsFocusedContext", "CMUXCLI+ClaudeTeams.swift"),
    ("TmuxCompatStore", "CMUXCLI+TmuxCompat.swift"),
    ("runAgentHook", "CMUXCLI+ClaudeHook.swift"),
    ("bundledCLIIdentity", "CMUXCLI+Version.swift"),
    ("usage", "CMUXCLI+Usage.swift"),
]

LEADING_FILE_FOR_MEMBERS = "CMUXCLI+SocketDiscovery.swift"
STAY_IN_STRUCT = "c11.swift"

ACCESS_RE = re.compile(r"(?<![\w.])(?:private|fileprivate)(?!\s*\()\s+")


def item_key(item, counters):
    name = item.name
    kind = item.kind.replace("ifdef:", "")
    if kind == "extension":
        counters[("ext", name)] = counters.get(("ext", name), 0) + 1
        return "extension %s#%d" % (name, counters[("ext", name)])
    counters[name] = counters.get(name, 0) + 1
    return name if counters[name] == 1 else "%s#%d" % (name, counters[name])


def assign(items, anchors, first_file, what):
    """Return [(file, item)] following anchors; error on a missing anchor."""
    table = dict(anchors)
    if len(table) != len(anchors):
        raise SystemExit("duplicate anchor key in %s table" % what)
    used = set()
    counters = {}
    current = first_file
    out = []
    for item in items:
        key = item_key(item, counters)
        if key in table:
            current = table[key]
            used.add(key)
        out.append((current, item))
    missing = [k for k, _ in anchors if k not in used]
    if missing:
        raise SystemExit(
            "split-cli: %s anchors not found in CLI/c11.swift: %s\n"
            "Update the anchor table in scripts/split-cli.py (a declaration was renamed or removed)."
            % (what, ", ".join(missing))
        )
    return out


def strip_access(item_text):
    """Drop private/fileprivate from the declaration's own head line."""
    lines = item_text.splitlines(keepends=True)
    for idx, line in enumerate(lines):
        st = line.strip()
        if not st or st.startswith(("//", "#", "/*", "*")):
            continue
        if re.match(r"^@\w+(\([^)]*\))?\s*$", st):
            continue
        lines[idx] = ACCESS_RE.sub("", line, count=1)
        break
    return "".join(lines)


def is_stored_instance(m):
    if m.kind not in ("let", "var"):
        return False
    head = m.head
    return not re.search(r"\bstatic\b|\bclass\b", head) and "{" not in head.split("=")[0]


TYPE_HEAD_RE = r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|final|public|internal)\s+)*(?:struct|enum|class|actor|extension)\b"


def split_extension(item, head_re=r"\s*(struct|extension) CMUXCLI\b"):
    """(open_text, members, trailing, close_text) for a type or extension item."""
    text = item.text
    mask = code_mask(text)
    lines = text.splitlines(keepends=True)
    depths = []
    d = 0
    pos = 0
    for line in lines:
        depths.append(d)
        for k, ch in enumerate(line):
            if mask[pos + k]:
                if ch in "{([":
                    d += 1
                elif ch in "})]":
                    d -= 1
        pos += len(line)
    open_idx = next(i for i, l in enumerate(lines) if re.match(head_re, l))
    close_idx = max(i for i, l in enumerate(lines) if l.strip() == "}" and depths[i] == 1)
    members, trailing = split_items(lines, depths, 1, open_idx + 1, close_idx)
    return "".join(lines[: open_idx + 1]), members, trailing, "".join(lines[close_idx:])


def plan(src):
    """Return ordered {filename: [text chunks]} for the whole split."""
    header, top, trailing, _, _ = parse_monolith(src)
    if trailing.strip():
        raise SystemExit("split-cli: unexpected trailing text after the last declaration")
    assigned = assign(top, TOP_ANCHORS, "c11.swift", "file-level")
    files = {}
    order = []

    def put(fname, text):
        if fname not in files:
            files[fname] = []
            order.append(fname)
        files[fname].append(text)

    typed = []
    for fname, item in assigned:
        kind = item.kind
        if item.name == "CMUXCLI" and kind == "struct":
            op, members, tr, cl = split_extension(item)
            stored = [m for m in members if is_stored_instance(m)]
            movable = [m for m in members if not is_stored_instance(m)]
            core = op + "".join(strip_access(m.text) for m in stored) + tr + cl
            put(fname, core)
            for f2, m in assign(movable, MEMBER_ANCHORS, LEADING_FILE_FOR_MEMBERS, "member"):
                put(f2, ("member", m))
            continue
        if kind == "extension" and item.name == "CMUXCLI":
            op, members, tr, cl = split_extension(item)
            body = "".join(strip_access(m.text) for m in members)
            put(fname, op + body + tr + cl)
            continue
        if kind in ("class", "struct", "enum", "extension") and re.match(r"\s*(?:@\w+\s+)*(?:private|fileprivate)\b", item.head):
            put(fname, strip_access(item.text))
        else:
            put(fname, item.text)
        if kind in ("class", "struct", "enum", "extension"):
            typed.append((fname, item))

    def file_text(fname):
        return "".join(c[1].text if isinstance(c, tuple) else c for c in files[fname])

    # A private member of a file-level type that another output file now names
    # must be widened, or the split would not compile. Members nobody else
    # references keep their access level.
    texts = {f: file_text(f) for f in order}
    for fname, item in typed:
        if item.name == "CMUXCLI":
            continue
        try:
            op, members, tr, cl = split_extension(item, TYPE_HEAD_RE)
        except StopIteration:
            continue
        rebuilt = []
        changed = False
        for m in members:
            if m.kind != "other" and ACCESS_RE.search(m.head) and not re.search(r"private\s*\(", m.head):
                used = any(re.search(r"\b%s\b" % re.escape(m.name), t) for f2, t in texts.items() if f2 != fname)
                if used:
                    rebuilt.append(strip_access(m.text))
                    changed = True
                    continue
            rebuilt.append(m.text)
        if changed:
            new_text = strip_access(op) + "".join(rebuilt) + tr + cl
            for idx, c in enumerate(files[fname]):
                if c == item.text or c == strip_access(item.text):
                    files[fname][idx] = new_text
                    break

    out = {}
    for fname in order:
        chunks = files[fname]
        body = []
        members = [c[1] for c in chunks if isinstance(c, tuple)]
        for c in chunks:
            if not isinstance(c, tuple):
                body.append(c)
        if members:
            text = "extension CMUXCLI {\n" + "".join(strip_access(m.text) for m in members) + "}\n"
            if body:
                raise SystemExit("split-cli: %s mixes struct members with file-level items" % fname)
            out[fname] = (text, True)
        else:
            out[fname] = ("".join(body), False)
    return header, out


def render_file(fname, header, text):
    if fname == "c11.swift":
        return header + text
    return SPLIT_MARK + header + "\n" + text.lstrip("\n")


# ---------------------------------------------------------------------------
# Xcode project: deterministic text insertion into the c11-cli target only.
# ---------------------------------------------------------------------------

def pbx_ids(fname):
    import hashlib
    h = hashlib.sha1(("c11-317:" + fname).encode()).hexdigest().upper()
    return "C11317B" + h[:17], "C11317F" + h[17:34]  # build file id, file ref id (24 hex each)


def update_pbxproj(files):
    with open(PBXPROJ) as fh:
        text = fh.read()
    # drop previously generated entries
    ours = re.compile(r"^\t\t(C11317[BF][0-9A-F]{17}) /\*[^\n]*\n", re.M)
    text = ours.sub("", text)
    text = re.sub(r"^\t\t\t\tC11317[BF][0-9A-F]{17} /\*[^\n]*\n", "", text, flags=re.M)
    names = sorted(f for f in files if f != "c11.swift")
    build_lines, ref_lines, group_lines, source_lines = [], [], [], []
    for fname in names:
        bid, rid = pbx_ids(fname)
        build_lines.append(
            "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bid, fname, rid, fname)
        )
        ref_lines.append(
            "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"%s\"; sourceTree = \"<group>\"; };\n"
            % (rid, fname, fname)
        )
        group_lines.append("\t\t\t\t%s /* %s */,\n" % (rid, fname))
        source_lines.append("\t\t\t\t%s /* %s in Sources */,\n" % (bid, fname))

    def insert_before(marker, lines):
        nonlocal text
        i = text.index(marker)
        text = text[:i] + "".join(lines) + text[i:]

    def insert_after_line(anchor, lines):
        nonlocal text
        i = text.index(anchor)
        j = text.index("\n", i) + 1
        text = text[:j] + "".join(lines) + text[j:]

    insert_before("/* End PBXBuildFile section */", build_lines)
    insert_before("/* End PBXFileReference section */", ref_lines)
    insert_after_line("B9000001A1B2C3D4E5F60719 /* c11.swift */,", group_lines)
    insert_after_line("B9000002A1B2C3D4E5F60719 /* c11.swift in Sources */,", source_lines)
    with open(PBXPROJ, "w") as fh:
        fh.write(text)


# ---------------------------------------------------------------------------
# Verification: the declarations of the monolith and of the split are the same
# multiset once access modifiers and whitespace are ignored.
# ---------------------------------------------------------------------------

def norm(t, mask=None):
    """Canonical form for comparison. Only code is normalised: access keywords
    are dropped and whitespace runs collapse outside string literals and
    comments; literal and comment bytes (spacing included) compare verbatim.
    `mask` is code_mask() of a larger text this fragment was cut from."""
    if mask is None:
        mask = code_mask(t)
    probe = "".join(c if mask[i] else "\0" for i, c in enumerate(t))
    drop = bytearray(len(t))
    for m in ACCESS_RE.finditer(probe):
        for i in range(m.start(), m.end()):
            drop[i] = 1
    out = []
    pending_space = False
    for i, c in enumerate(t):
        if drop[i]:
            continue
        if mask[i] and c.isspace():
            pending_space = True
            continue
        if pending_space and out:
            out.append(" ")
        pending_space = False
        out.append(c)
    return "".join(out)


def units(src, wrappers=True):
    """Every declaration, with CMUXCLI struct/extension bodies flattened."""
    _, top, _, _, _ = parse_monolith(src)
    out = []
    for item in top:
        if item.name == "CMUXCLI" and item.kind in ("struct", "extension"):
            _, members, _, _ = split_extension(item)
            out.extend(norm(m.text) for m in members)
        else:
            out.append(norm(item.text))
    return out


def git_show(ref, path):
    return subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (ref, path)], check=True, capture_output=True, text=True).stdout


def split_files_on_disk():
    result = {}
    for name in sorted(os.listdir(CLI_DIR)):
        full = os.path.join(CLI_DIR, name)
        if not name.endswith(".swift"):
            continue
        with open(full) as fh:
            content = fh.read()
        if name == "c11.swift" or content.startswith(SPLIT_MARK):
            result[name] = content
    return result


def verify(ref):
    from collections import Counter
    src = git_show(ref, "CLI/c11.swift")
    expected = Counter(units(src))
    actual = Counter()
    problems = []
    on_disk = split_files_on_disk()
    for name, content in on_disk.items():
        if name == "c11.swift":
            body = content
        else:
            body = content[len(SPLIT_MARK):]
        for u in units(body):
            if u == norm("extension CMUXCLI {}"):
                continue
            actual[u] += 1
    # stored property `args` and wrapper lines are covered through units(); compare.
    lost = expected - actual
    extra = actual - expected
    for u, c in lost.items():
        problems.append("LOST/EDITED x%d: %s" % (c, u[:160]))
    for u, c in extra.items():
        problems.append("EXTRA/EDITED x%d: %s" % (c, u[:160]))
    # Independent of the declaration parser: every non-blank source line must
    # reappear, once, in the split (ignoring access modifiers, the repeated
    # import header, the extension wrapper lines and the split marker).
    def line_bag(text):
        bag = Counter()
        mask = code_mask(text)
        pos = 0
        for line in text.splitlines(keepends=True):
            t = norm(line, mask[pos:pos + len(line)])
            pos += len(line)
            if t and t != "}":
                bag[t] += 1
        return bag

    src_header = parse_monolith(src)[0]
    boilerplate = line_bag(src_header)
    src_bag = line_bag(src)
    out_bag = Counter()
    for name, content in on_disk.items():
        out_bag.update(line_bag(content[len(SPLIT_MARK):] if name != "c11.swift" else content))
    for line, count in boilerplate.items():
        out_bag[line] -= count * (len(on_disk) - 1)  # header repeated in every extra file
    for line in ("extension CMUXCLI {",):
        out_bag.pop(line, None)
        src_bag.pop(line, None)
    for line, count in (src_bag - out_bag).items():
        problems.append("LINE LOST x%d: %s" % (count, line[:140]))
    for line, count in (out_bag - src_bag).items():
        if count > 0:
            problems.append("LINE EXTRA x%d: %s" % (count, line[:140]))
    pbx = open(PBXPROJ).read()
    for name in on_disk:
        if name == "c11.swift":
            continue
        bid, rid = pbx_ids(name)
        if pbx.count(bid) != 2 or pbx.count(rid) != 3:
            problems.append("pbxproj membership wrong for %s (build id x%d, ref id x%d)" % (name, pbx.count(bid), pbx.count(rid)))
    total = sum(c.count("\n") for c in on_disk.values())
    print("split files: %d, lines: %d (source %d)" % (len(on_disk), total, src.count("\n")))
    print("declaration units: expected %d, actual %d" % (sum(expected.values()), sum(actual.values())))
    biggest = sorted(((c.count("\n"), n) for n, c in on_disk.items()), reverse=True)[:5]
    print("largest:", ", ".join("%s %d" % (n, c) for c, n in biggest))
    if problems:
        print("\n".join(problems))
        return 1
    print("verify: OK (no declaration lost, duplicated or edited beyond access modifiers)")
    return 0


def generate(ref):
    src = git_show(ref, "CLI/c11.swift")
    header, out = plan(src)
    # remove files a previous run generated but this layout no longer has
    for name, content in split_files_on_disk().items():
        if name != "c11.swift" and name not in out:
            os.remove(os.path.join(CLI_DIR, name))
    for fname, (text, _) in out.items():
        with open(os.path.join(CLI_DIR, fname), "w") as fh:
            fh.write(render_file(fname, header, text))
    update_pbxproj(list(out))
    sizes = sorted(((t.count("\n"), f) for f, (t, _) in out.items()), reverse=True)
    for c, f in sizes:
        print("%6d  CLI/%s" % (c, f))
    return 0


def main(argv):
    ref = "origin/main"
    mode = "generate"
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--from":
            ref = args.pop(0)
        elif a == "--verify":
            mode = "verify"
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            raise SystemExit("unknown argument: %s" % a)
    return verify(ref) if mode == "verify" else generate(ref)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
