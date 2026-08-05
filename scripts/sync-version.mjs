import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const version = (await readFile(resolve(root, "VERSION"), "utf8")).trim();
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`VERSION is not semantic versioning: ${version}`);
}
const check = process.argv.includes("--check");
const pythonVersion = version
  .replace(/-alpha\.(\d+)$/, "a$1")
  .replace(/-beta\.(\d+)$/, "b$1");

async function updateJson(relative, transform) {
  const path = resolve(root, relative);
  const parsed = JSON.parse(await readFile(path, "utf8"));
  const expected = structuredClone(parsed);
  transform(expected);
  if (check) {
    if (JSON.stringify(parsed) !== JSON.stringify(expected)) {
      throw new Error(`${path} is not synchronized with VERSION (${version}).`);
    }
    return;
  }
  await update(path, `${JSON.stringify(expected, null, 2)}\n`);
}

async function update(path, expected) {
  const current = await readFile(path, "utf8");
  if (current === expected) return;
  if (check)
    throw new Error(`${path} is not synchronized with VERSION (${version}).`);
  await writeFile(path, expected, "utf8");
}

await updateJson("package.json", (value) => {
  value.version = version;
});
await updateJson("apps/desktop/package.json", (value) => {
  value.version = version;
  value.dependencies["@devpulse/shared-types"] = version;
});
await updateJson("packages/shared-types/package.json", (value) => {
  value.version = version;
});
await updateJson("package-lock.json", (value) => {
  value.version = version;
  value.packages[""].version = version;
  value.packages["apps/desktop"].version = version;
  value.packages["apps/desktop"].dependencies["@devpulse/shared-types"] =
    version;
  value.packages["packages/shared-types"].version = version;
});
await updateJson("apps/desktop/src-tauri/tauri.conf.json", (value) => {
  value.version = version;
});
await updateJson("services/local-core/openapi/v1.json", (value) => {
  value.info.version = version;
});

const cargoPath = resolve(root, "apps/desktop/src-tauri/Cargo.toml");
const cargo = await readFile(cargoPath, "utf8");
await update(
  cargoPath,
  cargo.replace(
    /(\[package\][\s\S]*?\nversion = ")[^"]+("\n)/,
    `$1${version}$2`,
  ),
);
await update(
  resolve(root, "services/local-core/devpulse_core/_version.py"),
  `"""Generated from the repository VERSION file by scripts/sync-version.mjs."""\n\n__version__ = "${version}"\n`,
);
const pyprojectPath = resolve(root, "pyproject.toml");
const pyproject = await readFile(pyprojectPath, "utf8");
await update(
  pyprojectPath,
  pyproject.replace(
    /(\[project\][\s\S]*?\nversion = ")[^"]+("\n)/,
    `$1${pythonVersion}$2`,
  ),
);

if (!check) console.log(`Synchronized DevPulse ${version}.`);
