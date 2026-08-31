import type {
  ActivityList,
  ApiErrorPayload,
  CoreConnection,
  DesktopStatus,
  ProjectList,
  ProjectDetail,
  ProjectPatch,
  QaPathStatus,
  Settings,
  SettingsPatch,
  QaStatus,
  SafeDiagnostics,
  SystemSummary,
  SystemHistory,
  BackupSummary,
  ConfigurationExport,
  ConfigurationImportPreview,
} from "@devpulse/shared-types";
import { invoke } from "@tauri-apps/api/core";
import type { LocalDataProvider as LocalDataProviderContract } from "./contracts";

export class LocalApiError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly requestId?: string,
  ) {
    super(message);
  }
}

export class HttpLocalDataProvider implements LocalDataProviderContract {
  constructor(private readonly connection: CoreConnection) {
    if (!connection.address || !connection.token) {
      throw new Error("The local service connection is not ready.");
    }
    if (!isValidLoopbackCoreAddress(connection.address)) {
      throw new Error("The local service connection address is unsafe.");
    }
  }

  getSystemSummary() {
    return this.request<SystemSummary>("/api/v1/system/summary");
  }

  getSystemHistory() {
    return this.request<SystemHistory>("/api/v1/system/history");
  }

  getProjects() {
    return this.request<ProjectList>("/api/v1/projects");
  }

  getProject(id: string) {
    return this.request<ProjectDetail>(
      `/api/v1/projects/${encodeURIComponent(id)}`,
    );
  }

  previewProject(path: string) {
    return this.request<ProjectDetail>("/api/v1/projects/preview", {
      method: "POST",
      body: JSON.stringify({ path }),
    });
  }

  previewRoot(path: string) {
    return this.request<ProjectList>("/api/v1/project-roots/preview", {
      method: "POST",
      body: JSON.stringify({ path }),
    });
  }

  addProjects(paths: string[]) {
    return this.request<Settings>("/api/v1/projects", {
      method: "POST",
      body: JSON.stringify({ paths }),
    });
  }

  removeProject(id: string) {
    return this.request<Settings>(
      `/api/v1/projects/${encodeURIComponent(id)}`,
      {
        method: "DELETE",
      },
    );
  }

  updateProjectPath(id: string, path: string) {
    return this.updateProject(id, { path });
  }

  updateProject(id: string, patch: ProjectPatch) {
    return this.request<Settings>(
      `/api/v1/projects/${encodeURIComponent(id)}`,
      { method: "PATCH", body: JSON.stringify(patch) },
    );
  }

  refreshProjects() {
    return this.request<ProjectList>("/api/v1/projects/refresh", {
      method: "POST",
    });
  }

  getActivity(limit = 30) {
    return this.request<ActivityList>(`/api/v1/activity?limit=${limit}`);
  }

  async clearActivity() {
    await this.request<void>("/api/v1/activity", { method: "DELETE" });
  }

  getSettings() {
    return this.request<Settings>("/api/v1/settings");
  }

  updateSettings(patch: SettingsPatch) {
    return this.request<Settings>("/api/v1/settings", {
      method: "PATCH",
      body: JSON.stringify(patch),
    });
  }

  getQaStatus() {
    return this.request<QaStatus>("/api/v1/qa/status");
  }

  resetQaData() {
    return this.request<Settings>("/api/v1/qa/reset", { method: "POST" });
  }

  regenerateQaData() {
    return this.request<Settings>("/api/v1/qa/regenerate", {
      method: "POST",
    });
  }

  getSafeDiagnostics() {
    return this.request<SafeDiagnostics>("/api/v1/diagnostics");
  }

  async exportSafeDiagnostics() {
    const response = await this.request<{ text: string }>(
      "/api/v1/diagnostics/export",
    );
    return response.text;
  }

  exportConfiguration(includeNotes = false) {
    return this.request<ConfigurationExport>(
      `/api/v1/configuration/export?include_notes=${includeNotes ? "true" : "false"}`,
    );
  }

  previewConfigurationImport(payload: ConfigurationExport) {
    return this.request<ConfigurationImportPreview>(
      "/api/v1/configuration/import/preview",
      { method: "POST", body: JSON.stringify({ payload }) },
    );
  }

  importConfiguration(payload: ConfigurationExport) {
    return this.request<Settings>("/api/v1/configuration/import", {
      method: "POST",
      body: JSON.stringify({ payload }),
    });
  }

  getBackups() {
    return this.request<BackupSummary[]>("/api/v1/backups");
  }

  createBackup() {
    return this.request<BackupSummary>("/api/v1/backups", { method: "POST" });
  }

  restoreBackup(id: string) {
    return this.request<Settings>(
      `/api/v1/backups/${encodeURIComponent(id)}/restore`,
      { method: "POST" },
    );
  }

  async deleteBackup(id: string) {
    await this.request<void>(`/api/v1/backups/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }

  private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const response = await fetch(`${this.connection.address}${path}`, {
      ...init,
      headers: {
        "Content-Type": "application/json",
        "X-DevPulse-Token": this.connection.token ?? "",
        ...init.headers,
      },
    });
    if (!response.ok) {
      const payload = (await response
        .json()
        .catch(() => null)) as ApiErrorPayload | null;
      throw new LocalApiError(
        payload?.error.message ??
          `Local service request failed (${response.status}).`,
        payload?.error.code ?? "request_failed",
        payload?.error.request_id,
      );
    }
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }
}

export function isValidLoopbackCoreAddress(address: string): boolean {
  try {
    const parsed = new URL(address);
    return (
      parsed.protocol === "http:" &&
      parsed.hostname === "127.0.0.1" &&
      parsed.port !== "" &&
      parsed.port !== "0" &&
      parsed.pathname === "/" &&
      parsed.search === "" &&
      parsed.hash === "" &&
      parsed.username === "" &&
      parsed.password === ""
    );
  } catch {
    return false;
  }
}

export async function resolveCoreConnection(): Promise<CoreConnection> {
  if ("__TAURI_INTERNALS__" in window) {
    return invoke<CoreConnection>("core_connection");
  }
  const address = import.meta.env.VITE_DEVPULSE_CORE_URL as string | undefined;
  const token = import.meta.env.VITE_DEVPULSE_CORE_TOKEN as string | undefined;
  return address && token
    ? {
        status: "ready",
        address,
        token,
        version: "0.3.0",
        qaMode: import.meta.env.VITE_DEVPULSE_QA_MODE === "1",
      }
    : {
        status: "failed",
        message: "DevPulse must be opened from the desktop application.",
      };
}

export async function restartCore(): Promise<CoreConnection> {
  return invoke<CoreConnection>("restart_core");
}

export async function resolveDesktopStatus(): Promise<DesktopStatus> {
  if ("__TAURI_INTERNALS__" in window)
    return invoke<DesktopStatus>("desktop_status");
  return {
    sidecarProcessStatus: "running",
    processUptimeSeconds: 0,
    qaMode: false,
    installQa: false,
    startupDurationMs: 0,
  };
}

export async function resolveQaPathStatus(): Promise<QaPathStatus> {
  if (!("__TAURI_INTERNALS__" in window))
    throw new Error(
      "QA path status is available only in the desktop application.",
    );
  return invoke<QaPathStatus>("qa_path_status");
}

export function isPathInsideQaRoot(path: string, qaRoot: string): boolean {
  const normalize = (value: string) =>
    value.replaceAll("\\", "/").replace(/\/+$/, "").toLocaleLowerCase();
  const root = normalize(qaRoot);
  const candidate = normalize(path);
  if (!root || root === "/" || /^[a-z]:$/.test(root)) return false;
  if (candidate.split("/").includes("..")) return false;
  return candidate === root || candidate.startsWith(`${root}/`);
}

export function qaPathsAreIsolated(status: QaPathStatus): boolean {
  const writablePaths = [
    status.tauriAppConfigurationDirectory,
    status.tauriAppDataDirectory,
    status.tauriLocalDataDirectory,
    status.tauriCacheDirectory,
    status.tauriLogDirectory,
    status.webView2UserDataDirectory,
    status.pythonLocalCoreConfigurationDirectory,
    status.pythonCacheDirectory,
    status.pythonLogDirectory,
    status.qaRepositoryDirectory,
    status.diagnosticsExportDirectory,
    status.activityStorage,
  ];
  return (
    status.qaMode &&
    status.environmentMatchesCanonicalPlan &&
    status.tauriWebViewDirectoryMatchesCanonicalPlan &&
    status.allWritablePathsUnderQaRoot &&
    writablePaths.every((path) => isPathInsideQaRoot(path, status.qaRoot))
  );
}

export async function writeQaCheckpoint(checks: Record<string, unknown>) {
  if ("__TAURI_INTERNALS__" in window)
    await invoke("qa_frontend_checkpoint", { checks });
}

export async function writeInstallQaVisualCheckpoint(stage: string) {
  if ("__TAURI_INTERNALS__" in window) {
    await invoke("qa_visual_checkpoint", { stage });
    return true;
  }
  return false;
}

export async function completeInstallQa(checks: Record<string, unknown>) {
  if ("__TAURI_INTERNALS__" in window)
    await invoke("complete_install_qa", { checks });
}

export async function exitQaMode() {
  if ("__TAURI_INTERNALS__" in window) await invoke("exit_qa_mode");
}

export async function openProjectFolder(projectId: string) {
  if (!("__TAURI_INTERNALS__" in window)) {
    throw new Error(
      "Opening a project folder is available from the desktop app.",
    );
  }
  await invoke("open_project_folder", { projectId });
}
