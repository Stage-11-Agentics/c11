import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseChangelog } from "../lib/changelog";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const changelogPath = path.resolve(scriptDir, "../../CHANGELOG.md");
const markdown = fs.readFileSync(changelogPath, "utf-8");
const expectedHeadline = markdown.match(
  /^## \[1\.1\.0\] - [^\n]+\n\nHeadline: \*\*(.+)\*\*$/m
)?.[1];
const version = parseChangelog(markdown).find((item) => item.version === "1.1.0");
const thanks = version?.sections.find((section) => section.heading.startsWith("Thanks"));

if (!expectedHeadline || !version || version.intro !== expectedHeadline) {
  throw new Error(`1.1.0 headline mismatch: ${version?.intro ?? "<missing>"}`);
}
if (!thanks) {
  throw new Error("1.1.0 Thanks section was not parsed");
}
if (!thanks.items.some((item) => item.includes("[@BenevolentFutures]"))) {
  throw new Error("1.1.0 contributor link was not parsed into the Thanks section");
}

console.log(`1.1.0 headline: ${version.intro}`);
console.log(`1.1.0 thanks: ${thanks.items.join(", ")}`);
