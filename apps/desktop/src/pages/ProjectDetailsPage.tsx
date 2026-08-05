import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { open } from "@tauri-apps/plugin-dialog";
import {
  ArrowLeft,
  Check,
  Clipboard,
  Clock3,
  FolderOpen,
  Pencil,
  RefreshCw,
  ShieldAlert,
  Star,
} from "lucide-react";
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
  if (query.error || !query.data)
    return (
      <ErrorState
        message={
          query.error instanceof Error
            ? query.error.message
            : "Project details are unavailable."
        }
        onRetry={() => void query.refetch()}
      />
    );
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
  async function chooseUpdatedPath() {
    const path = await open({
      directory: true,
      multiple: false,
      title: "Choose the updated repository path",
    });
    if (typeof path === "string") updatePath.mutate(path);
  }
  async function copyPath() {
    await navigator.clipboard.writeText(summary.path);
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
    if (tags !== null)
      update.mutate({
        tags: tags
          .split(",")
          .map((tag) => tag.trim())
          .filter(Boolean),
      });
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
        <ArrowLeft size={15} /> Projects
      </button>
      <header className="page-header">
        <div>
          <p className="eyebrow">Repository details</p>
          <h1>{summary.name}</h1>
          <p className="full-path">{summary.path}</p>
        </div>
        <div className="header-actions details-actions">
          <button
            className="button"
            onClick={() => void copyPath()}
            title="Copy project path"
          >
            <Clipboard size={15} /> Copy path
          </button>
          <button
            className="button"
            onClick={() => void openProjectFolder(summary.id)}
            disabled={!summary.exists}
          >
            <FolderOpen size={15} /> Open folder
          </button>
          <button className="button" onClick={rename}>
            <Pencil size={15} /> Rename
          </button>
          <button
            className="button"
            onClick={() => update.mutate({ favorite: !summary.favorite })}
          >
            <Star size={15} fill={summary.favorite ? "currentColor" : "none"} />{" "}
            {summary.favorite ? "Favorited" : "Favorite"}
          </button>
          <button
            className="button"
            onClick={() => update.mutate({ archived: !summary.archived })}
          >
            {summary.archived ? "Restore" : "Archive"}
          </button>
          <button
            className="button"
            onClick={() => void chooseUpdatedPath()}
            disabled={qaMode}
          >
            Update path
          </button>
          <button
            className="button button-primary"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
          >
            <RefreshCw size={16} className={refresh.isPending ? "spin" : ""} />{" "}
            Rescan
          </button>
        </div>
      </header>
      <section className="detail-stat-grid">
        <Fact label="Status" value={summary.status} />
        <Fact label="Branch" value={summary.branch} />
        <Fact
          label="Tracking"
          value={summary.tracking_branch ?? "No upstream"}
        />
        <Fact label="Health" value={`${summary.health_score}/100`} />
        <Fact label="Warnings" value={String(summary.warning_count)} />
        <Fact
          label="Ahead / behind"
          value={`${summary.ahead_count} ahead · ${summary.behind_count} behind`}
        />
        <Fact label="Last scan" value={`${summary.last_scan_duration_ms} ms`} />
        <Fact
          label="Repository age"
          value={
            summary.repository_age_days === null
              ? "No commits"
              : `${summary.repository_age_days} days`
          }
        />
      </section>
      {item.warnings.length > 0 && (
        <section className="attention-banner">
          <ShieldAlert size={18} />
          <div>
            <strong>Repository warnings</strong>
            {item.warning_details.map((warning) => (
              <article className="warning-detail" key={warning.code}>
                <strong>{warning.title}</strong>
                <span>
                  {warning.what} {warning.why}
                </span>
                <small>
                  {warning.changed} Suggested manual action:{" "}
                  {warning.suggested_action}
                </small>
              </article>
            ))}
          </div>
        </section>
      )}
      <div className="detail-columns">
        <section className="panel">
          <div className="panel-heading">
            <div>
              <h2>Git activity</h2>
              <p>
                Read-only local history; credentials and remote URLs are never
                shown.
              </p>
            </div>
          </div>
          <div className="git-facts">
            <Fact label="Modified" value={String(summary.modified_count)} />
            <Fact label="Staged" value={String(summary.staged_count)} />
            <Fact label="Untracked" value={String(summary.untracked_count)} />
            <Fact
              label="Remote"
              value={item.remote_present ? "Present" : "None detected"}
            />
          </div>
          <h3 className="subsection-title">Last ten commits</h3>
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
            <p className="compact-empty">No commits yet.</p>
          )}
        </section>
        <section className="panel">
          <div className="panel-heading">
            <div>
              <h2>Health score</h2>
              <p>
                Transparent signals, not a security guarantee or code-quality
                certification.
              </p>
            </div>
            <strong className="large-score">{summary.health_score}/100</strong>
          </div>
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
        </section>
      </div>
      <div className="detail-columns">
        <FilePanel title="Changed files" files={item.modified_files} />
        <FilePanel title="Staged files" files={item.staged_files} />
        <FilePanel title="Untracked files" files={item.untracked_files} />
      </div>
      <section className="panel project-local-metadata">
        <div className="panel-heading">
          <div>
            <h2>Local project details</h2>
            <p>Only DevPulse metadata. Nothing is written to the repository.</p>
          </div>
          <Pencil size={18} />
        </div>
        <div className="local-metadata-grid">
          <div>
            <span>Display name</span>
            <strong>DevPulse display name</strong>
            <button className="text-button" onClick={rename}>
              Edit display name
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
      <section className="panel metadata-panel">
        <div>
          <h2>Technology</h2>
          <p>{summary.technologies.join(" · ") || "None detected"}</p>
          <small>Primary: {summary.primary_technology}</small>
        </div>
        <div>
          <h2>Tooling</h2>
          <p>Dependency manager: {item.dependency_manager ?? "Not detected"}</p>
          <p>Testing: {item.testing_framework ?? "Not detected"}</p>
          <p>CI: {item.ci_provider ?? "Not detected"}</p>
        </div>
        <div>
          <h2>Repository shape</h2>
          <p>
            Container: {item.container_support ? "Yes" : "No"} · Monorepo:{" "}
            {item.monorepo ? "Likely" : "Not detected"}
          </p>
          <p>
            Deployment:{" "}
            {item.deployment_indicators.join(" · ") || "None detected"}
          </p>
          <p>
            Apps: {item.application_directories.join(" · ") || "None detected"}
          </p>
        </div>
        <div>
          <h2>Root files</h2>
          <p>{item.important_files.join(" · ") || "None detected"}</p>
          <p>
            Documentation:{" "}
            {item.documentation_directory
              ? "docs directory"
              : "No docs directory"}
          </p>
        </div>
        <div>
          <h2>Last successful scan</h2>
          <p>
            <Clock3 size={14} />{" "}
            {new Date(summary.last_scan_timestamp).toLocaleString()}
          </p>
        </div>
      </section>
      {update.isSuccess && (
        <p className="inline-success" role="status">
          <Check size={14} /> DevPulse metadata saved locally.
        </p>
      )}
    </div>
  );
}

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <article>
      <span>{label}</span>
      <strong title={value}>{value}</strong>
    </article>
  );
}
function FilePanel({ title, files }: { title: string; files: string[] }) {
  return (
    <section className="panel">
      <div className="panel-heading">
        <div>
          <h2>{title}</h2>
          <p>
            {title === "Staged files"
              ? "File names only; no contents are displayed."
              : "Informational only. File contents are never displayed."}
          </p>
        </div>
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
    </section>
  );
}
