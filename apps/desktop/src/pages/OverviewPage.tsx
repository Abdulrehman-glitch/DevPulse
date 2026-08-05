import type { DataProvider } from "../providers/contracts";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  CheckCircle2,
  Clock3,
  GitBranch,
  RefreshCw,
  Search,
  TriangleAlert,
} from "lucide-react";
import { type ReactNode, useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import { MetricStrip } from "../components/MetricStrip";
import { ProjectTable } from "../components/ProjectTable";

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
  if (summary.isLoading || projects.isLoading || activity.isLoading)
    return <DashboardSkeleton />;
  const error = summary.error ?? projects.error ?? activity.error;
  if (error)
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
  if (!summary.data || !projects.data || !activity.data) return null;
  const lastRefresh = projects.data.last_successful_refresh;
  const activeProjects = projects.data.items.filter((item) => !item.archived);
  const visibleProjects = activeProjects.filter((item) =>
    `${item.name} ${item.path}`
      .toLowerCase()
      .includes(projectSearch.trim().toLowerCase()),
  );
  const favorites = activeProjects.filter((item) => item.favorite);
  const attention = activeProjects.filter(
    (item) => item.warning_count > 0 || item.status !== "clean",
  );
  const ahead = activeProjects.filter((item) => item.ahead_count > 0).length;
  const behind = activeProjects.filter((item) => item.behind_count > 0).length;
  const stale = activeProjects.filter(
    (item) =>
      item.repository_age_days !== null && item.repository_age_days > 30,
  ).length;
  return (
    <div className="page overview-page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Workspace pulse</p>
          <h1>Overview</h1>
          <p className="page-description">
            A clear read of your machine and repositories, kept local and
            read-only.
          </p>
        </div>
        <div className="header-actions">
          <span
            className="last-refresh"
            title="Last successful repository scan"
          >
            <Clock3 size={15} />
            {lastRefresh
              ? `Updated ${new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(new Date(lastRefresh))}`
              : "Not refreshed yet"}
          </span>
          <button
            className="button button-primary"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
          >
            <RefreshCw size={16} className={refresh.isPending ? "spin" : ""} />
            {refresh.isPending ? "Refreshing" : "Refresh"}
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
      <section className="metrics-grid" aria-label="System utilisation">
        <MetricStrip
          label="CPU utilisation"
          value={summary.data.cpu_percent}
          kind="cpu"
        />
        <MetricStrip
          label="Memory utilisation"
          value={summary.data.memory_percent}
          kind="memory"
        />
        <MetricStrip
          label="Disk utilisation"
          value={summary.data.disk_percent}
          kind="disk"
        />
        <MetricStrip
          label="Average health"
          value={summary.data.average_health_score}
          kind="health"
        />
      </section>
      <section className="workspace-summary" aria-label="Repository summary">
        <SummaryIcon
          label="Repositories"
          value={activeProjects.length}
          icon={<GitBranch size={17} />}
        />
        <SummaryIcon
          label="Clean"
          value={summary.data.clean_repositories}
          icon={<CheckCircle2 size={17} />}
        />
        <SummaryIcon
          label="With changes"
          value={summary.data.modified_repositories}
          icon={<TriangleAlert size={17} />}
        />
        <SummaryIcon
          label="Warnings"
          value={summary.data.repositories_with_warnings}
          icon={<TriangleAlert size={17} />}
        />
      </section>
      <section className="signal-grid" aria-label="Repository signals">
        <Signal
          label="Ahead of remote"
          value={ahead}
          detail="Local commits not on the upstream branch"
        />
        <Signal
          label="Behind remote"
          value={behind}
          detail="Upstream commits not in the local branch"
        />
        <Signal
          label="Stale repositories"
          value={stale}
          detail="No commit observed in the last 30 days"
        />
        <Signal
          label="Scan duration"
          value={summary.data.refreshing ? "Scanning" : "Ready"}
          detail="Refresh work stays outside the UI thread"
        />
      </section>
      <section className="panel project-panel">
        <div className="panel-heading">
          <div>
            <h2>Projects</h2>
            <p>Repository state from the most recent read-only scan.</p>
          </div>
          <label className="search-field overview-search">
            <Search size={15} />
            <span className="visually-hidden">Search projects</span>
            <input
              value={projectSearch}
              onChange={(event) => setProjectSearch(event.target.value)}
              placeholder="Quick project search"
            />
          </label>
        </div>
        {visibleProjects.length ? (
          <ProjectTable
            projects={visibleProjects.slice(0, 6)}
            onOpen={onOpen}
          />
        ) : (
          <div className="empty-state">
            <GitBranch size={28} />
            <h3>
              {activeProjects.length
                ? "No matching projects"
                : "Your workspace is ready"}
            </h3>
            <p>
              {activeProjects.length
                ? "Try a different name or path."
                : "Add one repository or preview a narrowly scoped project root. DevPulse will not scan elsewhere."}
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
      <section className="panel favorites-panel">
        <div className="panel-heading">
          <div>
            <h2>Favorite projects</h2>
            <p>A quick shelf for the repositories you check most often.</p>
          </div>
          <span>{favorites.length}</span>
        </div>
        {favorites.length ? (
          <div className="favorite-grid">
            {favorites.slice(0, 4).map((item) => (
              <button
                className="favorite-card"
                key={item.id}
                onClick={() => onOpen?.(item.id)}
              >
                <strong>{item.name}</strong>
                <span>
                  {item.primary_technology} · health {item.health_score}
                </span>
              </button>
            ))}
          </div>
        ) : (
          <div className="compact-empty">
            Mark a project as favorite from the Projects page.
          </div>
        )}
      </section>
      {attention.length > 0 && (
        <section className="panel attention-panel">
          <div className="panel-heading">
            <div>
              <h2>Attention</h2>
              <p>
                Signals that deserve a manual review. DevPulse has not changed
                anything.
              </p>
            </div>
            <span>{attention.length} projects</span>
          </div>
          <ul className="attention-list">
            {attention.slice(0, 8).map((item) => (
              <li key={item.id}>
                <span>
                  <strong>{item.name}</strong>
                  <small>
                    {item.warning_count
                      ? `${item.warning_count} warning${item.warning_count === 1 ? "" : "s"}`
                      : item.status === "clean"
                        ? "No attention signal"
                        : `${item.status} working tree`}
                  </small>
                </span>
                <b>{item.health_score}</b>
              </li>
            ))}
          </ul>
        </section>
      )}
      <section className="panel activity-panel">
        <div className="panel-heading">
          <div>
            <h2>Recent activity</h2>
            <p>Recent repository activity and DevPulse actions.</p>
          </div>
          <span>{activity.data.items.length} events</span>
        </div>
        {activity.data.items.length ? (
          <ol className="activity-list">
            {activity.data.items.slice(0, 8).map((event) => (
              <li key={event.id}>
                <span className={`event-mark event-${event.kind}`} />
                <div>
                  <p>{event.message}</p>
                  <time>
                    {new Intl.DateTimeFormat(undefined, {
                      timeStyle: "short",
                    }).format(new Date(event.timestamp))}
                  </time>
                </div>
              </li>
            ))}
          </ol>
        ) : (
          <div className="compact-empty">
            Activity will appear after the first repository refresh.
          </div>
        )}
      </section>
    </div>
  );
}

function SummaryIcon({
  label,
  value,
  icon,
}: {
  label: string;
  value: number;
  icon: ReactNode;
}) {
  return (
    <div>
      {icon}
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}
function Signal({
  label,
  value,
  detail,
}: {
  label: string;
  value: number | string;
  detail: string;
}) {
  return (
    <article className="signal-card">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
}
