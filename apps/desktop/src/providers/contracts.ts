import type {
  ActivityList,
  ProjectList,
  ProjectDetail,
  Settings,
  SettingsPatch,
  ProjectPatch,
  SystemHistory,
  BackupSummary,
  ConfigurationExport,
  ConfigurationImportPreview,
  QaStatus,
  SafeDiagnostics,
  SystemSummary,
} from "@devpulse/shared-types";

export interface DataProvider {
  getSystemSummary(): Promise<SystemSummary>;
  getSystemHistory(): Promise<SystemHistory>;
  getProjects(): Promise<ProjectList>;
  getProject(id: string): Promise<ProjectDetail>;
  previewProject(path: string): Promise<ProjectDetail>;
  previewRoot(path: string): Promise<ProjectList>;
  addProjects(paths: string[]): Promise<Settings>;
  removeProject(id: string): Promise<Settings>;
  updateProjectPath(id: string, path: string): Promise<Settings>;
  updateProject(id: string, patch: ProjectPatch): Promise<Settings>;
  refreshProjects(): Promise<ProjectList>;
  getActivity(limit?: number): Promise<ActivityList>;
  clearActivity(): Promise<void>;
  getSettings(): Promise<Settings>;
  updateSettings(patch: SettingsPatch): Promise<Settings>;
  getQaStatus(): Promise<QaStatus>;
  resetQaData(): Promise<Settings>;
  regenerateQaData(): Promise<Settings>;
  getSafeDiagnostics(): Promise<SafeDiagnostics>;
  exportSafeDiagnostics(): Promise<string>;
  exportConfiguration(includeNotes?: boolean): Promise<ConfigurationExport>;
  previewConfigurationImport(
    payload: ConfigurationExport,
  ): Promise<ConfigurationImportPreview>;
  importConfiguration(payload: ConfigurationExport): Promise<Settings>;
  getBackups(): Promise<BackupSummary[]>;
  createBackup(): Promise<BackupSummary>;
  restoreBackup(id: string): Promise<Settings>;
  deleteBackup(id: string): Promise<void>;
}

export type LocalDataProvider = DataProvider;
export type RemoteDataProvider = DataProvider;

export interface AuthenticationProvider {
  isAuthenticated(): Promise<boolean>;
}

export interface SubscriptionProvider {
  getCurrentPlan(): Promise<string | null>;
}

export interface UpdateProvider {
  getAvailableVersion(): Promise<string | null>;
}
