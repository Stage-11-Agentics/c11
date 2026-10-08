"use strict";
window.C11MD = (() => {
  const themes = [], faces = [];
  /* a face is a family plus the metrics it needs: size, leading, measure, weight, heading scale */
  const registerFace = f => { faces.push(f); return f; };
  const getFace = id => faces.find(f => f.id === id);
  /* a theme names its default face (a registered id, or its own face object); its token set includes that type */
  const register = t => {
    t.faceDef = typeof t.face === "string" ? getFace(t.face) : t.face;
    t.tokens = { ...t.faceDef.tokens, ...t.tokens };
    themes.push(t); return t;
  };
  const get = id => themes.find(t => t.id === id);
  const css = tokens => Object.entries(tokens).map(([k, v]) => `${k}: ${v};`).join(" ");
  /* tab theme tokens on the surface; an operator typeface choice layers its face tokens on top */
  const apply = (osId, tabId, faceId) => {
    const os = get(osId), tab = get(tabId) || os, face = faceId ? getFace(faceId) : null;
    document.getElementById("themeStyle").textContent =
      `:root { ${css(os.tokens)} color-scheme: ${os.scheme}; }\n.surface { ${css(tab.tokens)} ${face ? css(face.tokens) : ""} color-scheme: ${tab.scheme}; }`;
    document.documentElement.dataset.theme = os.id;
  };
  return { themes, faces, register, registerFace, get, getFace, apply };
})();
const MONO = '"JetBrains Mono Variable", "JetBrains Mono", "SF Mono", ui-monospace, Menlo, monospace';
C11MD.registerFace({ id: "serif", label: "reading serif", family: "literata", pick: true, load: '400 1em "Literata Variable"', tokens: {
  "--font-prose": '"Literata Variable", Literata, Charter, "Iowan Old Style", Georgia, serif', "--font-head": "var(--font-prose)", "--mono": MONO,
  "--face-size": "1", "--face-lh": "1.62", "--face-measure": "36em", "--face-para": "0.92em", "--face-track": "0", "--face-head-track": "-0.012em",
  "--face-w-dark": "370", "--face-w-light": "410", "--h1": "2.02em", "--h2": "1.4em", "--h3": "1.13em",
  "--face-code": "0.79em", "--face-pre": "0.735em", "--face-table": "0.86em", "--face-code-td": "0.82em", "--face-rail": "1", "--face-hyphens": "auto" } });
C11MD.registerFace({ id: "sans", label: "sans", family: "sf pro", pick: true, load: '400 1em "Inter Variable"', tokens: {
  "--font-prose": '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter Variable", Inter, "Helvetica Neue", sans-serif', "--font-head": '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter Variable", Inter, sans-serif', "--mono": MONO,
  "--face-size": "0.94", "--face-lh": "1.56", "--face-measure": "35em", "--face-para": "0.9em", "--face-track": "0", "--face-head-track": "-0.018em",
  "--face-w-dark": "380", "--face-w-light": "400", "--h1": "1.92em", "--h2": "1.36em", "--h3": "1.12em",
  "--face-code": "0.84em", "--face-pre": "0.78em", "--face-table": "0.9em", "--face-code-td": "0.84em", "--face-rail": "0.97", "--face-hyphens": "auto" } });
C11MD.registerFace({ id: "mono", label: "mono", family: "jetbrains mono", pick: true, load: '400 1em "JetBrains Mono Variable"', tokens: {
  "--font-prose": MONO, "--font-head": MONO, "--mono": MONO,
  "--face-size": "0.8", "--face-lh": "1.8", "--face-measure": "30.5em", "--face-para": "1.2em", "--face-track": "0", "--face-head-track": "0",
  "--face-w-dark": "330", "--face-w-light": "380", "--h1": "1.6em", "--h2": "1.24em", "--h3": "1.06em",
  "--face-code": "0.98em", "--face-pre": "0.92em", "--face-table": "0.96em", "--face-code-td": "0.97em", "--face-rail": "0.88", "--face-hyphens": "manual" } });
C11MD.register({ id: "light", label: "light", scheme: "light", icon: "sun", face: "serif", tokens: {"--page": "#d7d6d1", "--chrome": "#efeeea", "--chrome-2": "#e6e5e0", "--tab-on": "#fbfaf6", "--rule": "#d8d6cf", "--rule-soft": "rgba(0,0,0,0.07)", "--c-text": "rgba(20,20,18,0.86)", "--c-dim": "rgba(20,20,18,0.62)", "--c-faint": "rgba(20,20,18,0.42)", "--paper": "#fbfaf6", "--paper-2": "#f4f2ec", "--pop": "#ffffff", "--ink": "#2b2925", "--ink-strong": "#121110", "--ink-dim": "#67635b", "--ink-faint": "#9a958b", "--prose-w": "var(--face-w-light)", "--strong-w": "650", "--head-w": "620", "--code-bg": "#f3f1ea", "--code-inline": "#efece4", "--code-border": "#e2dfd6", "--link-line": "rgba(43,41,37,0.34)", "--wash": "rgba(0,0,0,0.028)", "--wash-2": "rgba(0,0,0,0.055)", "--gold-ink": "#9c7b20", "--gold-faint": "rgba(156,123,32,0.22)", "--gold-ghost": "rgba(201,168,76,0.12)", "--hit": "rgba(201,168,76,0.32)", "--hit-cur": "#b8952f", "--hit-cur-ink": "#fff", "--shadow": "0 12px 40px rgba(40,36,28,0.16), 0 0 0 1px rgba(0,0,0,0.07)", "--k-note": "#2f6fb8", "--k-tip": "#2e7d5b", "--k-important": "#6a4fc2", "--k-warning": "#9a6d00", "--k-caution": "#b23b2e", "--h-com": "#8b867c", "--h-kw": "#7a3d9e", "--h-str": "#3d7628", "--h-num": "#9c5510", "--h-title": "#275a96", "--h-attr": "#1d7468", "--h-meta": "#7a756b", "--h-var": "#9b3d2a"}, mermaid: {"bg": "#f4f2ec", "node": "#ffffff", "border": "#b9b5ab", "text": "#2b2925", "line": "#77736a", "cluster": "#efede6", "clusterB": "#d6d2c8", "note": "#f6edd2", "noteB": "#cdb36a", "noteT": "#4a3c12", "act": "#ecebe6"} });
C11MD.register({ id: "dark", label: "dark", scheme: "dark", icon: "moon", face: "serif", tokens: {"--k-note": "#79aee8", "--k-tip": "#78b59e", "--k-important": "#a99be6", "--k-warning": "#d0aa45", "--k-caution": "#e07a6e", "--page": "#050505", "--chrome": "#0a0a0a", "--chrome-2": "#141416", "--tab-on": "#1d1d21", "--rule": "#2b2b30", "--rule-soft": "rgba(255,255,255,0.065)", "--c-text": "rgba(232,232,232,0.88)", "--c-dim": "rgba(232,232,232,0.62)", "--c-faint": "rgba(232,232,232,0.42)", "--paper": "#0f0f11", "--paper-2": "#131316", "--pop": "#16161a", "--ink": "#d8d4cb", "--ink-strong": "#f3f0e9", "--ink-dim": "#9c988f", "--ink-faint": "#6e6b65", "--prose-w": "var(--face-w-dark)", "--strong-w": "620", "--head-w": "600", "--code-bg": "#141417", "--code-inline": "#1b1b20", "--code-border": "#26262b", "--link-line": "rgba(216,212,203,0.36)", "--wash": "rgba(255,255,255,0.035)", "--wash-2": "rgba(255,255,255,0.07)", "--gold-ink": "#c9a84c", "--gold-faint": "rgba(201,168,76,0.24)", "--gold-ghost": "rgba(201,168,76,0.06)", "--hit": "rgba(201,168,76,0.26)", "--hit-cur": "#c9a84c", "--hit-cur-ink": "#0b0b0b", "--shadow": "0 12px 40px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.06)", "--h-com": "#706d67", "--h-kw": "#c69fd8", "--h-str": "#a9c48a", "--h-num": "#d8a56c", "--h-title": "#8fb7e4", "--h-attr": "#80c3b6", "--h-meta": "#8d8981", "--h-var": "#e0ae9e"}, mermaid: {"bg": "#131316", "node": "#1a1a1f", "border": "#4a4a53", "text": "#e2ded6", "line": "#8a8790", "cluster": "#111114", "clusterB": "#34343b", "note": "#272315", "noteB": "#6b5a2a", "noteT": "#e6dcc0", "act": "#232328"} });
