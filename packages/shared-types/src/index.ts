export type CoreConnection = {
  status: "starting" | "ready" | "recovering" | "failed" | "stopped";
  address?: string;
  token?: string;
  version?: string;
  message?: string;
  diagnosticsPath?: string;
  failureCode?: string;
  recoveryAttempt?: number;
  recoveryLimit?: number;
  qaMode?: boolean;
  qaAutomation?: boolean;
  installQa?: boolean;
};

export type SystemSummary = {
  cpu_percent: number | null;
  logical_processors: number | null;
  memory_percent: number | null;
  memory_available_bytes: number | null;
  disk_percent: number | null;
  volumes: Array<{ mount: string; usage_percent: number; free_bytes: number }>;
  process_uptime_seconds: number;
  scan_worker_status: "idle" | "scanning";
  cache_status: "ready" | "empty" | "unavailable";
  application_data_location: string;
  log_directory_location: string;
  repositories_total: number;
  clean_repositories: number;
  modified_repositories: number;
  repositories_with_warnings: number;
  average_health_score: number | null;
  last_successful_refresh: string | null;
  refreshing: boolean;
};

export type ProjectSummary = {
  id: string;
  name: string;
  path: string;
  favorite: boolean;
  tags: string[];
  notes: string;
  archived: boolean;
  exists: boolean;
  is_git_repository: boolean;
  branch: string;
  tracking_branch: string | null;
  status: string;
  changed_files: number;
  modified_count: number;
  staged_count: number;
  untracked_count: number;
  ahead_count: number;
  behind_count: number;
  last_commit_message: string;
  last_commit_author: string;
  last_commit_date: string | null;
  repository_age_days: number | null;
  recent_activity: boolean | null;
  primary_technology: string;
  technologies: string[];
  health_score: number;
  warning_count: number;
  last_scan_duration_ms: number;
  last_scan_timestamp: string;
  error: string | null;
};

export type ProjectDetail = {
  summary: ProjectSummary;
  modified_files: string[];
  staged_files: string[];
  untracked_files: string[];
  important_files: string[];
  root_files: string[];
  dependency_manager: string | null;
  testing_framework: string | null;
  ci_provider: string | null;
  container_support: boolean;
  deployment_indicators: string[];
  monorepo: boolean;
  application_directories: string[];
  documentation_directory: boolean;
  remote_present: boolean;
  commits: Array<{
    short_sha: string;
    message: string;
    author: string;
    date: string;
  }>;
  health_breakdown: Array<{
    label: string;
    points: number;
    earned: boolean;
    detail: string;
  }>;
  warnings: string[];
  warning_details: Array<{
    code: string;
    title: string;
    what: string;
    why: string;
    changed: string;
    suggested_action: string;
  }>;
};

export type ProjectList = {
  items: ProjectSummary[];
  total: number;
  last_successful_refresh: string | null;
};

export type ActivityEvent = {
  id: string;
  timestamp: string;
  kind: "info" | "success" | "warning" | "error";
  event_type:
    | "application_started"
    | "core_started"
    | "core_connected"
    | "project_added"
    | "project_removed"
    | "scan_started"
    | "scan_completed"
    | "scan_failed"
    | "configuration_updated"
    | "configuration_migrated"
    | "configuration_imported"
    | "configuration_exported"
    | "recovery_performed"
    | "core_restarted"
    | "shutdown_requested"
    | "qa_mode_started"
    | "qa_data_reset"
    | "qa_data_regenerated"
    | "project_archived"
    | "project_restored"
    | "warning_appeared"
    | "warning_resolved";
  message: string;
  project_id: string | null;
};

export type ActivityList = { items: ActivityEvent[] };

export type Settings = {
  schema_version: number;
  onboarding_completed: boolean;
  projects: Array<{
    name: string;
    path: string;
    favorite: boolean;
    tags: string[];
    notes: string;
    archived: boolean;
  }>;
  scan_roots: Array<{ path: string; recursive: boolean }>;
  ignored_directories: string[];
  maximum_scan_depth: number;
  maximum_repositories_per_root: number;
  maximum_directories_per_scan: number;
  maximum_entries_per_scan: number;
  scan_timeout_seconds: number;
  repository_scan_timeout_seconds: number;
  maximum_changed_paths: number;
  cache_duration_seconds: number;
  refresh_interval_seconds: number;
  maximum_commits_displayed: number;
  appearance: "system" | "light" | "dark";
  start_minimized: boolean;
  reduced_motion: boolean;
  confirm_before_removing_project: boolean;
  log_level: string;
  default_landing_page: PageId;
  date_time_display: "local" | "utc";
  table_density: "comfortable" | "compact";
  stale_project_days: number;
  default_sort:
    "name" | "recent" | "changes" | "health" | "warnings" | "refresh";
  notification_preferences: Record<string, boolean>;
  notification_severity_threshold: "info" | "success" | "warning" | "error";
  notification_history_length: number;
  saved_views: Array<{
    id: string;
    name: string;
    query: string;
    status: string;
    technology: string;
    tag: string;
    warning: string;
    minimum_health: number;
    sort: string;
    favorites_only: boolean;
    show_archived: boolean;
  }>;
  active_saved_view: string | null;
};

export type SettingsPatch = Partial<Omit<Settings, "projects">> & {
  project_directories?: string[];
};

export type PageId =
  "overview" | "projects" | "activity" | "system" | "diagnostics" | "settings";

export type ProjectPatch = Partial<{
  path: string;
  name: string;
  favorite: boolean;
  tags: string[];
  notes: string;
  archived: boolean;
}>;

export type SystemHistoryPoint = {
  timestamp: string;
  cpu_percent: number | null;
  memory_percent: number | null;
  scan_duration_ms: number | null;
  refresh_succeeded: boolean | null;
  warning_count: number;
};

export type SystemHistory = { items: SystemHistoryPoint[] };

export type BackupSummary = {
  id: string;
  created_at: string;
  size_bytes: number;
  source: string;
};

export type ConfigurationExport = {
  schema_version: number;
  exported_at: string;
  includes_notes: boolean;
  settings: Record<string, unknown>;
  projects: Array<Record<string, unknown>>;
};

export type ConfigurationImportPreview = {
  additions: Array<Record<string, unknown>>;
  updates: Array<Record<string, unknown>>;
  conflicts: Array<Record<string, unknown>>;
  valid: boolean;
};

export type DesktopStatus = {
  sidecarProcessStatus: "running" | "stopped";
  processUptimeSeconds: number;
  applicationDataLocation?: string;
  logDirectoryLocation?: string;
  sidecarPid?: number;
  qaMode: boolean;
  installQa: boolean;
  startupDurationMs: number;
};

export type QaPathStatus = {
  schemaVersion: number;
  qaMode: true;
  installQa: boolean;
  qaRoot: string;
  tauriAppConfigurationDirectory: string;
  tauriAppDataDirectory: string;
  tauriLocalDataDirectory: string;
  tauriCacheDirectory: string;
  tauriLogDirectory: string;
  webView2UserDataDirectory: string;
  pythonLocalCoreConfigurationDirectory: string;
  pythonCacheDirectory: string;
  pythonLogDirectory: string;
  qaRepositoryDirectory: string;
  diagnosticsExportDirectory: string;
  activityStorage: string;
  environmentMatchesCanonicalPlan: boolean;
  tauriWebViewDirectoryMatchesCanonicalPlan: boolean;
  allWritablePathsUnderQaRoot: boolean;
};

export type QaStatus = {
  enabled: boolean;
  artificial_data: boolean;
  data_root: string | null;
  test_lab: string | null;
};

export type SafeDiagnostics = {
  devpulse_version: string;
  operating_system: string;
  qa_mode: boolean;
  local_core_status: string;
  sidecar_status: string;
  startup_duration_ms: number;
  last_scan_status: string;
  registered_projects: number;
  cache_status: string;
  configuration_schema_version: number;
  data_boundary: string;
  recent_error_codes: string[];
  log_excerpt: string[];
};

export type ApiErrorPayload = {
  error: { code: string; message: string; request_id: string };
};
