import type { ProjectDetail } from "@devpulse/shared-types";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { open } from "@tauri-apps/plugin-dialog";
import {
  ArrowLeft,
  Check,
  CheckCircle2,
  Clipboard,
  Clock3,
  FolderOpen,
  Pencil,
  RefreshCw,
  ShieldAlert,
  Star,
} from "lucide-react";
import { useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import type { DataProvider } from "../providers/contracts";
import { openProjectFolder } from "../providers/local";

export function ProjectDetailsPage({
  provider,
  projectId,
  onBack,
  qaMode = false,
}: {
  provider: DataProvider;
  projectId: string;
  onBack: () => void;
  qaMode?: boolean;
}) {
  const query = useQuery({
    queryKey: ["project", projectId],
    queryFn: () => provider.getProject(projectId),
  });
  if (query.isLoading) return <DashboardSkeleton />;
  if (query.error || !query.data) {
    return (
      <ErrorState
        title="Repository details are unavailable"
        message={
          query.error instanceof Error
            ? query.error.message
            : "The latest repository scan did not return project details."
        }
        onRetry={() => void query.refetch()}
      />
    );
  }
  return (
    <ProjectDetailsContent
      key={JSON.stringify(query.data.summary)}
      provider={provider}
      item={query.data}
      projectId={projectId}
      onBack={onBack}
      qaMode={qaMode}
    />
  );
}

function ProjectDetailsContent({
  provider,
  item,
  projectId,
  onBack,
  qaMode,
}: {
  provider: DataProvider;
  item: Awaited<ReturnType<DataProvider["getProject"]>>;
  projectId: string;
  onBack: () => void;
  qaMode: boolean;
}) {
  const client = useQueryClient();
  const [copyStatus, setCopyStatus] = useState<"idle" | "success" | "error">(
    "idle",
  );
  const refresh = useMutation({
    mutationFn: () => provider.refreshProjects(),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["project", projectId] });
      await client.invalidateQueries({ queryKey: ["projects"] });
    },
  });
  const update = useMutation({
    mutationFn: (patch: Parameters<DataProvider["updateProject"]>[1]) =>
      provider.updateProject(projectId, patch),
    onSuccess: async () => {
      await client.invalidateQueries();
    },
  });
  const updatePath = useMutation({
    mutationFn: (path: string) => provider.updateProjectPath(projectId, path),
    onSuccess: async () => {
      await client.invalidateQueries();
      onBack();
    },
  });
  const summary = item.summary;
  const state = repositoryState(summary);
  const sync = repositorySync(summary);

  async function chooseUpdatedPath() {
    const path = await open({
      directory: true,
      multiple: false,
      title: "Choose the updated repository path",
    });
    if (typeof path === "string") updatePath.mutate(path);
  }
  async function copyPath() {
    try {
      await navigator.clipboard.writeText(summary.path);
      setCopyStatus("success");
    } catch {
      setCopyStatus("error");
    }
    window.setTimeout(() => setCopyStatus("idle"), 2_000);
  }
  function rename() {
    const name = window.prompt("DevPulse display name", summary.name);
    if (name?.trim()) update.mutate({ name: name.trim() });
  }
  function editTags() {
    const tags = window.prompt(
      "Local tags, separated by commas",
      summary.tags.join(", "),
    );
    if (tags !== null) {
      update.mutate({
        tags: tags
          .split(",")
          .map((tag) => tag.trim())
          .filter(Boolean),
      });
    }
  }
  function editNotes() {
    const notes = window.prompt(
      "Private local notes (stored only by DevPulse)",
      summary.notes,
    );
    if (notes !== null) update.mutate({ notes });
  }

  return (
    <div className="page details-page">
      <button className="text-button details-back" onClick={onBack}>
        <ArrowLeft size={15} /> Back to repositories
      </button>

      <header className="page-header repository-identity">
        <div className="repository-title">
          <div className="repository-title-line">
            <p className="eyebrow">Repository</p>
            {summary.favorite && (
              <span className="favorite-label">
                <Star size={13} fill="currentColor" /> Favorite
              </span>
            )}
          </div>
          <h1>{summary.name}</h1>
          <p className="full-path" title={summary.path}>
            {summary.path}
          </p>
        </div>
        <div className="header-actions details-primary-actions">
          <button
            className="button"
            onClick={() => void copyPath()}
            aria-label="Copy repository path"
            aria-live="polite"
          >
            {copyStatus === "success" ? (
              <Check size={15} />
            ) : (
              <Clipboard size={15} />
            )}
            {copyStatus === "success"
              ? "Path copied"
              : copyStatus === "error"
                ? "Couldn\u2019t copy path"
                : "Copy path"}
          </button>
          <button
            className="button"
            onClick={() => void openProjectFolder(summary.id)}
            disabled={!summary.exists}
          >
            <FolderOpen size={15} /> Open folder
          </button>
          <button
            className="button button-primary"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
          >
            <RefreshCw size={16} className={refresh.isPending ? "spin" : ""} />
            {refresh.isPending ? "Scanning" : "Scan repository"}
          </button>
        </div>
      </header>

      <section
        className={`repository-state-bar state-${state.tone}`}
        aria-label="Repository state"
      >
        <div className="state-summary">
          <span className="state-symbol" aria-hidden="true">
            {state.tone === "healthy" ? (
              <CheckCircle2 size={22} />
            ) : (
              <ShieldAlert size={22} />
            )}
          </span>
          <div>
            <small>Current state</small>
            <h2>{state.label}</h2>
            <p>{sync}</p>
          </div>
        </div>
        <StateFact label="Branch" value={summary.branch || "Unknown"} code />
        <StateFact
          label="Local changes"
          value={
            summary.changed_files === 0
              ? "None"
              : `${summary.changed_files} ${summary.changed_files === 1 ? "file" : "files"}`
          }
        />
        <StateFact label="Health" value={`${summary.health_score}/100`} />
        <StateFact
          label="Last scan"
          value={formatRelativeScan(summary.last_scan_timestamp)}
        />
      </section>

      <section
        className="repository-warning-area"
        aria-label="Repository warnings"
      >
        {item.warning_details.length ? (
          <div className="warning-stack">
            <div className="warning-stack-heading">
              <ShieldAlert size={18} />
              <div>
                <strong>
                  {item.warning_details.length} repository
                  {item.warning_details.length === 1 ? " warning" : " warnings"}
                </strong>
                <span>
                  Manual review is recommended. DevPulse changed nothing.
                </span>
              </div>
            </div>
            {item.warning_details.slice(0, 3).map((warning) => (
              <WarningDetail key={warning.code} warning={warning} />
            ))}
            {item.warning_details.length > 3 && (
              <details className="warning-more">
                <summary>
                  Show {item.warning_details.length - 3} more warnings
                </summary>
                {item.warning_details.slice(3).map((warning) => (
                  <WarningDetail key={warning.code} warning={warning} />
                ))}
              </details>
            )}
          </div>
        ) : (
          <div className="clear-state repository-clear-state">
            <CheckCircle2 size={19} />
            <div>
              <strong>No repository warnings</strong>
              <span>The latest scan did not identify a warning condition.</span>
            </div>
          </div>
        )}
      </section>

      <div className="repository-actions-bar" aria-label="Repository actions">
        <span>DevPulse metadata and tracking</span>
        <div>
          <button className="text-button" onClick={rename}>
            <Pencil size={14} /> Rename
          </button>
          <button
            className="text-button"
            onClick={() => update.mutate({ favorite: !summary.favorite })}
          >
            <Star size={14} fill={summary.favorite ? "currentColor" : "none"} />
            {summary.favorite ? "Remove favorite" : "Add favorite"}
          </button>
          <button
            className="text-button"
            onClick={() => update.mutate({ archived: !summary.archived })}
          >
            {summary.archived ? "Restore repository" : "Archive repository"}
          </button>
          <button
            className="text-button"
            onClick={() => void chooseUpdatedPath()}
            disabled={qaMode}
          >
            Update path
          </button>
        </div>
      </div>

      <div className="detail-primary-grid">
        <section
          className="overview-section git-state-section"
          aria-label="Git state"
        >
          <DetailHeading
            title="Git state"
            detail="Working tree, upstream relationship, and recent local history."
          />
          <div className="git-state-grid">
            <StateFact
              label="Modified"
              value={String(summary.modified_count)}
            />
            <StateFact label="Staged" value={String(summary.staged_count)} />
            <StateFact
              label="Untracked"
              value={String(summary.untracked_count)}
            />
            <StateFact
              label="Remote"
              value={item.remote_present ? "Configured" : "Not detected"}
            />
          </div>
          <div className="subsection-heading">
            <h3>Recent commits</h3>
            <span>{item.commits.length}</span>
          </div>
          {item.commits.length ? (
            <ol className="commit-list">
              {item.commits.map((commit) => (
                <li key={commit.short_sha}>
                  <code>{commit.short_sha}</code>
                  <div>
                    <strong title={commit.message}>{commit.message}</strong>
                    <span>
                      {commit.author} · {new Date(commit.date).toLocaleString()}
                    </span>
                  </div>
                </li>
              ))}
            </ol>
          ) : (
            <p className="compact-empty">
              No commits are available for this repository.
            </p>
          )}
        </section>

        <section
          className="overview-section health-section"
          aria-label="Health signals"
        >
          <DetailHeading
            title="Health signals"
            detail="Transparent repository cues—not a code-quality or security grade."
          />
          <div className="health-score-lockup">
            <strong>{summary.health_score}</strong>
            <span>out of 100</span>
          </div>
          {item.health_breakdown.length ? (
            <ul className="health-list">
              {item.health_breakdown.map((check) => (
                <li
                  key={check.label}
                  className={check.earned ? "earned" : "missed"}
                >
                  <span>
                    {check.label}
                    <small>{check.detail}</small>
                  </span>
                  <b>
                    {check.earned ? "+" : ""}
                    {check.points}
                  </b>
                </li>
              ))}
            </ul>
          ) : (
            <p className="compact-empty">
              No health breakdown is available yet.
            </p>
          )}
        </section>
      </div>

      <section
        className="overview-section changed-files-section"
        aria-label="Changed files"
      >
        <DetailHeading
          title="Changed files"
          detail="File names only. DevPulse never displays file contents."
        />
        <div className="file-columns">
          <FilePanel title="Modified" files={item.modified_files} />
          <FilePanel title="Staged" files={item.staged_files} />
          <FilePanel title="Untracked" files={item.untracked_files} />
        </div>
      </section>

      <section
        className="overview-section repository-context"
        aria-label="Repository context"
      >
        <DetailHeading
          title="Repository context"
          detail="Detected stack and project shape from the latest read-only scan."
        />
        <div className="context-grid">
          <ContextGroup
            title="Technology"
            primary={summary.technologies.join(" · ") || "None detected"}
            secondary={`Primary: ${summary.primary_technology || "Unknown"}`}
          />
          <ContextGroup
            title="Tooling"
            primary={`Dependencies: ${item.dependency_manager ?? "Not detected"}`}
            secondary={`Tests: ${item.testing_framework ?? "Not detected"} · CI: ${item.ci_provider ?? "Not detected"}`}
          />
          <ContextGroup
            title="Repository shape"
            primary={`${item.monorepo ? "Likely monorepo" : "Single project"} · ${item.container_support ? "Container support" : "No container signal"}`}
            secondary={`Apps: ${item.application_directories.join(" · ") || "None detected"}`}
          />
          <ContextGroup
            title="Project files"
            primary={item.important_files.join(" · ") || "None detected"}
            secondary={
              item.documentation_directory
                ? "Documentation directory detected"
                : "No documentation directory detected"
            }
          />
        </div>
      </section>

      <section
        className="overview-section project-local-metadata"
        aria-label="Local project metadata"
      >
        <DetailHeading
          title="Local project metadata"
          detail="Stored only by DevPulse. Repository files remain unchanged."
        />
        <div className="local-metadata-grid">
          <div>
            <span>Display name</span>
            <strong>{summary.name}</strong>
            <button className="text-button" onClick={rename}>
              Edit
            </button>
          </div>
          <div>
            <span>Tags</span>
            <strong>
              {summary.tags.length ? summary.tags.join(", ") : "No tags"}
            </strong>
            <button className="text-button" onClick={editTags}>
              Edit
            </button>
          </div>
          <div className="notes-field">
            <span>Private notes</span>
            <strong>{summary.notes || "No private notes"}</strong>
            <button className="text-button" onClick={editNotes}>
              Edit
            </button>
          </div>
        </div>
      </section>

      <p className="detail-scan-time">
        <Clock3 size={14} /> Last successful scan{" "}
        {formatDate(summary.last_scan_timestamp)}
      </p>
      {update.isSuccess && (
        <p className="inline-success" role="status">
          <Check size={14} /> DevPulse metadata saved locally.
        </p>
      )}
    </div>
  );
}

function repositoryState(
  summary: Awaited<ReturnType<DataProvider["getProjects"]>>["items"][number],
) {
  if (!summary.exists || summary.status === "missing") {
    return { label: "Repository path unavailable", tone: "error" as const };
  }
  if (summary.error || summary.status === "access_error") {
    return { label: "Repository scan unavailable", tone: "error" as const };
  }
  if (!summary.is_git_repository || summary.status === "not_git") {
    return { label: "Not a Git repository", tone: "warning" as const };
  }
  if (summary.status === "detached") {
    return { label: "Detached HEAD", tone: "warning" as const };
  }
  if (summary.changed_files > 0 || summary.status !== "clean") {
    return { label: "Local changes present", tone: "warning" as const };
  }
  return { label: "Clean working tree", tone: "healthy" as const };
}

function repositorySync(
  summary: Awaited<ReturnType<DataProvider["getProjects"]>>["items"][number],
) {
  if (!summary.tracking_branch) return "No upstream branch is configured";
  if (summary.ahead_count > 0 && summary.behind_count > 0) {
    return `${summary.ahead_count} ${pluralisedCommit(summary.ahead_count)} ahead and ${summary.behind_count} behind ${summary.tracking_branch}`;
  }
  if (summary.ahead_count > 0) {
    return `${summary.ahead_count} local ${pluralisedCommit(summary.ahead_count)} not on ${summary.tracking_branch}`;
  }
  if (summary.behind_count > 0) {
    return `${summary.behind_count} ${pluralisedCommit(summary.behind_count)} behind ${summary.tracking_branch}`;
  }
  return `Up to date with ${summary.tracking_branch}`;
}

function pluralisedCommit(count: number) {
  return count === 1 ? "commit" : "commits";
}

function WarningDetail({
  warning,
}: {
  warning: ProjectDetail["warning_details"][number];
}) {
  return (
    <article className="warning-detail">
      <strong>{warning.title}</strong>
      <span>
        {warning.what} {warning.why}
      </span>
      <small>
        {warning.changed} Suggested manual action: {warning.suggested_action}
      </small>
    </article>
  );
}

function StateFact({
  label,
  value,
  code = false,
}: {
  label: string;
  value: string;
  code?: boolean;
}) {
  return (
    <div className="state-fact">
      <span>{label}</span>
      {code ? (
        <code title={value}>{value}</code>
      ) : (
        <strong title={value}>{value}</strong>
      )}
    </div>
  );
}

function DetailHeading({ title, detail }: { title: string; detail: string }) {
  return (
    <div className="section-heading detail-section-heading">
      <div>
        <h2>{title}</h2>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function FilePanel({ title, files }: { title: string; files: string[] }) {
  return (
    <div className="file-column">
      <div className="file-column-heading">
        <h3>{title}</h3>
        <span>{files.length}</span>
      </div>
      {files.length ? (
        <ul className="file-list">
          {files.map((file) => (
            <li key={file}>{file}</li>
          ))}
        </ul>
      ) : (
        <p className="compact-empty">No files in this category.</p>
      )}
      <p className="visually-hidden">
        {title === "Staged"
          ? "File names only; no contents are displayed."
          : "File contents are never displayed."}
      </p>
    </div>
  );
}

function ContextGroup({
  title,
  primary,
  secondary,
}: {
  title: string;
  primary: string;
  secondary: string;
}) {
  return (
    <div className="context-group">
      <span>{title}</span>
      <strong>{primary}</strong>
      <small>{secondary}</small>
    </div>
  );
}

function formatRelativeScan(value: string) {
  const elapsed = Date.now() - new Date(value).getTime();
  if (elapsed >= 0 && elapsed < 60_000) return "Just now";
  if (elapsed >= 0 && elapsed < 3_600_000) {
    const minutes = Math.max(1, Math.round(elapsed / 60_000));
    return `${minutes} min ago`;
  }
  return formatDate(value);
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}
