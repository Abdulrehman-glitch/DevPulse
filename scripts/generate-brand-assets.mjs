import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const sourcePath = resolve(root, "assets", "branding", "devpulse-mark.svg");
const outputDirectory = resolve(root, "apps", "desktop", "src-tauri", "icons");

await mkdir(outputDirectory, { recursive: true });

if (process.argv.includes("--rasterize")) {
  const cli = resolve(root, "node_modules", "@tauri-apps", "cli", "tauri.js");
  const temporaryOutput = await mkdtemp(resolve(tmpdir(), "devpulse-icons-"));
  try {
    const result = spawnSync(
      process.execPath,
      [cli, "icon", sourcePath, "-o", temporaryOutput],
      {
        cwd: root,
        encoding: "utf8",
        stdio: "inherit",
      },
    );
    if (result.error) throw result.error;
    if (result.status !== 0)
      throw new Error(`Tauri icon generation failed (${result.status}).`);
    for (const name of [
      "32x32.png",
      "128x128.png",
      "128x128@2x.png",
      "icon.ico",
    ]) {
      await copyFile(
        resolve(temporaryOutput, name),
        resolve(outputDirectory, name),
      );
    }
  } finally {
    await rm(temporaryOutput, { recursive: true, force: true });
  }
}

console.log(`Generated DevPulse pulse aperture assets from ${sourcePath}.`);
