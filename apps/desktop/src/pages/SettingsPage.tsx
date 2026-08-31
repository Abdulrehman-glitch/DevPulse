import type { ConfigurationExport, Settings } from "@devpulse/shared-types";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Download,
  FileUp,
  KeyRound,
  LockKeyhole,
  Save,
  ShieldCheck,
  Trash2,
  Upload,
} from "lucide-react";
import { useRef, useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import { useFocusTrap } from "../components/useFocusTrap";
import type { DataProvider } from "../providers/contracts";

export function SettingsPage({
  provider,
  version = "0.3.0",
}: {
  provider: DataProvider;
  version?: string;
}) {
  const query = useQuery({
    queryKey: ["settings"],
    queryFn: () => provider.getSettings(),
  });
  if (query.isLoading) return <DashboardSkeleton />;
  if (query.error)
    return (
      <ErrorState
        message={
          query.error instanceof Error
            ? query.error.message
            : "Settings are unavailable."
        }
        onRetry={() => void query.refetch()}
      />
    );
  if (!query.data) return null;
  return (
    <SettingsForm
      key={JSON.stringify(query.data)}
      provider={provider}
      settings={query.data}
      version={version}
    />
  );
}

function SettingsForm({
  provider,
  settings,
  version,
}: {
  provider: DataProvider;
  settings: Settings;
  version: string;
}) {
  const client = useQueryClient();
  const [draft, setDraft] = useState(settings);
  const [ignored, setIgnored] = useState(
    settings.ignored_directories.join(", "),
  );
  const [notificationPreferences, setNotificationPreferences] = useState(
    settings.notification_preferences,
  );
  const [importPreview, setImportPreview] = useState<{
    payload: ConfigurationExport;
    additions: number;
    updates: number;
    conflicts: number;
  } | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const importCancelRef = useRef<HTMLButtonElement>(null);
  const importDialogRef = useFocusTrap<HTMLElement>(
    importPreview !== null,
    () => setImportPreview(null),
    importCancelRef,
  );
  const save = useMutation({
    mutationFn: () =>
      provider.updateSettings({
        refresh_interval_seconds: draft.refresh_interval_seconds,
        cache_duration_seconds: draft.cache_duration_seconds,
        maximum_scan_depth: draft.maximum_scan_depth,
        maximum_repositories_per_root: draft.maximum_repositories_per_root,
        maximum_directories_per_scan: draft.maximum_directories_per_scan,
        scan_timeout_seconds: draft.scan_timeout_seconds,
        ignored_directories: ignored
          .split(/[,\n]/)
          .map((item) => item.trim())
          .filter(Boolean),
        start_minimized: draft.start_minimized,
        appearance: draft.appearance,
        reduced_motion: draft.reduced_motion,
        log_level: draft.log_level,
        confirm_before_removing_project: draft.confirm_before_removing_project,
        default_landing_page: draft.default_landing_page,
        date_time_display: draft.date_time_display,
        table_density: draft.table_density,
        stale_project_days: draft.stale_project_days,
        default_sort: draft.default_sort,
        notification_severity_threshold: draft.notification_severity_threshold,
        notification_history_length: draft.notification_history_length,
        notification_preferences: notificationPreferences,
      }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["settings"] });
    },
  });
  const backups = useQuery({
    queryKey: ["backups"],
    queryFn: () => provider.getBackups(),
  });
  const backup = useMutation({
    mutationFn: () => provider.createBackup(),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["backups"] });
    },
  });
  const restore = useMutation({
    mutationFn: (id: string) => provider.restoreBackup(id),
    onSuccess: async () => {
      await client.invalidateQueries();
    },
  });
  const deleteBackup = useMutation({
    mutationFn: (id: string) => provider.deleteBackup(id),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["backups"] });
    },
  });
  function number<K extends keyof Settings>(key: K, value: number) {
    setDraft((current) => ({ ...current, [key]: value }));
  }
  function download(payload: ConfigurationExport, filename: string) {
    const blob = new Blob([JSON.stringify(payload, null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    anchor.click();
    URL.revokeObjectURL(url);
  }
  async function exportConfiguration(includeNotes: boolean) {
    if (
      includeNotes &&
      !window.confirm(
        "Include private local notes in this export? Notes remain local unless you choose where to save this file.",
      )
    )
      return;
    const payload = await provider.exportConfiguration(includeNotes);
    download(
      payload,
      `devpulse-beta1-config${includeNotes ? "-with-notes" : ""}.json`,
    );
  }
  async function importFile(file: File) {
    try {
      const payload = JSON.parse(await file.text()) as ConfigurationExport;
      const preview = await provider.previewConfigurationImport(payload);
      setImportPreview({
        payload,
        additions: preview.additions.length,
        updates: preview.updates.length,
        conflicts: preview.conflicts.length,
      });
    } catch (error) {
      window.alert(
        error instanceof Error
          ? error.message
          : "The configuration file could not be read.",
      );
    }
  }
  return (
    <div className="page settings-page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Application preferences</p>
          <h1>Settings</h1>
          <p className="page-description">
            Shape the local workspace while permanent safety boundaries stay
            locked.
          </p>
        </div>
        <div className="version-stamp">
          Schema {settings.schema_version} · DevPulse {version}
        </div>
      </header>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          save.mutate();
        }}
      >
        <section className="panel settings-form">
          <div className="section-heading">
            <h2>General</h2>
            <p>
              Display and refresh preferences remain in DevPulse application
              data.
            </p>
          </div>
          <div className="settings-grid">
            <NumberField
              label="Refresh interval (seconds)"
              min={0}
              max={86400}
              value={draft.refresh_interval_seconds}
              onChange={(value) => number("refresh_interval_seconds", value)}
            />
            <label className="field-group">
              <span>Default landing page</span>
              <select
                value={draft.default_landing_page}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    default_landing_page: event.target
                      .value as Settings["default_landing_page"],
                  })
                }
              >
                <option value="overview">Overview</option>
                <option value="projects">Projects</option>
                <option value="activity">Activity</option>
                <option value="system">System</option>
              </select>
            </label>
            <label className="field-group">
              <span>Appearance</span>
              <select
                value={draft.appearance}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    appearance: event.target.value as Settings["appearance"],
                  })
                }
              >
                <option value="system">System</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
            </label>
            <label className="field-group">
              <span>Table density</span>
              <select
                value={draft.table_density}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    table_density: event.target
                      .value as Settings["table_density"],
                  })
                }
              >
                <option value="comfortable">Comfortable</option>
                <option value="compact">Compact</option>
              </select>
            </label>
            <label className="field-group">
              <span>Date and time display</span>
              <select
                value={draft.date_time_display}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    date_time_display: event.target
                      .value as Settings["date_time_display"],
                  })
                }
              >
                <option value="local">Local time</option>
                <option value="utc">UTC</option>
              </select>
            </label>
          </div>
          <div className="toggle-list">
            <Toggle
              label="Start minimised"
              detail="Window preference only; Windows startup is not configured."
              checked={draft.start_minimized}
              onChange={(value) =>
                setDraft({ ...draft, start_minimized: value })
              }
            />
            <Toggle
              label="Reduced motion"
              detail="Removes nonessential interface animation."
              checked={draft.reduced_motion}
              onChange={(value) =>
                setDraft({ ...draft, reduced_motion: value })
              }
            />
          </div>
        </section>
        <section className="panel settings-form">
          <div className="section-heading">
            <h2>Projects</h2>
            <p>
              Limits are intentionally bounded to protect the laptop and keep
              the interface responsive.
            </p>
          </div>
          <div className="settings-grid">
            <NumberField
              label="Maximum scan depth"
              min={0}
              max={12}
              value={draft.maximum_scan_depth}
              onChange={(value) => number("maximum_scan_depth", value)}
            />
            <NumberField
              label="Repositories per root"
              min={1}
              max={500}
              value={draft.maximum_repositories_per_root}
              onChange={(value) =>
                number("maximum_repositories_per_root", value)
              }
            />
            <NumberField
              label="Directories per scan"
              min={50}
              max={50000}
              value={draft.maximum_directories_per_scan}
              onChange={(value) =>
                number("maximum_directories_per_scan", value)
              }
            />
            <NumberField
              label="Scan timeout (seconds)"
              min={2}
              max={120}
              value={draft.scan_timeout_seconds}
              onChange={(value) => number("scan_timeout_seconds", value)}
            />
            <NumberField
              label="Stale-project threshold (days)"
              min={1}
              max={3650}
              value={draft.stale_project_days}
              onChange={(value) => number("stale_project_days", value)}
            />
            <label className="field-group">
              <span>Default project sort</span>
              <select
                value={draft.default_sort}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    default_sort: event.target
                      .value as Settings["default_sort"],
                  })
                }
              >
                <option value="name">Name</option>
                <option value="recent">Recent commit</option>
                <option value="changes">Change count</option>
                <option value="health">Health</option>
                <option value="warnings">Warnings</option>
                <option value="refresh">Last refresh</option>
              </select>
            </label>
          </div>
          <label className="field-group">
            <span>Ignored directory names</span>
            <small>Plain names only, separated with commas.</small>
            <textarea
              rows={3}
              value={ignored}
              onChange={(event) => setIgnored(event.target.value)}
            />
          </label>
        </section>
        <section className="panel settings-form">
          <div className="section-heading">
            <h2>Notifications</h2>
            <p>
              In-app attention signals only. There is no background agent,
              email, or cloud notification service.
            </p>
          </div>
          <div className="settings-grid">
            <label className="field-group">
              <span>Severity threshold</span>
              <select
                value={draft.notification_severity_threshold}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    notification_severity_threshold: event.target
                      .value as Settings["notification_severity_threshold"],
                  })
                }
              >
                <option value="info">Info</option>
                <option value="success">Success</option>
                <option value="warning">Warning</option>
                <option value="error">Error</option>
              </select>
            </label>
            <NumberField
              label="History length"
              min={20}
              max={2000}
              value={draft.notification_history_length}
              onChange={(value) => number("notification_history_length", value)}
            />
          </div>
          <div className="notification-preference-list">
            <Preference
              label="Missing project path"
              checked={notificationPreferences.missing_path !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  missing_path: checked,
                })
              }
            />
            <Preference
              label="Scan failed"
              checked={notificationPreferences.scan_failed !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  scan_failed: checked,
                })
              }
            />
            <Preference
              label="Repository became modified"
              checked={notificationPreferences.modified !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  modified: checked,
                })
              }
            />
            <Preference
              label="Behind remote"
              checked={notificationPreferences.behind_remote !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  behind_remote: checked,
                })
              }
            />
            <Preference
              label="Detached HEAD"
              checked={notificationPreferences.detached_head !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  detached_head: checked,
                })
              }
            />
            <Preference
              label="Core restart"
              checked={notificationPreferences.core_restart !== false}
              onChange={(checked) =>
                setNotificationPreferences({
                  ...notificationPreferences,
                  core_restart: checked,
                })
              }
            />
          </div>
        </section>
        <section className="panel settings-form">
          <div className="section-heading">
            <h2>Storage and portability</h2>
            <p>
              Exports contain settings and registrations only. Logs, caches,
              credentials, environment values, and file contents never leave
              DevPulse.
            </p>
          </div>
          <div className="storage-actions">
            <button
              type="button"
              className="button"
              onClick={() => void exportConfiguration(false)}
            >
              <Download size={15} /> Export configuration
            </button>
            <button
              type="button"
              className="button"
              onClick={() => void exportConfiguration(true)}
            >
              <KeyRound size={15} /> Export with private notes
            </button>
            <button
              type="button"
              className="button"
              onClick={() => inputRef.current?.click()}
            >
              <Upload size={15} /> Import configuration
            </button>
            <input
              ref={inputRef}
              className="visually-hidden"
              type="file"
              accept="application/json,.json"
              onChange={(event) => {
                const file = event.target.files?.[0];
                if (file) void importFile(file);
                event.currentTarget.value = "";
              }}
            />
            <button
              type="button"
              className="button"
              onClick={() => backup.mutate()}
            >
              <Save size={15} /> Create local backup
            </button>
          </div>
          <div className="backup-list">
            <div className="section-heading">
              <h3>DevPulse-owned backups</h3>
              <p>
                Automatic pre-import and pre-migration backups are kept here.
              </p>
            </div>
            {backups.data?.length ? (
              backups.data.map((item) => (
                <div className="backup-row" key={item.id}>
                  <div>
                    <strong>{item.id}</strong>
                    <span>
                      {new Date(item.created_at).toLocaleString()} ·{" "}
                      {Math.round(item.size_bytes / 1024)} KB
                    </span>
                  </div>
                  <div>
                    <button
                      type="button"
                      className="text-button"
                      onClick={() => {
                        if (
                          window.confirm(
                            "Restore this DevPulse configuration backup?",
                          )
                        )
                          restore.mutate(item.id);
                      }}
                    >
                      <FileUp size={14} /> Restore
                    </button>
                    <button
                      type="button"
                      className="text-button danger-text"
                      onClick={() => deleteBackup.mutate(item.id)}
                    >
                      <Trash2 size={14} /> Delete
                    </button>
                  </div>
                </div>
              ))
            ) : (
              <p className="compact-empty">No backups created yet.</p>
            )}
          </div>
        </section>
        <section className="panel safety-section">
          <div className="safety-heading">
            <ShieldCheck />
            <div>
              <h2>Safety</h2>
              <p>These product boundaries cannot be disabled.</p>
            </div>
          </div>
          <div className="safety-grid">
            {[
              ["Read-only repository mode", "Enabled"],
              ["Project command execution", "Unavailable"],
              ["Full-drive scanning", "Unavailable"],
              ["External repository writes", "Blocked"],
              ["Automatic startup", "Unavailable"],
              ["Automatic updates", "Unavailable in beta.1"],
              ["Telemetry", "Disabled"],
              ["Cloud sync", "Unavailable"],
            ].map(([label, value]) => (
              <div key={label}>
                <LockKeyhole size={14} />
                <span>{label}</span>
                <strong>{value}</strong>
              </div>
            ))}
          </div>
        </section>
        <section className="panel about-panel">
          <div className="section-heading">
            <h2>About and privacy</h2>
            <p>
              DevPulse v{version} · local-core API v1 · Windows desktop beta.
            </p>
          </div>
          <p>
            DevPulse reads bounded Git metadata and relevant system capacity.
            Project paths and local notes stay in DevPulse-owned application
            data. No cloud account is required and telemetry is disabled.
          </p>
          <p>
            Safe diagnostics are available from the Diagnostics page.
            Open-source dependency notices and documentation live in the
            repository docs folder.
          </p>
        </section>
        <div className="settings-actions">
          <span role="status">
            {save.isSuccess
              ? "Settings saved"
              : save.isError
                ? save.error instanceof Error
                  ? save.error.message
                  : "Settings could not be saved"
                : "Stored in DevPulse application data"}
          </span>
          <button className="button button-primary" disabled={save.isPending}>
            <Save size={16} /> Save changes
          </button>
        </div>
      </form>
      {importPreview && (
        <div className="modal-backdrop">
          <section
            ref={importDialogRef}
            className="import-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="import-title"
          >
            <h2 id="import-title">Review configuration import</h2>
            <p>
              This preview changes DevPulse settings and local registrations
              only. External project files will not be overwritten.
            </p>
            <div className="import-counts">
              <strong>
                {importPreview.additions}
                <span>Additions</span>
              </strong>
              <strong>
                {importPreview.updates}
                <span>Updates</span>
              </strong>
              <strong>
                {importPreview.conflicts}
                <span>Existing conflicts</span>
              </strong>
            </div>
            <div className="dialog-actions">
              <button
                ref={importCancelRef}
                className="button"
                onClick={() => setImportPreview(null)}
              >
                Cancel
              </button>
              <button
                className="button button-primary"
                onClick={() => {
                  provider
                    .importConfiguration(importPreview.payload)
                    .then(() => {
                      setImportPreview(null);
                      void client.invalidateQueries();
                    })
                    .catch((error: unknown) =>
                      window.alert(
                        error instanceof Error
                          ? error.message
                          : "Import failed.",
                      ),
                    );
                }}
              >
                Create backup and import
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}

function NumberField({
  label,
  min,
  max,
  value,
  onChange,
}: {
  label: string;
  min: number;
  max: number;
  value: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="field-group">
      <span>{label}</span>
      <input
        type="number"
        required
        min={min}
        max={max}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
      />
    </label>
  );
}
function Toggle({
  label,
  detail,
  checked,
  onChange,
}: {
  label: string;
  detail: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="toggle-row">
      <span>
        <strong>{label}</strong>
        <small>{detail}</small>
      </span>
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
    </label>
  );
}
function Preference({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="preference-row">
      <span>{label}</span>
      <input
        type="checkbox"
        checked={checked}
        aria-label={`Enable ${label} notifications`}
        onChange={(event) => onChange(event.target.checked)}
      />
    </label>
  );
}
