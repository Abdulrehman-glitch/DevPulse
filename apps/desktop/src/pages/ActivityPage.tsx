import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Activity, Check, Clipboard, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { DashboardSkeleton } from "../components/LoadingState";
import { ErrorState } from "../components/ErrorState";
import type { DataProvider } from "../providers/contracts";

export function ActivityPage({ provider }: { provider: DataProvider }) {
  const client = useQueryClient();
  const [search, setSearch] = useState("");
  const [severity, setSeverity] = useState("all");
  const [type, setType] = useState("all");
  const [project, setProject] = useState("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [copied, setCopied] = useState(false);
  const query = useQuery({
    queryKey: ["activity", "all"],
    queryFn: () => provider.getActivity(200),
  });
  const projects = useQuery({
    queryKey: ["projects"],
    queryFn: () => provider.getProjects(),
  });
  const clear = useMutation({
    mutationFn: () => provider.clearActivity(),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["activity"] });
    },
  });
  const source = useMemo(() => query.data?.items ?? [], [query.data]);
  const types = [...new Set(source.map((item) => item.event_type))];
  const items = useMemo(
    () =>
      source.filter((item) => {
        const timestamp = item.timestamp.slice(0, 10);
        const value = `${item.message} ${item.event_type}`.toLowerCase();
        return (
          (!search || value.includes(search.toLowerCase())) &&
          (severity === "all" || item.kind === severity) &&
          (type === "all" || item.event_type === type) &&
          (project === "all" || item.project_id === project) &&
          (!from || timestamp >= from) &&
          (!to || timestamp <= to)
        );
      }),
    [from, project, search, severity, source, to, type],
  );
  if (query.isLoading) return <DashboardSkeleton />;
  if (query.error)
    return (
      <ErrorState
        message={
          query.error instanceof Error
            ? query.error.message
            : "Activity data is unavailable."
        }
        onRetry={() => void query.refetch()}
      />
    );
  async function copyReport() {
    const report = JSON.stringify(
      {
        schema_version: 1,
        generated_at: new Date().toISOString(),
        events: items.map(
          ({ id, timestamp, kind, event_type, message, project_id }) => ({
            id,
            timestamp,
            kind,
            event_type,
            message,
            project_id,
          }),
        ),
      },
      null,
      2,
    );
    await navigator.clipboard.writeText(report);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2_000);
  }
  return (
    <div className="page">
      <header className="page-header">
        <div>
          <p className="eyebrow">Local history</p>
          <h1>Activity</h1>
          <p className="page-description">
            DevPulse events only — never file contents, credentials, or
            unrelated document names.
          </p>
        </div>
        <div className="header-actions">
          <button className="button" onClick={() => void copyReport()}>
            {copied ? <Check size={15} /> : <Clipboard size={15} />}
            {copied ? "Report copied" : "Copy redacted report"}
          </button>
          <button
            className="button button-danger"
            onClick={() => {
              if (
                window.confirm(
                  "Clear DevPulse activity history? This affects only DevPulse’s own records.",
                )
              )
                clear.mutate();
            }}
          >
            <Trash2 size={15} /> Clear history
          </button>
        </div>
      </header>
      <section className="panel timeline-panel">
        <div className="filter-bar activity-filters">
          <label className="search-field">
            <Activity size={15} />
            <span className="visually-hidden">Search activity</span>
            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search activity"
            />
          </label>
          <select
            aria-label="Severity filter"
            value={severity}
            onChange={(event) => setSeverity(event.target.value)}
          >
            <option value="all">All severities</option>
            <option value="info">Info</option>
            <option value="success">Success</option>
            <option value="warning">Warning</option>
            <option value="error">Error</option>
          </select>
          <select
            aria-label="Event type filter"
            value={type}
            onChange={(event) => setType(event.target.value)}
          >
            <option value="all">All event types</option>
            {types.map((item) => (
              <option key={item} value={item}>
                {item.replaceAll("_", " ")}
              </option>
            ))}
          </select>
          <select
            aria-label="Project filter"
            value={project}
            onChange={(event) => setProject(event.target.value)}
          >
            <option value="all">All projects</option>
            {(projects.data?.items ?? []).map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
              </option>
            ))}
          </select>
          <label className="date-filter">
            <span>From</span>
            <input
              type="date"
              value={from}
              onChange={(event) => setFrom(event.target.value)}
            />
          </label>
          <label className="date-filter">
            <span>To</span>
            <input
              type="date"
              value={to}
              onChange={(event) => setTo(event.target.value)}
            />
          </label>
          <span>{items.length} events</span>
        </div>
        {items.length ? (
          <ol className="timeline">
            {items.map((event) => (
              <li key={event.id}>
                <span className={`event-mark event-${event.kind}`} />
                <time>
                  {new Intl.DateTimeFormat(undefined, {
                    dateStyle: "medium",
                    timeStyle: "short",
                  }).format(new Date(event.timestamp))}
                </time>
                <div>
                  <small>{event.event_type.replaceAll("_", " ")}</small>
                  <p>{event.message}</p>
                </div>
              </li>
            ))}
          </ol>
        ) : (
          <div className="empty-state">
            <Activity size={28} />
            <h3>No matching activity</h3>
            <p>Change the filters or refresh a registered project.</p>
          </div>
        )}
      </section>
    </div>
  );
}
