import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

const workflowRoot = resolve(".github", "workflows");
const expectedNames = ["ci.yml", "release-qa.yml", "windows-compatibility.yml"];
const names = readdirSync(workflowRoot)
  .filter((name) => /\.ya?ml$/i.test(name))
  .sort();

if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
  throw new Error(
    `Workflow inventory changed without policy review: ${names.join(", ")}`,
  );
}

const sources = new Map(
  names.map((name) => [
    name,
    readFileSync(resolve(workflowRoot, name), "utf8"),
  ]),
);
for (const [name, source] of sources) {
  if (/^\s*pull_request_target\s*:/m.test(source))
    throw new Error(`${name} uses pull_request_target.`);
  if (/\b(?:write-all|contents:\s*write|packages:\s*write)\b/.test(source)) {
    throw new Error(`${name} requests an unapproved broad write permission.`);
  }
  if (/runs-on:\s*(?:self-hosted|.*(?:4|8|16|32|64)-core)/i.test(source)) {
    throw new Error(`${name} selects a self-hosted or larger runner.`);
  }
  for (const match of source.matchAll(/^\s*uses:\s*([^\s#]+)\s*$/gm)) {
    if (!/@[0-9a-f]{40}$/.test(match[1])) {
      throw new Error(
        `${name} has a non-immutable action reference: ${match[1]}`,
      );
    }
  }
  if (/actions\/cache@|^\s*cache:\s*/m.test(source)) {
    throw new Error(
      `${name} introduces a cache without explicit storage-policy review.`,
    );
  }

  const lines = source.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^\s*run:\s*\|\s*$/.test(lines[index])) continue;
    const runIndent = lines[index].match(/^\s*/)[0].length;
    const preceding = lines.slice(Math.max(0, index - 3), index).join("\n");
    if (!/shell:\s*pwsh\s*$/.test(preceding)) continue;
    const body = [];
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const line = lines[cursor];
      if (line.trim() && line.match(/^\s*/)[0].length <= runIndent) break;
      body.push(line);
    }
    const nativeCommands = body.filter((line) =>
      /^\s*(?:npm|python|cargo|rustup|git|\.\\\.venv\\Scripts\\python\.exe)\b/.test(
        line,
      ),
    );
    if (
      nativeCommands.length > 1 &&
      !body.some((line) =>
        line.includes("$PSNativeCommandUseErrorActionPreference = $true"),
      )
    ) {
      throw new Error(
        `${name} has a multi-command PowerShell gate without native fail-fast semantics.`,
      );
    }
  }
}

for (const ordinary of ["ci.yml", "windows-compatibility.yml"]) {
  if (/actions\/upload-artifact@/.test(sources.get(ordinary))) {
    throw new Error(`${ordinary} must remain artifact-free.`);
  }
}

const release = sources.get("release-qa.yml");
const uploads = [...release.matchAll(/actions\/upload-artifact@/g)];
if (uploads.length !== 1)
  throw new Error("Release QA must have exactly one artifact upload.");
const uploadStart = uploads[0].index;
const uploadEnd = release.indexOf("\n      - name:", uploadStart);
const uploadBlock = release.slice(
  uploadStart,
  uploadEnd === -1 ? undefined : uploadEnd,
);
if (!/^\s*retention-days:\s*1\s*$/m.test(uploadBlock))
  throw new Error("Release candidate retention must remain one day.");
if (!/^\s*compression-level:\s*0\s*$/m.test(uploadBlock))
  throw new Error(
    "Already-compressed installer output must not be recompressed.",
  );
for (const forbidden of [
  "node_modules",
  ".venv",
  "target",
  "debug log",
  "screenshot",
  "build directory",
]) {
  if (uploadBlock.toLowerCase().includes(forbidden))
    throw new Error(
      `Release upload includes forbidden bulk content: ${forbidden}`,
    );
}
const candidateFiles = [
  ...uploadBlock.matchAll(/artifact_dir[^\n]*[\\/]([^\r\n}]+)$/gm),
].map((match) => match[1].trim());
if (candidateFiles.length !== 5)
  throw new Error(
    `Release QA must upload exactly five reviewed candidate files; found ${candidateFiles.length}.`,
  );

const compatibility = sources.get("windows-compatibility.yml");
for (const required of [
  "workflow_dispatch:",
  "windows-2022",
  "windows-2025",
  "timeout-minutes: 90",
]) {
  if (!compatibility.includes(required))
    throw new Error(`Compatibility workflow is missing ${required}.`);
}
if (/^\s{2}(?:push|pull_request|schedule)\s*:/m.test(compatibility)) {
  throw new Error(
    "Windows compatibility must remain a manual/release workflow.",
  );
}

console.log(
  "Workflow runner, permission, cache, and artifact-retention policy passed.",
);
