import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { execFileSync } from "node:child_process";

const files = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.md"], { encoding: "utf8" })
  .trim()
  .split(/\r?\n/)
  .filter(Boolean);
const missing = [];
for (const file of files) {
  const source = readFileSync(file, "utf8");
  for (const match of source.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    const target = match[1].split("#", 1)[0].trim().replace(/^<|>$/g, "");
    if (!target || /^(https?:|mailto:)/i.test(target)) continue;
    if (!existsSync(resolve(dirname(file), decodeURIComponent(target)))) {
      missing.push(`${file}: ${target}`);
    }
  }
}
if (missing.length) throw new Error(`Broken Markdown links:\n${missing.join("\n")}`);
console.log(`${files.length} Markdown files have valid local links.`);
