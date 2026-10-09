// Headless WebKit scroll-budget for highlighted fences.
// Measures the markdown scroll-frame callback (the work publish() schedules),
// not the display vsync interval. Median must stay under 16 ms; p95 is reported.
import { webkit } from 'playwright';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const bundle = path.join(root, 'Resources/markdown-viewer');
const assertBudget = process.argv.includes('--assert');
const counts = [1000, 3000];
const plainOnly = process.argv.includes('--plain-only');
const afterFindOnly = process.argv.includes('--after-find-only');
const variants = [
  ...(!afterFindOnly ? [{ afterFind: false, label: 'SCROLL_BUDGET' }] : []),
  ...(!plainOnly ? [{ afterFind: true, label: 'SCROLL_BUDGET_AFTER_FIND' }] : []),
];

function quantile(sorted, p) {
  if (!sorted.length) return null;
  const index = (sorted.length - 1) * p;
  const lo = Math.floor(index);
  const hi = Math.ceil(index);
  if (lo === hi) return sorted[lo];
  return sorted[lo] * (hi - index) + sorted[hi] * (index - lo);
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    n: sorted.length,
    median: quantile(sorted, 0.5),
    p95: quantile(sorted, 0.95),
    max: sorted.at(-1) ?? null,
  };
}

const fence = (lines) => {
  const body = Array.from({ length: lines }, (_, i) =>
    `const line_${String(i).padStart(4, '0')} = items[index] + compute(offset, "label");`
  ).join('\n');
  return `# Scroll budget\n\n\`\`\`javascript\n${body}\n\`\`\`\n`;
};

const browser = await webkit.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 820 } });
await page.addInitScript(() => {
  window.testMessages = [];
  window.webkit = { messageHandlers: { c11md: { postMessage: (message) => window.testMessages.push(message) } } };
});
const report = { browser: await browser.version(), engine: 'webkit', samples: [] };
try {
  await page.goto(pathToFileURL(path.join(bundle, 'index.html')).href);
  await page.waitForFunction(() => window.testMessages.some((message) => message.type === 'ready'));
  await page.evaluate(() => c11md.setSettings({ theme: 'light', typeface: 'mono', scale: 1, outlineOpen: false }));
  for (const variant of variants) for (const lines of counts) {
    const markdown = fence(lines);
    await page.evaluate(async (markdown) => {
      await c11md.load({
        markdown,
        documentPath: '/synthetic/scroll-budget.md',
        baseURL: 'file:///synthetic/scroll-budget.md',
        revision: 1,
      });
    }, markdown);
    const highlighted = await page.locator('.hljs-keyword').count();
    assert.ok(highlighted > 0, `${lines} lines did not highlight`);
    // Source line 1 is the heading, 2 is blank, 3 opens the fence, 4 is line_0000.
    const interior = 4 + Math.floor(lines / 2);
    const placed = await page.evaluate((line) => {
      const state = c11md.scrollToLine(line);
      const needle = `line_${String(line - 4).padStart(4, '0')}`;
      const code = document.querySelector('.code pre code');
      const scroller = document.querySelector('#scroller');
      const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        const start = node.textContent.indexOf(needle);
        if (start < 0) continue;
        const range = document.createRange();
        range.setStart(node, start);
        range.setEnd(node, start + needle.length);
        return {
          first: state.lines.first,
          textTop: range.getBoundingClientRect().top - scroller.getBoundingClientRect().top,
        };
      }
      return { first: state.lines.first, textTop: null };
    }, interior);
    // The fence starts on source line 4 (heading, blank, opening fence).
    const expected = interior;
    assert.equal(placed.first, expected, `scrollToLine(${expected}) reported ${placed.first}`);
    assert.ok(placed.textTop !== null && Math.abs(placed.textTop) < 1, `interior line textTop ${placed.textTop}`);
    if (variant.afterFind) await page.evaluate(() => { c11md.find('const'); c11md.findClose(); });
    const samples = await page.evaluate(async () => {
      const scroller = document.querySelector('#scroller');
      scroller.scrollTop = 0;
      const max = scroller.scrollHeight - scroller.clientHeight;
      const frames = 80;
      const samples = [];
      const real = window.requestAnimationFrame.bind(window);
      // WebKit fires scroll after the assignment returns, so the patch has to
      // stay up until the callback publish() scheduled has actually run.
      let pending = null;
      window.requestAnimationFrame = (callback) => real((timestamp) => {
        const start = performance.now();
        try { callback(timestamp); }
        finally {
          const cost = performance.now() - start;
          if (pending) {
            const resolve = pending;
            pending = null;
            resolve(cost);
          }
        }
      });
      const idle = () => new Promise((resolve) => real(resolve));
      await idle();
      await idle();
      for (let i = 1; i <= frames; i += 1) {
        const target = Math.min(max, (max * i) / frames);
        if (Math.abs(scroller.scrollTop - target) < 0.5) continue;
        const cost = await new Promise((resolve) => {
          const timer = setTimeout(() => {
            if (pending) pending = null;
            resolve(-1);
          }, 1000);
          pending = (value) => {
            clearTimeout(timer);
            resolve(value);
          };
          scroller.scrollTop = target;
        });
        samples.push(cost);
      }
      window.requestAnimationFrame = real;
      return samples;
    });
    assert.ok(!samples.includes(-1), `${lines} lines: scroll callback never ran`);
    assert.ok(samples.length >= 40, `${lines} lines: only ${samples.length} scroll frames`);
    const summary = summarize(samples);
    report.samples.push({ lines, ...summary, scrollToLine: placed });
    const row = `${variant.label} lines=${lines} median=${summary.median.toFixed(3)} p95=${summary.p95.toFixed(3)} max=${summary.max.toFixed(3)} n=${summary.n}`;
    console.log(row);
    if (assertBudget) assert.ok(summary.median < 16, `${row} exceeded 16 ms median`);
  }
  console.log(`SCROLL_BUDGET_ENGINE ${report.browser}`);
} finally {
  await browser.close();
}
