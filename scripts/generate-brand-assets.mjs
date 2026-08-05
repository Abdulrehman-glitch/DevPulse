import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const sourceDirectory = resolve(root, "assets", "branding");
const sourcePath = resolve(sourceDirectory, "devpulse-mark.svg");
const outputDirectory = resolve(root, "apps", "desktop", "src-tauri", "icons");

const source = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="DevPulse interim mark">
  <rect width="512" height="512" rx="112" fill="#10243e"/>
  <path d="M72 270h92l42-104 70 190 48-112 28 26h88" fill="none" stroke="#5de2c2" stroke-width="38" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
`;

await mkdir(sourceDirectory, { recursive: true });
await mkdir(outputDirectory, { recursive: true });
await writeFile(sourcePath, source, "utf8");

if (process.argv.includes("--rasterize")) {
  const cli = resolve(root, "node_modules", "@tauri-apps", "cli", "tauri.js");
  const temporaryOutput = await mkdtemp(resolve(tmpdir(), "devpulse-icons-"));
  try {
    const result = spawnSync(process.execPath, [cli, "icon", sourcePath, "-o", temporaryOutput], {
      cwd: root,
      encoding: "utf8",
      stdio: "inherit",
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`Tauri icon generation failed (${result.status}).`);
    for (const name of ["32x32.png", "128x128.png", "128x128@2x.png", "icon.ico"]) {
      await copyFile(resolve(temporaryOutput, name), resolve(outputDirectory, name));
    }
  } finally {
    await rm(temporaryOutput, { recursive: true, force: true });
  }
}

console.log(`Generated interim DevPulse mark source at ${sourcePath}.`);
