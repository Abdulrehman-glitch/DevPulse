import type { ProjectSummary } from "@devpulse/shared-types";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Activity,
  CheckCircle2,
  Clock3,
  GitBranch,
  RefreshCw,
  Search,
  TriangleAlert,
} from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import { MetricStrip } from "../components/MetricStrip";
import { ProjectTable } from "../components/ProjectTable";
import type { DataProvider } from "../providers/contracts";

export function OverviewPage({
  provider,
  onAddProject,
  onAddRoot,
  onOpen,
  qaMode = false,
}: {
  provider: DataProvider;
  onAddProject: () => void;
  onAddRoot: () => void;
  onOpen?: (id: string) => void;
  qaMode?: boolean;
}) {
  const queryClient = useQueryClient();
  const [projectSearch, setProjectSearch] = useState("");
  const summary = useQuery({
    queryKey: ["system-summary"],
    queryFn: () => provider.getSystemSummary(),
    refetchInterval: 5_000,
  });
  const projects = useQuery({
    queryKey: ["projects"],
    queryFn: () => provider.getProjects(),
  });
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => provider.getSettings(),
  });
  const activity = useQuery({
    queryKey: ["activity"],
    queryFn: () => provider.getActivity(20),
    refetchInterval: 10_000,
  });
  const refresh = useMutation({
    mutationFn: () => provider.refreshProjects(),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["system-summary"] }),
        queryClient.invalidateQueries({ queryKey: ["projects"] }),
        queryClient.invalidateQueries({ queryKey: ["activity"] }),
      ]);
    },
  });

  const summaryRefresh = summary.data?.last_successful_refresh ?? null;
  const projectsRefresh = projects.data?.last_successful_refresh ?? null;
  useEffect(() => {
    if (summaryRefresh && summaryRefresh !== projectsRefresh) {
      void queryClient.invalidateQueries({ queryKey: ["projects"] });
    }
  }, [projectsRefresh, queryClient, summaryRefresh]);

  if (
    summary.isLoading ||
    projects.isLoading ||
    activity.isLoading ||
    settings.isLoading
  ) {
    return <DashboardSkeleton />;
  }
  const error =
    summary.error ?? projects.error ?? activity.error ?? settings.error;
  if (error) {
    return (
      <ErrorState
        message={
          error instanceof Error
            ? error.message
            : "The local service did not respond."
        }
        onRetry={() => void queryClient.invalidateQueries()}
      />
    );
  }
  if (!summary.data || !projects.data || !activity.data || !settings.data) {
    return null;
  }

  const lastRefresh =
    summary.data.last_successful_refresh ??
    projects.data.last_successful_refresh;
  const activeProjects = projects.data.items.filter((item) => !item.archived);
  const scanInProgress = refresh.isPending || summary.data.refreshing;
  const scanFreshnessLabel = getScanFreshnessLabel(
    lastRefresh,
    scanInProgress,
    settings.data.refresh_interval_seconds,
  );
  const cleanProjects = activeProjects.filter(
    (item) => item.status === "clean" && item.changed_files === 0,
  ).length;
  const changedProjects = activeProjects.filter(
    (item) => item.changed_files > 0 || item.status === "modified",
  ).length;
  const warningProjects = activeProjects.filter(
    (item) => item.warning_count > 0,
  ).length;
  const visibleProjects = activeProjects.filter((item) =>
    `${item.name} ${item.path}`
      .toLowerCase()
      .includes(projectSearch.trim().toLowerCase()),
  );
  const attention = activeProjects
    .map((project) => ({ project, signals: getAttentionSignals(project) }))
    .filter((item) => item.signals.length > 0)
    .sort(
      (left, right) =>
        right.project.warning_count - left.project.warning_count ||
        left.project.health_score - right.project.health_score,
    );

  return (
    <div className="page overview-page">
      <header className="page-header overview-header">
        <div>
          <p className="eyebrow">Workspace overview</p>
          <h1>Overview</h1>
          <p className="page-description">
            Repository health, changes, and remote state across your local
            workspace.
          </p>
        </div>
        <div className="header-actions scan-actions">
          <span
            className={`scan-freshness ${scanInProgress ? "is-scanning" : ""}`}
            title="Last successful repository scan"
            aria-live="polite"
          >
            <Clock3 size={15} />
            <span>
              <strong>{scanFreshnessLabel}</strong>
              <small>{formatScanFreshness(lastRefresh)}</small>
            </span>
          </span>
          <button
            className="button button-primary"
            onClick={() => refresh.mutate()}
            disabled={scanInProgress}
          >
            <RefreshCw size={16} className={scanInProgress ? "spin" : ""} />
            {scanInProgress ? "Scanning projects" : "Scan projects"}
          </button>
        </div>
      </header>

      {qaMode && (
        <section className="qa-artificial-notice">
          <strong>Artificial QA workspace</strong>
          <span>
            Every repository and activity record on this screen belongs to the
            isolated DevPulse test lab.
          </span>
        </section>
      )}

      <section className="landscape-strip" aria-label="Project landscape">
        <div className="landscape-intro">
          <span className="landscape-icon" aria-hidden="true">
            <GitBranch size={19} />
          </span>
          <div>
            <strong>
              {attention.length === 0 && activeProjects.length > 0
                ? "Workspace is clear"
                : `${attention.length} ${attention.length === 1 ? "project needs" : "projects need"} attention`}
            </strong>
            <small>From the latest read-only repository scan</small>
          </div>
        </div>
        <LandscapeMetric value={activeProjects.length} label="tracked" />
        <LandscapeMetric value={cleanProjects} label="clean" />
        <LandscapeMetric
          value={changedProjects}
          label="with local changes"
          tone={changedProjects > 0 ? "warning" : undefined}
        />
        <LandscapeMetric
          value={warningProjects}
          label="with warnings"
          tone={warningProjects > 0 ? "warning" : undefined}
        />
      </section>

      <section
        className="overview-section attention-section"
        aria-label="Needs attention"
      >
        <SectionHeading
          title="Needs attention"
          detail="The shortest path to repositories that may need a closer look."
          count={attention.length ? String(attention.length) : undefined}
        />
        {attention.length ? (
          <ul className="attention-queue">
            {attention.slice(0, 6).map(({ project, signals }) => (
              <li key={project.id}>
                <button onClick={() => onOpen?.(project.id)}>
                  <span className="attention-state" aria-hidden="true">
                    <TriangleAlert size={17} />
                  </span>
                  <span className="attention-copy">
                    <strong>{project.name}</strong>
                    <small>{signals.join(" · ")}</small>
                  </span>
                  <span className="attention-health">
                    <small>Health</small>
                    <strong>{project.health_score}</strong>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <div className="clear-state">
            <CheckCircle2 size={21} />
            <div>
              <strong>Nothing needs attention</strong>
              <span>
                All tracked repositories are clean, current, and free of scan
                warnings.
              </span>
            </div>
          </div>
        )}
      </section>

      <section
        className="overview-section repository-section"
        aria-label="Repository intelligence"
      >
        <SectionHeading
          title="Repositories"
          detail="Branch, remote state, local changes, and latest activity in one scan."
          action={
            <label className="search-field overview-search">
              <Search size={15} />
              <span className="visually-hidden">Search projects</span>
              <input
                value={projectSearch}
                onChange={(event) => setProjectSearch(event.target.value)}
                placeholder="Find a repository"
              />
            </label>
          }
        />
        {visibleProjects.length ? (
          <ProjectTable
            projects={visibleProjects.slice(0, 8)}
            onOpen={onOpen}
          />
        ) : (
          <div className="empty-state repository-empty-state">
            <GitBranch size={27} />
            <h3>
              {activeProjects.length
                ? "No matching repositories"
                : "No repositories yet"}
            </h3>
            <p>
              {activeProjects.length
                ? "Try a different repository name or path."
                : "Add one repository or a narrowly scoped project root. DevPulse will not scan elsewhere."}
            </p>
            {!activeProjects.length && (
              <div className="empty-actions">
                <button
                  className="button button-primary"
                  onClick={onAddProject}
                  disabled={qaMode}
                >
                  Add Project
                </button>
                <button
                  className="button"
                  onClick={onAddRoot}
                  disabled={qaMode}
                >
                  Add Project Root
                </button>
              </div>
            )}
          </div>
        )}
      </section>

      <div className="overview-secondary-grid">
        <section
          className="overview-section activity-summary"
          aria-label="Recent activity"
        >
          <SectionHeading
            title="Recent activity"
            detail="Repository scans and DevPulse events."
          />
          {activity.data.items.length ? (
            <ol className="activity-list compact-activity-list">
              {activity.data.items.slice(0, 6).map((event) => (
                <li key={event.id}>
                  <span className={`event-mark event-${event.kind}`} />
                  <div>
                    <p>{event.message}</p>
                    <time>{formatActivityTime(event.timestamp)}</time>
                  </div>
                </li>
              ))}
            </ol>
          ) : (
            <div className="clear-state neutral-clear-state">
              <Activity size={20} />
              <div>
                <strong>No recent activity</strong>
                <span>New scan and repository events will appear here.</span>
              </div>
            </div>
          )}
        </section>

        <section
          className="overview-section machine-summary"
          aria-label="Machine status"
        >
          <SectionHeading
            title="Machine status"
            detail="Secondary context from this Windows session."
          />
          <div className="machine-metrics">
            <MetricStrip
              label="CPU"
              value={summary.data.cpu_percent}
              kind="cpu"
            />
            <MetricStrip
              label="Memory"
              value={summary.data.memory_percent}
              kind="memory"
            />
            <MetricStrip
              label="Disk"
              value={summary.data.disk_percent}
              kind="disk"
            />
          </div>
        </section>
      </div>
    </div>
  );
}

function LandscapeMetric({
  value,
  label,
  tone,
}: {
  value: number;
  label: string;
  tone?: "warning";
}) {
  return (
    <div className={`landscape-metric ${tone ? `landscape-${tone}` : ""}`}>
      <strong>{value}</strong> <span>{label}</span>
    </div>
  );
}

function SectionHeading({
  title,
  detail,
  count,
  action,
}: {
  title: string;
  detail: string;
  count?: string;
  action?: ReactNode;
}) {
  return (
    <div className="section-heading">
      <div>
        <div className="section-title-line">
          <h2>{title}</h2>
          {count && <span className="section-count">{count}</span>}
        </div>
        <p>{detail}</p>
      </div>
      {action}
    </div>
  );
}

function getAttentionSignals(project: ProjectSummary): string[] {
  const signals: string[] = [];
  if (!project.exists || project.status === "missing") {
    signals.push("repository path is unavailable");
  } else if (project.error || project.status === "access_error") {
    signals.push("latest scan could not read this repository");
  } else if (project.changed_files > 0 || project.status === "modified") {
    signals.push(
      `${project.changed_files} local ${project.changed_files === 1 ? "change" : "changes"}`,
    );
  } else if (project.status !== "clean") {
    signals.push(`${project.status.replaceAll("_", " ")} working tree`);
  }

  if (project.ahead_count > 0 && project.behind_count > 0) {
    signals.push(
      `${project.ahead_count} ${project.ahead_count === 1 ? "commit" : "commits"} ahead and ${project.behind_count} behind`,
    );
  } else if (project.ahead_count > 0) {
    signals.push(
      `${project.ahead_count} local ${project.ahead_count === 1 ? "commit" : "commits"} not pushed`,
    );
  } else if (project.behind_count > 0) {
    signals.push(
      `${project.behind_count} ${project.behind_count === 1 ? "commit" : "commits"} behind remote`,
    );
  }
  if (project.warning_count > 0) {
    signals.push(
      `${project.warning_count} ${project.warning_count === 1 ? "warning" : "warnings"}`,
    );
  }
  if (
    project.repository_age_days !== null &&
    project.repository_age_days > 30
  ) {
    signals.push(`no commit for ${project.repository_age_days} days`);
  }
  return signals;
}

function formatScanFreshness(value: string | null): string {
  if (!value) return "No completed scan yet";
  return `Last scanned ${new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value))}`;
}

function getScanFreshnessLabel(
  value: string | null,
  scanInProgress: boolean,
  refreshIntervalSeconds: number,
): string {
  if (scanInProgress) return "Scan in progress";
  if (!value) return "Not scanned yet";
  if (refreshIntervalSeconds <= 0) return "Last scan recorded";
  const scannedAt = new Date(value).getTime();
  const staleAfterMs = Math.max(
    refreshIntervalSeconds * 2 * 1_000,
    15 * 60_000,
  );
  if (!Number.isFinite(scannedAt) || Date.now() - scannedAt > staleAfterMs) {
    return "Scan needs refresh";
  }
  return "Scan current";
}

function formatActivityTime(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}
