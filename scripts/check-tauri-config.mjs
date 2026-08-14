import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const config = JSON.parse(
  await readFile(
    resolve(root, "apps/desktop/src-tauri/tauri.conf.json"),
    "utf8",
  ),
);
if (config.identifier !== "com.devpulse.desktop")
  throw new Error("Unexpected Tauri identifier.");
if (!config.bundle.externalBin.includes("binaries/devpulse-local-core"))
  throw new Error("Sidecar is not bundled.");
if (JSON.stringify(config.bundle.targets) !== JSON.stringify(["nsis"]))
  throw new Error("Only the current-user NSIS bundle may be enabled.");
if (config.bundle.windows.webviewInstallMode.type !== "skip")
  throw new Error("The installer must not bootstrap system dependencies.");
if (config.bundle.windows.nsis.installMode !== "currentUser")
  throw new Error("NSIS must use current-user mode.");
if (config.bundle.publisher !== "DevPulse contributors")
  throw new Error("Unexpected publisher metadata.");
if (config.bundle.windows.nsis.installerHooks !== "installer-hooks.nsh")
  throw new Error("Only the reviewed DevPulse NSIS cleanup hook is permitted.");
const installerHook = await readFile(
  resolve(root, "apps/desktop/src-tauri/installer-hooks.nsh"),
);
if (
  createHash("sha256").update(installerHook).digest("hex") !==
  "a15aed73d66cc077e652738584e78e0087641cbccf36ff159a38d1a3f420418f"
)
  throw new Error("The reviewed NSIS cleanup hook changed unexpectedly.");
if (config.plugins?.updater || config.bundle.createUpdaterArtifacts)
  throw new Error("Automatic updates must remain disabled.");
if (!config.app.security.csp || config.app.security.csp.includes("*://"))
  throw new Error("Tauri CSP is missing or broad.");
const capabilities = JSON.parse(
  await readFile(
    resolve(root, "apps/desktop/src-tauri/capabilities/default.json"),
    "utf8",
  ),
);
if (
  capabilities.permissions.some(
    (item) =>
      String(item).startsWith("shell:") || String(item).startsWith("fs:"),
  )
) {
  throw new Error(
    "Frontend capability must not include shell or filesystem permissions.",
  );
}
if (
  capabilities.permissions.some(
    (item) => !["core:default", "dialog:allow-open"].includes(String(item)),
  )
) {
  throw new Error("Unexpected desktop capability.");
}
console.log("Tauri configuration and capability boundary are valid.");
