import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const files = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.json"], { encoding: "utf8" })
  .trim()
  .split(/\r?\n/)
  .filter(Boolean);
for (const file of files) JSON.parse(readFileSync(file, "utf8"));
console.log(`${files.length} project JSON files are valid.`);
